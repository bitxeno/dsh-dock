import Foundation

enum DshLaunchError: LocalizedError {
    case portOccupied(Int)
    case binaryMissing(searched: [String])
    case invalidBinary(String)
    case exited(code: Int32, logTail: String)
    case timeout(logTail: String)

    var errorDescription: String? {
        switch self {
        case .portOccupied(let p): return "端口 \(p) 已被占用"
        case .binaryMissing: return "找不到 dsh（且 npx fallback 也不可用）"
        case .invalidBinary(let s): return "二进制不可用：\(s)"
        case .exited(let c, _): return "dsh 启动后退出，exit=\(c)"
        case .timeout: return "dsh 启动超时（10s 未就绪）"
        }
    }
}

/// 端口占用者（lsof 解析结果），错误页展示 + 强杀定位用。
struct PortOccupant {
    let pid: pid_t
    let name: String
    var description: String { "\(name) (pid \(pid))" }
}

/// 托管 dsh 子进程：启动/停止/重启 + 就绪轮询 + 日志。
/// Swift 5 模式：状态回调一律派到主线程。
final class DshService: NSObject {
    enum State: String {
        case idle, starting, running, stopping
    }

    let log = LogStore()
    private(set) var state: State = .idle
    private var process: Process?
    private var outPipe: Pipe?
    private var errPipe: Pipe?
    private var currentConfig: DshConfig?
    private var currentLaunch: ResolvedLaunch?
    private var currentCleanedExtra: [String] = []
    private var strippedArgs: [String] = []

    var onStateChange: ((State) -> Void)?
    var onUnexpectedExit: ((Int32) -> Void)?

    var providerDescription: String { currentLaunch?.displayName ?? "未启动" }

    // dsh 会在 stdout 打印带 token 的完整 URL（`dsh web: http://127.0.0.1:<port>/?token=…`），
    // 裸 `/` 只会 401，必须加载 token URL。实测：token URL 返回 303（就绪），裸 `/` 返回 401。
    private let urlLock = NSLock()
    private var _serviceURL: URL?
    var serviceURL: URL? {
        urlLock.lock()
        defer { urlLock.unlock() }
        return _serviceURL
    }

    private func setServiceURL(_ u: URL?) {
        urlLock.lock()
        _serviceURL = u
        urlLock.unlock()
    }

    /// 从子进程输出里抓 token URL：优先含 `token=` 的 http(s) 链接。
    private func scanForServiceURL(_ chunk: String) {
        urlLock.lock()
        let already = _serviceURL
        urlLock.unlock()
        if already != nil { return }
        guard let re = try? NSRegularExpression(pattern: "https?://[^\\s\"'<>]+", options: []) else { return }
        let range = NSRange(chunk.startIndex..., in: chunk)
        let matches = re.matches(in: chunk, options: [], range: range)
        var fallback: URL?
        for m in matches {
            guard let r = Range(m.range, in: chunk) else { continue }
            let s = String(chunk[r])
            guard let u = URL(string: s) else { continue }
            if s.contains("token=") {
                setServiceURL(u)
                log.append("发现服务 URL（token）：\(u)")
                return
            }
            if fallback == nil { fallback = u }
        }
        // 非 token 链接也记一个保底（比如 dsh 改版不打印 token 时降级用），但不视为就绪。
        if let fb = fallback {
            urlLock.lock()
            if _serviceURL == nil { _serviceURL = fb }
            urlLock.unlock()
        }
    }

    func diagnosticCommand() -> String {
        guard let cfg = currentConfig, let launch = currentLaunch else { return "" }
        var parts: [String] = [launch.executableURL.path]
        parts += launch.prefixArgs
        parts += ["web", "--no-open", "--port", String(cfg.port)]
        parts += currentCleanedExtra
        return shellJoin(parts)
    }

    private func setState(_ s: State) {
        state = s
        if Thread.isMainThread {
            onStateChange?(s)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onStateChange?(s)
            }
        }
    }

    // MARK: - 启动

    func start(config: DshConfig) async throws {
        if state == .starting || state == .running { return }
        if state == .stopping {
            // 等上一次停干净再起
            var tries = 0
            while state == .stopping && tries < 100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                tries += 1
            }
        }
        setState(.starting)
        log.clearRing()
        setServiceURL(nil)
        currentConfig = config

        // 1) 解析二进制
        let (launch, searched) = BinaryResolver.resolve(configuredBinary: config.binaryPath)
        guard let launch = launch else {
            // 区分自定义无效 vs 全缺失；错误页"详情"读环 buffer，这里必须先落日志
            log.header("二进制解析失败")
            if !searched.isEmpty {
                log.append("已搜索：\n" + searched.map { "  \($0)" }.joined(separator: "\n"))
            }
            let trimmed = config.binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != DshConfig.defaultBinary && !trimmed.isEmpty {
                setState(.idle)
                throw DshLaunchError.invalidBinary(trimmed)
            }
            setState(.idle)
            throw DshLaunchError.binaryMissing(searched: searched)
        }
        currentLaunch = launch

        // 2) 切分 extra 并 strip App 拥有的参数
        let rawExtra = shellSplit(config.extraArgs)
        let (cleaned, stripped) = stripOwnedArgs(rawExtra)
        currentCleanedExtra = cleaned
        strippedArgs = stripped

        // 3) 先把本次启动的命令写进日志（必须在 TCP 预检之前——错误页"详情"读的就是
        //    这份环 buffer，不留一行就永远是空的，实测踩过）。
        log.header("启动 \(launch.displayName)")
        let diag: [String] = [launch.executableURL.path] + launch.prefixArgs
            + ["web", "--no-open", "--port", String(config.port)] + cleaned
        log.append("$ " + shellJoin(diag))
        if !stripped.isEmpty {
            log.append("提示：已忽略命令中的自带参数（以端口字段为准）：\(stripped.joined(separator: " "))")
        }

        // 4) TCP 预检端口
        if tcpConnectSucceeds(port: config.port) {
            log.append("TCP 预检失败：127.0.0.1:\(config.port) 已被其他进程监听")
            setState(.idle)
            throw DshLaunchError.portOccupied(config.port)
        }

        // 5) 组装 Process
        let proc = Process()
        proc.executableURL = launch.executableURL
        proc.arguments = launch.prefixArgs + ["web", "--no-open", "--port", String(config.port)] + cleaned
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // PATH 多来源合并去重，不依赖单一来源（实测踩坑）：brew shellenv 配在
        // .zshrc（交互式）而非 .zprofile 的机器上，Finder 双击下 zsh -l -c 拿到的
        // login PATH 没有 /opt/homebrew/bin——dsh 能靠固定路径解析到，但它脚本的
        // `#!/usr/bin/env node` 找不到 node，直接起不来。所以把 login PATH、
        // 当前 env、dsh 所在目录、常用固定目录全部并进来。
        var env = ProcessInfo.processInfo.environment
        var pathParts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        if let lp = BinaryResolver.loginShellPATH() {
            pathParts += lp.split(separator: ":").map(String.init)
        }
        pathParts.append(launch.executableURL.deletingLastPathComponent().path)
        pathParts.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin",
                                      "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        var seenPaths = Set<String>()
        env["PATH"] = pathParts
            .filter { !$0.isEmpty && seenPaths.insert($0).inserted }
            .joined(separator: ":")
        proc.environment = env

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        outPipe = out
        errPipe = err

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            self?.log.append(s)
            self?.scanForServiceURL(s)
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            self?.log.append(s)
            self?.scanForServiceURL(s)
        }
        proc.terminationHandler = { [weak self] p in
            guard let self = self else { return }
            // 排空残余
            self.outPipe?.fileHandleForReading.readabilityHandler = nil
            self.errPipe?.fileHandleForReading.readabilityHandler = nil
            let code = p.terminationStatus
            let cur = self.state
            // 意料之中（stop 中）不回调；意料之外（running/starting 中挂掉）通知 UI
            if cur == .running || cur == .starting {
                DispatchQueue.main.async {
                    self.onUnexpectedExit?(code)
                }
            }
        }

        do {
            try proc.run()
        } catch {
            setState(.idle)
            throw DshLaunchError.exited(code: -1, logTail: "无法拉起进程：\(error.localizedDescription)")
        }
        process = proc

        // 5) 就绪轮询：等 token URL 出现并探活（2xx/3xx 算就绪；401 不算），10s 超时。
        //    裸 `/` 无 token 会 401，所以必须按 token URL 探。
        let bareURL = URL(string: "http://127.0.0.1:\(config.port)/")!
        let deadline = Date().addingTimeInterval(10)
        var ready = false
        while Date() < deadline {
            if Task.isCancelled {
                await stop()
                throw DshLaunchError.timeout(logTail: log.tail(100))
            }
            if !proc.isRunning {
                let code = proc.terminationStatus
                setState(.idle)
                process = nil
                throw DshLaunchError.exited(code: code, logTail: log.tail(100))
            }
            if let target = serviceURL, await httpOK(url: target) {
                ready = true
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if !ready {
            // TCP 兜底 + 降级：端口已监听但 token 探针没通过（比如 dsh 改了输出格式），
            // 仍进 WebView 让 dsh 自己的 401 提示可见，而不是干等报错。
            if proc.isRunning && tcpConnectSucceeds(port: config.port) {
                if serviceURL == nil {
                    log.append("提示：未从输出中解析到 token URL，但 TCP 端口已监听，降级加载裸 URL（可能显示 401 鉴权提示）。")
                    setServiceURL(bareURL)
                } else {
                    log.append("提示：token URL 探针未通过，但 TCP 端口已监听，按就绪处理。")
                }
                ready = true
            }
        }
        if !ready {
            await stop()
            throw DshLaunchError.timeout(logTail: log.tail(100))
        }
        setState(.running)
    }

    func stop(grace: Double = 5) async {
        guard let p = process else {
            setState(.idle)
            return
        }
        if state == .idle { return }
        setState(.stopping)
        // 先摘掉意外退出回调的干扰：terminationHandler 里按 state 判断，stopping 不回调
        p.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while p.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if p.isRunning {
            log.append("警告：SIGTERM 后 \(Int(grace))s 仍未退出，发送 SIGKILL。")
            kill(p.processIdentifier, SIGKILL)
            let d2 = Date().addingTimeInterval(2)
            while p.isRunning && Date() < d2 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        outPipe = nil
        errPipe = nil
        setState(.idle)
    }

    func restart(config: DshConfig) async throws {
        await stop()
        try await start(config: config)
    }

    /// App 退出时的同步兜底：优雅等 2s，不死再 SIGKILL。必须快。
    func terminateForQuit() {
        guard let p = process else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
        process = nil
    }

    // MARK: - 端口占用（错误页"强制结束并重启"用）

    /// 查询 LISTEN 在指定 TCP 端口的进程。走 /usr/sbin/lsof 绝对路径（GUI PATH 残缺），
    /// -F 模式免表头解析；可能同时有多个监听者（SO_REUSEPORT）。
    func portOccupants(port: Int) -> [PortOccupant] {
        let out = runTool("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"])
        var result: [PortOccupant] = []
        var pid: pid_t?
        var name = ""
        func flush() {
            if let pid { result.append(PortOccupant(pid: pid, name: name.isEmpty ? "?" : name)) }
            pid = nil
            name = ""
        }
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("p"), let p = pid_t(line.dropFirst()) {
                flush()
                pid = p
            } else if line.hasPrefix("c") {
                name = String(line.dropFirst())
            }
        }
        flush()
        return result
    }

    /// SIGKILL 掉 LISTEN 在指定端口的所有进程，返回被杀列表（写进服务日志备查）。
    @discardableResult
    func forceKillPortOccupants(port: Int) -> [PortOccupant] {
        let victims = portOccupants(port: port)
        for v in victims {
            kill(v.pid, SIGKILL)
            log.append("已强制结束占用端口 \(port) 的进程：\(v.description)")
        }
        return victims
    }

    private func runTool(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 探针

    /// token URL 实测返回 303（就绪），裸 `/` 返回 401（未鉴权）。2xx/3xx 视为就绪。
    private func httpOK(url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.0
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let code = (resp as? HTTPURLResponse)?.statusCode {
                return (200..<400).contains(code)
            }
            return false
        } catch {
            return false
        }
    }
}

/// 同步 TCP 预检：能连上即视为占用。localhost 上拒绝会立刻失败，不会 hang。
func tcpConnectSucceeds(port: Int, host: String = "127.0.0.1") -> Bool {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    let portStr = String(port)
    let rc = host.withCString { h in
        portStr.withCString { p in
            getaddrinfo(h, p, &hints, &res)
        }
    }
    guard rc == 0, let info = res else { return false }
    defer { freeaddrinfo(res) }
    let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    guard let addr = info.pointee.ai_addr else { return false }
    let len = info.pointee.ai_addrlen
    // 直接拷贝 sockaddr
    var storage = sockaddr_storage()
    memcpy(&storage, addr, Int(len))
    let ok: Bool = withUnsafePointer(to: &storage) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
            connect(fd, sock, len) == 0
        }
    }
    return ok
}
