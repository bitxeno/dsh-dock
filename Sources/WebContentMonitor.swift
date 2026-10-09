import Cocoa
import WebKit

/// WebContent 内存哨兵。
///
/// 背景：12G 级 footprint 是十几个小时堆出来的（实测：基线 ~1G、无害峰值 2.9G、
/// 冻机时 12G），不是瞬间爆炸——只要在 4–5G 处动手就到不了冻机的量级。
/// 之前缺的不是反应速度，是根本没人值班：30s 轮询有上千次动手窗口。
///
/// 读数：WebContent 是独立 XPC 进程（ppid=1），App 自身的 task_info 看不见它；
/// 用私有 `_webProcessIdentifier` 拿 PID（best-effort，拿不到就只观察不动手，
/// 绝不靠进程名猜归因——机器上可能还有模拟器等别的 WebContent），再用 libproc
/// 公开接口 `proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint` 读精确 footprint
/// （和 `footprint(1)` 同口径，同用户进程可读，无需特殊 entitlement）。
///
/// 整机压力兜底刻意不做（需求明确排除）：只看自家 WebContent。
final class WebContentMonitor {
    // MARK: - 阈值（调参只改这里，单位字节）

    /// 超过即提示（每轮只提示一次，见 notifiedXXX）。
    static let warnBytes: UInt64 = 4 * 1024 * 1024 * 1024
    /// 超过即动手（隐藏时自动重建，可见时弹提示让用户点）。
    static let actBytes: UInt64 = 5 * 1024 * 1024 * 1024
    /// 回落到此以下才解除本轮（warned/notified 复位），防阈值线上反复横跳。
    static let clearBytes: UInt64 = 1536 * 1024 * 1024
    /// 轮询间隔。
    static let pollInterval: TimeInterval = 30
    /// 动手后冷却：冷却内再次冲上 act，说明重建也压不住
    /// （巨型会话一点就爆），不再循环重建，转人工提示。
    static let cooldown: TimeInterval = 10 * 60

    enum Event {
        case warn(UInt64)
        case act(UInt64)
        case escalate(UInt64)
    }

    var onEvent: ((Event) -> Void)?

    private var timer: Timer?
    private var pidResolver: (() -> pid_t?)?
    private var notifiedWarn = false
    private var notifiedAct = false
    private var notifiedEscalate = false
    private var lastAutoAction = Date.distantPast
    private var pidMissingLogged = false
    private let queue = DispatchQueue(label: "com.xenori.dshdock.webcontent-monitor", qos: .utility)

    /// 幂等：重复 start 先停旧 timer。启动即查一次，不用等 30s。
    func start(pidResolver: @escaping () -> pid_t?) {
        stop()
        self.pidResolver = pidResolver
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pidResolver = nil
    }

    /// 真动手（重建 WebView）后调用：记时间戳进冷却。
    func recordAutoAction() {
        lastAutoAction = Date()
    }

    // MARK: - 轮询

    private func tick() {
        guard let pid = pidResolver?() else {
            // 进程还没起来（首次加载前）或私有接口变化：只观察不动手，
            // 同一原因只记一次日志，30s 一条刷屏没有意义。
            if !pidMissingLogged {
                pidMissingLogged = true
                NSLog("[DshDock] 内存哨兵：取不到 WebContent PID（进程未起或私有接口变化），本轮只观察不动手")
            }
            return
        }
        pidMissingLogged = false
        queue.async { [weak self] in
            guard let fp = Self.physFootprint(pid: pid) else { return }
            DispatchQueue.main.async { self?.handle(footprint: fp) }
        }
    }

    /// 同一轮（一次冲高到回落）每种事件只发一次：warn 弹过就不再弹，
    /// act 点了"稍后"也不会 30s 骚扰一次；回落后复位。
    private func handle(footprint fp: UInt64) {
        if fp < Self.clearBytes {
            notifiedWarn = false
            notifiedAct = false
            notifiedEscalate = false
            return
        }
        if fp >= Self.actBytes {
            if Date().timeIntervalSince(lastAutoAction) < Self.cooldown {
                if !notifiedEscalate {
                    notifiedEscalate = true
                    NSLog("[DshDock] 内存哨兵：动手后 %.0fs 内再次超标 %@ GB，转人工提示",
                          Self.cooldown, Self.gbString(fp))
                    onEvent?(.escalate(fp))
                }
            } else if !notifiedAct {
                notifiedAct = true
                onEvent?(.act(fp))
            }
            return
        }
        if fp >= Self.warnBytes, !notifiedWarn {
            notifiedWarn = true
            onEvent?(.warn(fp))
        }
    }

    // MARK: - 读数原语

    /// WKWebView 的 WebContent PID：私有 `_webProcessIdentifier`，best-effort。
    /// KVC 取不到会抛 NSException（Swift 接不住），所以先 responds 守门——
    /// 方法存在时 KVC 必然能取到（标量自动装箱成 NSNumber），不存在时直接 nil。
    static func webContentPID(of webView: WKWebView) -> pid_t? {
        let sel = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: sel) else { return nil }
        guard let num = webView.value(forKey: "_webProcessIdentifier") as? NSNumber else { return nil }
        let pid = num.int32Value
        return pid > 0 ? pid : nil
    }

    /// 精确 footprint（字节），和 `footprint(1)` 同口径。
    /// libproc 的 buffer 形参是 `void **`（`rusage_info_t *`），按 Apple 示例 cast 后传入。
    static func physFootprint(pid: pid_t) -> UInt64? {
        let buf = UnsafeMutablePointer<rusage_info_v4>.allocate(capacity: 1)
        defer { buf.deallocate() }
        let ret = buf.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
        guard ret == 0 else { return nil }
        return buf.pointee.ri_phys_footprint
    }

    static func gbString(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000)
    }
}
