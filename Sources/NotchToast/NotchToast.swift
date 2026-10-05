import Cocoa
import SwiftUI

/// 刘海悬窗通知（自研小引擎）。
///
/// 视觉与动效对齐 DynamicNotch（jackson-storm/DynamicNotch，GPL-3.0，本仓同 license）：
/// 纯黑底 + 白 20% 描边 2pt、顶部平边贴住菜单栏（粘连感）、底部大圆角、
/// 标题 14 semibold / 描述 11 medium 白 55%、按钮全宽 35 高胶囊、
/// 进场 scale+opacity+位移 spring。形状与按钮样式为参照其
/// NotchShape / PrimaryButtonStyle 的重实现（非整块搬运：不要它的
/// 400+ 文件引擎、设置流、手势与私有 API）。
struct NotchToastAction {
    let identifier: String
    let title: String
}

/// 参照 DynamicNotch `NotchShape`：顶边全宽平直（贴菜单栏即粘连感来自这里，
/// 顶部只有小过渡圆角），底部大圆角；圆角可动画，spring 下自动形变。
private struct NotchToastShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY))
        return path
    }
}

/// 参照 DynamicNotch `PrimaryButtonStyle`：全宽 35 高胶囊，按压缩小 + 变暗。
private struct NotchToastButtonStyle: ButtonStyle {
    var backgroundColor: Color = .gray.opacity(0.25)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: 35)
            .background(backgroundColor)
            .cornerRadius(30)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct NotchToastView: View {
    let toastId: String
    let title: String
    let message: String
    let actions: [NotchToastAction]
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    /// 进场位移 = 内容高度一半：内容从刘海里浮出来。
    let revealOffset: CGFloat
    let onBodyClick: () -> Void
    let onAction: (String) -> Void

    /// 入场 spring 开关：挂载即播一次。
    @State private var appeared = false

    var body: some View {
        let shape = NotchToastShape(topCornerRadius: topRadius, bottomCornerRadius: bottomRadius)
        // 内容 mask：比底小一圈，内容永远漫不出黑底。
        let maskShape = NotchToastShape(topCornerRadius: max(0, topRadius - 2),
                                        bottomCornerRadius: max(0, bottomRadius - 2))
        VStack(spacing: 0) {
            if appeared {
        VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.blue.gradient)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title.isEmpty ? "DshDock" : title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            if !message.isEmpty {
                                Text(message)
                                    .foregroundColor(.white.opacity(0.55))
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 20)

                    if !actions.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(Array(actions.prefix(2).enumerated()), id: \.offset) { idx, a in
                                Button(action: { onAction(a.identifier) }) {
                                    Text(a.title)
                                        .font(.system(size: 14))
                                        .fontWeight(.medium)
                                        .foregroundStyle(idx == 1 ? .blue : .white)
                                }
                                .buttonStyle(NotchToastButtonStyle(
                                    backgroundColor: idx == 1 ? .blue.opacity(0.25) : .gray.opacity(0.25)))
                                .accessibilityLabel(a.title)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 12)
                .frame(width: 360, alignment: .top)
                .background(shape.fill(.black))
                .clipShape(maskShape)
                .overlay { shape.stroke(.white.opacity(0.2), lineWidth: 2) }
                // 整个胶囊（含黑底）作为一个整体从顶部长出来：底和内容一起动，
                // 弹簧过冲也不会出现"内容漫出底"的错位；锚点 .top 让顶部钉在菜单栏上。
                .transition(
                    .scale(scale: 0.85, anchor: .top).combined(with: .opacity)
                        .combined(with: .offset(y: -revealOffset))
                        .animation(.interactiveSpring(duration: 0.5, extraBounce: 0.25,
                                                     blendDuration: 0.125)))
            }
        }
        .environment(\.colorScheme, .dark)
        .onTapGesture { onBodyClick() }
        .onAppear {
            // 挂载日志：与"呈现自检"配合可定位"窗正常但空白"的内容层问题。
            NSLog("[DshDock] 悬窗内容挂载：id=%@", toastId)
            appeared = true
        }
    }
}

/// 暂存的审批：文本暂代显示时记下原文，文本消失后恢复，沒有用户操作不丢失。
private struct ParkedApproval {
    let id: String
    let tag: String
    let title: String
    let body: String
    let actions: [NotchToastAction]
    let onBodyClick: () -> Void
    let onAction: (String) -> Void
}

/// 单例悬窗管理：同一时刻只留一条；同 tag 先顶掉上一条（对齐系统通知 renotify）。
/// 面板贴住屏幕顶部（y 无缝隙 = 粘连感来源）；进场为 SwiftUI 插入转场 +
/// 窗口层淡入，退出 0.18s 淡出。
final class NotchToastManager {
    static let shared = NotchToastManager()

    private var panel: NSPanel?
    private var hosting: NSHostingView<NotchToastView>?
    private var dismissWork: DispatchWorkItem?
    private var verifyWork: DispatchWorkItem?
    private var currentId: String?
    private var currentTag: String = ""
    /// 当前悬窗是否待审批（有按钮）：是则常驻，不自动消失。
    private var currentHasActions = false
    /// 正在显示的审批原文（文本暂代显示时，用于文本消失后恢复）。
    private var displayedApproval: ParkedApproval?
    /// 被文本暂代的审批：当前文本消失后重新请回来。
    private var parkedApproval: ParkedApproval?

    private init() {}

    /// 有 actions 时多留一会儿（等用户点裁决），纯文本则短停。
    static func dwellTime(hasActions: Bool) -> TimeInterval {
        hasActions ? 8 : 4
    }

    func show(id: String, tag: String, title: String, body: String,
              actions: [NotchToastAction],
              onBodyClick: @escaping () -> Void,
              onAction: @escaping (String) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let hasActions = !actions.isEmpty
            if hasActions {
                // 新审批（或同 tag 更新）：成为当前显示，清除暂存。
                displayedApproval = ParkedApproval(id: id, tag: tag, title: title, body: body,
                                                   actions: actions, onBodyClick: onBodyClick, onAction: onAction)
                parkedApproval = nil
            } else if self.currentId != nil, self.currentHasActions {
                if tag == self.currentTag {
                    // 同 tag 文本替换审批：视为审批被替代，不再恢复。
                    displayedApproval = nil
                    parkedApproval = nil
                } else if self.parkedApproval == nil {
                    // 审批暂存：文本先显示，文本消失后把审批请回来。
                    NSLog("[DshDock] 刘海审批暂存，文本先行：approval=%@ textTag=%@", self.currentTag, tag)
                    parkedApproval = displayedApproval
                }
            }
            // 同 tag 顶掉：与 UNUserNotificationCenter 的 removeDelivered 对齐。
            if !tag.isEmpty, tag == self.currentTag, self.currentId != nil {
                NSLog("[DshDock] 刘海通知同 tag 顶掉旧条：tag=%@", tag)
            }
            self.cancelTimer()
            self.currentId = id
            self.currentTag = tag
            self.currentHasActions = hasActions

            // 圆角随高度走（对齐原版 base = min(h/3, 16)，底部更大）。
            let bodyLines = max(1, (body.count + 39) / 40)
            var h: CGFloat = 14 + 20 + CGFloat(min(bodyLines, 3)) * 15 + 12
            if !actions.isEmpty { h += 14 + 35 }
            h = max(88, min(240, h))
            let base = min(h / 3, 16)
            let view = NotchToastView(
                toastId: id, title: title, message: body, actions: actions,
                topRadius: max(4, base - 4), bottomRadius: base + 8,
                revealOffset: h / 2,
                onBodyClick: { [weak self] in
                    onBodyClick()
                    self?.dismiss(id: id)
                },
                onAction: { [weak self] identifier in
                    onAction(identifier)
                    self?.dismiss(id: id)
                }
            )
            let panel = self.reusedPanel()
            let hosting = NSHostingView(rootView: view)
            let w: CGFloat = 360
            hosting.setFrameSize(NSSize(width: w, height: h))
            panel.contentView = hosting
            panel.setContentSize(NSSize(width: w, height: h))
            self.hosting = hosting
            // 进场：SwiftUI 插入转场（整体 scale + 淡入 + 上位移 spring）+
            // 窗口层 0.22s 淡入。落位断言保留：复用 panel 时 orderFront 之后
            // 原点偶发上跳（整个窗飞出可见区），二次落位次之。
            let target = self.anchorRect(width: w, height: h, id: id)
            panel.setFrame(target, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.setFrame(target, display: true)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            // 呈现自检：淡入播完后确认窗真的可见且位置正确，否则强制修复。
            self.verifyWork?.cancel()
            let verify = DispatchWorkItem { [weak self] in
                guard let self = self, self.currentId == id, let panel = self.panel else { return }
                let want = self.anchorRect(width: panel.frame.width, height: panel.frame.height)
                let off = abs(panel.frame.origin.x - want.origin.x)
                    + abs(panel.frame.origin.y - want.origin.y)
                NSLog("[DshDock] 刘海呈现自检：id=%@ visible=%d alpha=%.2f frame=%@ want=%@",
                      id, panel.isVisible, panel.alphaValue,
                      NSStringFromRect(panel.frame), NSStringFromRect(want))
                if !panel.isVisible || panel.alphaValue < 0.99 || off > 1 {
                    NSLog("[DshDock] 刘海呈现异常，强制修复：id=%@", id)
                    panel.setFrame(want, display: true)
                    panel.alphaValue = 1
                    panel.orderFrontRegardless()
                }
            }
            self.verifyWork = verify
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: verify)

            // 待审批（有按钮）常驻：不设自动消失，等用户点按钮/点正文回会话；
            // 纯文本仍按 dwell 自动收。
            if !hasActions {
                let dwell = Self.dwellTime(hasActions: false)
                let work = DispatchWorkItem { [weak self] in self?.dismiss(id: id) }
                self.dismissWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
            } else {
                NSLog("[DshDock] 刘海待审批常驻：id=%@ tag=%@", id, tag)
            }
            NSLog("[DshDock] 刘海通知呈现：id=%@ tag=%@ actions=%d", id, tag, actions.count)
        }
    }

    func dismiss(id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentId == id else { return }
            self.cancelTimer()
            self.currentId = nil
            self.currentTag = ""
            self.currentHasActions = false
            // 文本消失且有暂存审批：直接替换回来（show 自带进场，不先淡出）。
            if let p = self.parkedApproval {
                self.parkedApproval = nil
                NSLog("[DshDock] 刘海恢复暂存审批：id=%@", p.id)
                self.show(id: p.id, tag: p.tag, title: p.title, body: p.body, actions: p.actions,
                          onBodyClick: p.onBodyClick, onAction: p.onAction)
                return
            }
            self.displayedApproval = nil
            self.fadeOut()
        }
    }

    /// 页面发 close 时连暂存一起丢（审批已在别处处理，不再恢复）。
    func dropParked(id: String) {
        DispatchQueue.main.async { [weak self] in
            if self?.parkedApproval?.id == id { self?.parkedApproval = nil }
            if self?.displayedApproval?.id == id, self?.currentHasActions == false {
                self?.displayedApproval = nil
            }
        }
    }

    func dismissAll() {
        DispatchQueue.main.async { [weak self] in
            self?.cancelTimer()
            self?.currentId = nil
            self?.currentTag = ""
            self?.currentHasActions = false
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        guard let panel = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // 其间有新条呈现则不动（show 会重设 alpha 并 orderFront）。
            guard let self = self, self.currentId == nil else { return }
            panel.orderOut(nil)
            // 消失后销毁 panel：复用旧 panel 时 SwiftUI 插入转场偶发不播
            //（第二次无动效），每次重建可保证与第一次完全相同的起播条件。
            if self.panel === panel { self.panel = nil }
            self.hosting = nil
        })
    }

    private func cancelTimer() {
        dismissWork?.cancel()
        dismissWork = nil
        verifyWork?.cancel()
        verifyWork = nil
    }

    private func reusedPanel() -> NSPanel {
        if let p = panel { return p }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.level = .statusBar + 2
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        panel = p
        return p
    }

    /// 顶部贴住：优先跟 App 主窗口所在屏（用户眼睛看的地方；之前跟鼠标屏，
    /// 实测多屏下会出现"显示了但用户在看另一块屏"），其次鼠标屏，最后主屏。
    /// 返回目标矩形并落位（调用方做生长动画时用返回值做终态）。
    private func anchorRect(width: CGFloat, height: CGFloat, id: String) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let appScreen = NSApp.mainWindow?.screen ?? NSApp.windows.first(where: { $0.isVisible })?.screen
        let screen = appScreen ?? mouseScreen ?? NSScreen.main
        guard let s = screen else { return NSRect(x: 0, y: 0, width: width, height: height) }
        let anchor = s == appScreen ? "app" : (s == mouseScreen ? "mouse" : "main")
        NSLog("[DshDock] 刘海锚定屏：id=%@ %@ frame=%@", id, anchor, NSStringFromRect(s.frame))
        let x = s.frame.midX - width / 2
        let y = s.frame.maxY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// 按当前锚定策略算出目标矩形（不落位，供自检对比用）。
    private func anchorRect(width: CGFloat, height: CGFloat) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let appScreen = NSApp.mainWindow?.screen ?? NSApp.windows.first(where: { $0.isVisible })?.screen
        let screen = appScreen ?? mouseScreen ?? NSScreen.main
        guard let s = screen else { return NSRect(x: 0, y: 0, width: width, height: height) }
        let anchor = s == appScreen ? "app" : (s == mouseScreen ? "mouse" : "main")
        NSLog("[DshDock] 刘海锚定屏：%@ frame=%@", anchor, NSStringFromRect(s.frame))
        let x = s.frame.midX - width / 2
        let y = s.frame.maxY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
