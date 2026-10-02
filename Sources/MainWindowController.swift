import Cocoa
import WebKit

final class MainWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, NSPopoverDelegate {
    private var webView: WKWebView!
    // 标题栏右侧按钮：titlebar accessory（不占 toolbar 行，标题栏保持系统默认高度）。
    private var webTopConstraint: NSLayoutConstraint!
    private var restartContainer: NSView!
    private var restartButton: NSButton!
    private var restartSpinner: NSProgressIndicator!
    private var settingsButton: NSButton!
    private var loadingView: NSView!
    private var loadingLabel: NSTextField!
    private var loadingLog: NSTextView!
    private var statusView: NSView!
    private var statusTitle: NSTextField!
    private var statusDetail: NSTextField!
    private var statusLog: NSTextView!
    private var statusRetryButton: NSButton!
    private var statusSettingsButton: NSButton!
    private var statusCopyButton: NSButton!

    private let service = DshService()
    private var config = DshConfig.load()
    private var popover: NSPopover?
    private var bootTask: Task<Void, Never>?

    // MARK: - init

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "DshDock"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.minSize = NSSize(width: 900, height: 600)
        win.setFrameAutosaveName("DshDockMain")
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        setupViews(win: win)
        bindService()
        boot()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 视图搭建

    private func setupViews(win: NSWindow) {
        guard let content = win.contentView else { return }
        content.wantsLayer = true

        let wkConfig = WKWebViewConfiguration()
        wkConfig.websiteDataStore = .default()
        // 本地明文由 Info.plist NSAllowsLocalNetworking 放行
        webView = WKWebView(frame: .zero, configuration: wkConfig)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(webView)
        // fullSizeContentView 下内容会伸到透明标题栏底下，顶部按标题栏高度避让。
        webTopConstraint = webView.topAnchor.constraint(equalTo: content.topAnchor)
        webTopConstraint.isActive = true
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        // 注意：别往 webView 上加 NSClickGestureRecognizer 之类的手势，
        // 它们会拦截鼠标事件导致页面点不动（实测）。刷新走菜单 Cmd+R。

        buildLoadingView(into: content)
        buildStatusView(into: content)

        setupTitlebar(win: win)
    }

    /// 标题栏：交通灯居左（系统），重启/设置以 accessory 嵌在标题栏右侧。
    /// 不用 NSToolbar——toolbar 会独占一行把标题栏撑高；accessory 保持系统默认高度。
    /// 注意：accessory 视图不参与窗口级自动布局，一律用显式 frame（NSStackView
    /// 在这里会被压成 0 宽）；且总高不得超过标题栏 28pt，否则反而撑高标题栏。
    private func setupTitlebar(win: NSWindow) {
        // 布局（总 66x28）：[重启 34][间距 2][设置 30]，按钮 30x24 上下各留 2pt。
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 66, height: 28))

        restartContainer = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: 28))
        bar.addSubview(restartContainer)

        restartButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重启 dsh 服务") ?? NSImage(),
            target: self, action: #selector(didTapRestart))
        restartButton.toolTip = "重启 dsh 服务"
        restartButton.isBordered = false
        restartButton.imagePosition = .imageOnly
        restartButton.setAccessibilityLabel("重启")
        restartButton.frame = NSRect(x: 2, y: 2, width: 30, height: 24)
        restartContainer.addSubview(restartButton)

        restartSpinner = NSProgressIndicator(frame: NSRect(x: 9, y: 6, width: 16, height: 16))
        restartSpinner.style = .spinning
        restartSpinner.controlSize = .small
        restartSpinner.isDisplayedWhenStopped = false
        restartSpinner.isHidden = true
        restartContainer.addSubview(restartSpinner)

        settingsButton = NSButton(
            image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置") ?? NSImage(),
            target: self, action: #selector(didTapSettings))
        settingsButton.toolTip = "设置"
        settingsButton.isBordered = false
        settingsButton.imagePosition = .imageOnly
        settingsButton.setAccessibilityLabel("设置")
        settingsButton.frame = NSRect(x: 36, y: 2, width: 30, height: 24)
        bar.addSubview(settingsButton)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = bar
        accessory.layoutAttribute = .trailing
        win.addTitlebarAccessoryViewController(accessory)

        // WebView 顶部避让标题栏（透明标题栏下内容会透上去）。
        win.layoutIfNeeded()
        webTopConstraint.constant = Self.titlebarHeight(of: win)
        // 调试：确认 accessory 已挂载且有尺寸（sweetpad app logs 可见）。
        DispatchQueue.main.async {
            let n = win.titlebarAccessoryViewControllers.count
            NSLog("[DshDock] accessoryCount=%d bar=%@ restartBtn=%@ settingsBtn=%@ titlebarH=%.1f",
                  n,
                  NSStringFromRect(bar.frame),
                  NSStringFromRect(self.restartButton.frame),
                  NSStringFromRect(self.settingsButton.frame),
                  Self.titlebarHeight(of: win))
        }
    }

    /// 标题栏高度（content 坐标系下被标题栏占掉的顶部高度），算不出则回退 28。
    private static func titlebarHeight(of win: NSWindow) -> CGFloat {
        if let content = win.contentView {
            let topInset = content.bounds.maxY - win.contentLayoutRect.maxY
            if topInset > 0 && topInset < 60 { return topInset }
        }
        return 28
    }

    private func makeOverlayCard(into content: NSView) -> NSView {
        let card = NSVisualEffectView()
        card.material = .sidebar
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false
        card.isHidden = true
        content.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 520),
        ])
        return card
    }

    private func makeLogView() -> (NSScrollView, NSTextView) {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 8, height: 6)
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.heightAnchor.constraint(equalToConstant: 140).isActive = true
        return (sv, tv)
    }

    private func buildLoadingView(into content: NSView) {
        let card = makeOverlayCard(into: content)
        loadingView = card
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "正在启动 dsh…")
        label.font = .boldSystemFont(ofSize: 14)
        loadingLabel = label
        let (sv, tv) = makeLogView()
        loadingLog = tv
        let cancel = NSButton(title: "取消", target: self, action: #selector(didCancelBoot))
        cancel.bezelStyle = .rounded
        let stack = NSStackView(views: [spinner, label, sv, cancel])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
        // 定时把 ring 日志刷到 loadingLog
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self = self, !self.loadingView.isHidden else { return }
            let tail = self.service.log.tail(30)
            if self.loadingLog.string != tail {
                self.loadingLog.string = tail
                self.loadingLog.scrollToEndOfDocument(nil)
            }
        }
    }

    private func buildStatusView(into content: NSView) {
        let card = makeOverlayCard(into: content)
        statusView = card
        let title = NSTextField(labelWithString: "")
        title.font = .boldSystemFont(ofSize: 14)
        statusTitle = title
        let detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 4
        statusDetail = detail
        let (sv, tv) = makeLogView()
        statusLog = tv
        let retry = NSButton(title: "重试", target: self, action: #selector(didTapRetry))
        retry.bezelStyle = .rounded
        retry.keyEquivalent = "\r"
        let settings = NSButton(title: "打开设置", target: self, action: #selector(didTapSettings))
        settings.bezelStyle = .rounded
        let copy = NSButton(title: "复制诊断命令", target: self, action: #selector(didTapCopy))
        copy.bezelStyle = .rounded
        statusRetryButton = retry
        statusSettingsButton = settings
        statusCopyButton = copy
        let btns = NSStackView(views: [retry, settings, copy])
        btns.orientation = .horizontal
        btns.spacing = 8
        let stack = NSStackView(views: [title, detail, sv, btns])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
    }

    // MARK: - service 绑定与启动流

    private func bindService() {
        service.onStateChange = { _ in
            // 预留：可在此同步重启按钮菊花态
        }
        service.onUnexpectedExit = { [weak self] code in
            guard let self = self else { return }
            self.showStatus(
                title: "dsh 意外退出（exit=\(code)）",
                detail: "服务在运行中挂掉了，看看日志尾再重试或改配置。",
                logTail: self.service.log.tail(100),
                retryTitle: "重启"
            )
        }
    }

    private func boot() {
        bootTask?.cancel()
        showLoading("正在启动 dsh…")
        bootTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.service.start(config: self.config)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.hideOverlays()
                    self.loadServiceURL()
                }
            } catch let e as DshLaunchError {
                guard !Task.isCancelled else { return }
                await MainActor.run { self.present(launchError: e) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.showStatus(title: "启动失败", detail: error.localizedDescription,
                                    logTail: self.service.log.tail(100), retryTitle: "重试")
                }
            }
        }
    }

    private func present(launchError e: DshLaunchError) {
        switch e {
        case .binaryMissing(let searched):
            showStatus(
                title: "找不到 dsh",
                detail: "已搜索 login-shell PATH 与固定路径，均未找到 dsh；npx 也不可用。\n可先用 npm 全局安装：npm install -g @deepseek-ai/dsh@latest\n已搜：\(searched.prefix(6).joined(separator: "\n"))",
                logTail: service.log.tail(40),
                retryTitle: "重试"
            )
        case .invalidBinary(let s):
            showStatus(
                title: "二进制不可用",
                detail: "设置里的 Binary Path 不可执行：\(s)\n请打开设置修正，或改回默认 dsh。",
                logTail: service.log.tail(40),
                retryTitle: "重试"
            )
        case .portOccupied(let p):
            showStatus(
                title: "端口 \(p) 已被占用",
                detail: "换个端口，或停掉占用该端口的进程后重试。",
                logTail: service.log.tail(40),
                retryTitle: "重试"
            )
        case .exited(let code, let tail):
            showStatus(
                title: "dsh 启动后退出（exit=\(code)）",
                detail: "把诊断命令复制到终端跑一遍，通常能看到根本原因。",
                logTail: tail,
                retryTitle: "重启"
            )
        case .timeout(let tail):
            showStatus(
                title: "dsh 启动超时",
                detail: "10s 内未就绪（HTTP 探针 + TCP 兜底均失败）。",
                logTail: tail,
                retryTitle: "重试"
            )
        }
    }

    private func loadServiceURL() {
        // dsh 打印的 token URL 才是真实入口（裸 `/` 只会 401），service 已从 stdout 解析。
        let url = service.serviceURL ?? URL(string: "http://127.0.0.1:\(config.port)/")!
        webView.load(URLRequest(url: url))
    }

    // MARK: - overlays

    private func hideOverlays() {
        loadingView.isHidden = true
        statusView.isHidden = true
        webView.isHidden = false
    }

    private func showLoading(_ text: String) {
        webView.isHidden = true
        statusView.isHidden = true
        loadingView.isHidden = false
        loadingLabel.stringValue = text
        loadingLog.string = service.log.tail(30)
    }

    private func showStatus(title: String, detail: String, logTail: String, retryTitle: String) {
        webView.isHidden = true
        loadingView.isHidden = true
        statusView.isHidden = false
        statusTitle.stringValue = title
        statusDetail.stringValue = detail
        statusLog.string = logTail
        statusRetryButton.title = retryTitle
        statusLog.scrollToEndOfDocument(nil)
    }

    // MARK: - actions

    @objc private func didCancelBoot() {
        bootTask?.cancel()
        Task { [weak self] in
            guard let self = self else { return }
            await self.service.stop(grace: 2)
            await MainActor.run {
                self.showStatus(title: "已取消启动", detail: "点重试可重新拉起 dsh。",
                                logTail: self.service.log.tail(40), retryTitle: "重试")
            }
        }
    }

    @objc private func didTapRetry() {
        boot()
    }

    @objc private func didTapRestart() {
        if service.state == .starting || service.state == .stopping { return }
        setRestartingUI(true)
        showLoading("正在重启 dsh…（等旧进程退出）")
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.service.restart(config: self.config)
                await MainActor.run {
                    self.setRestartingUI(false)
                    self.hideOverlays()
                    self.loadServiceURL()
                }
            } catch let e as DshLaunchError {
                await MainActor.run {
                    self.setRestartingUI(false)
                    self.present(launchError: e)
                }
            } catch {
                await MainActor.run {
                    self.setRestartingUI(false)
                    self.showStatus(title: "重启失败", detail: error.localizedDescription,
                                    logTail: self.service.log.tail(100), retryTitle: "重试")
                }
            }
        }
    }

    @objc private func didTapSettings() {
        if popover != nil { return }
        let vc = SettingsViewController(config: config, providerText: service.providerDescription)
        vc.onApply = { [weak self] newCfg in
            guard let self = self else { return }
            self.popover?.close()
            newCfg.save()
            self.config = newCfg
            self.didTapRestart()
        }
        vc.onCancel = { [weak self] in
            self?.popover?.close()
        }
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.delegate = self
        self.popover = pop
        pop.show(relativeTo: settingsButton.bounds,
                 of: settingsButton, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }

    @objc private func didTapCopy() {
        let cmd = service.diagnosticCommand()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd.isEmpty ? "（暂无诊断命令，先启动一次）" : cmd, forType: .string)
    }

    @objc func reloadWebView() {
        webView.reload()
    }

    func terminateServiceForQuit() {
        bootTask?.cancel()
        service.terminateForQuit()
    }

    // MARK: - 标题栏按钮状态 + NSToolbarDelegate

    /// 重启中：按钮换成菊花，两个按钮都禁用。
    private func setRestartingUI(_ b: Bool) {
        restartButton.isHidden = b
        restartSpinner.isHidden = !b
        if b { restartSpinner.startAnimation(nil) } else { restartSpinner.stopAnimation(nil) }
        restartButton.isEnabled = !b
        settingsButton.isEnabled = !b
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 红灯 = 隐藏窗口（dsh 服务继续跑），Dock 点按可重新打开；退出走 Cmd+Q。
        NSLog("[DshDock] windowShouldClose -> hide instead of close")
        sender.orderOut(sender)
        return false
    }

    // MARK: - WKNavigationDelegate / UIDelegate

    private func isLocalHost(_ url: URL?) -> Bool {
        guard let h = url?.host?.lowercased() else { return false }
        return h == "127.0.0.1" || h == "localhost" || h == "::1"
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if isLocalHost(url) {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, !isLocalHost(url) {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}
