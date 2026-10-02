import Cocoa
import WebKit

final class MainWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, NSPopoverDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    // 标题栏右侧按钮：titlebar accessory（不占 toolbar 行，标题栏保持系统默认高度）。
    private var webTopConstraint: NSLayoutConstraint!
    private var restartContainer: NSView!
    private var restartButton: NSButton!
    private var restartSpinner: NSProgressIndicator!
    private var interceptButton: NSButton!
    private var settingsButton: NSButton!
    private var loadingView: NSView!
    private var loadingLabel: NSTextField!
    private var bootArt: BootAnimationView!
    private var hintTimer: Timer?
    private var statusViewController: StatusViewController?

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
        // 插件重启接管：钩子按偏好注入（默认开），消息名 dshDockRestart → didTapRestart。
        wkConfig.userContentController.add(self, name: "dshDockRestart")
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
        applyRestartHookScript()

        buildLoadingView(into: content)
        buildStatusView(into: content)

        setupTitlebar(win: win)
    }

    /// 标题栏：交通灯居左（系统），重启/设置以 accessory 嵌在标题栏右侧。
    /// 不用 NSToolbar——toolbar 会独占一行把标题栏撑高；accessory 保持系统默认高度。
    /// 注意：accessory 视图不参与窗口级自动布局，一律用显式 frame（NSStackView
    /// 在这里会被压成 0 宽）；且总高不得超过标题栏 28pt，否则反而撑高标题栏。
    private func setupTitlebar(win: NSWindow) {
        // 布局（总 98x28）：[重启 34][接管开关 30][设置 30]，按钮 30x24 上下各留 2pt。
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 98, height: 28))

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

        interceptButton = NSButton(
            image: NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "插件重启接管") ?? NSImage(),
            target: self, action: #selector(didTapInterceptToggle))
        interceptButton.toolTip = "插件重启接管"
        interceptButton.isBordered = false
        interceptButton.imagePosition = .imageOnly
        interceptButton.setAccessibilityLabel("插件重启接管")
        interceptButton.frame = NSRect(x: 36, y: 2, width: 30, height: 24)
        bar.addSubview(interceptButton)

        settingsButton = NSButton(
            image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置") ?? NSImage(),
            target: self, action: #selector(didTapSettings))
        settingsButton.toolTip = "设置"
        settingsButton.isBordered = false
        settingsButton.imagePosition = .imageOnly
        settingsButton.setAccessibilityLabel("设置")
        settingsButton.frame = NSRect(x: 68, y: 2, width: 30, height: 24)
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

    private func buildStatusView(into content: NSView) {
        let vc = StatusViewController()
        vc.view.isHidden = true
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: content.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        vc.onRetry = { [weak self] in self?.didTapRetry() }
        vc.onOpenLogFile = { [weak self] in
            guard let url = self?.service.log.fileURL else { return }
            NSWorkspace.shared.open(url)
        }
        statusViewController = vc
    }

    private func buildLoadingView(into content: NSView) {
        // 全屏 + 居中纵列，对齐 dsh web 自带的 loading 页（CSS 实测值）：
        // logo 16pt semibold + 字间距 .08em，spinner 20px/2px 环/72° 弧/0.8s，
        // 提示语 12pt，纵列间距 16pt。颜色用语义色以适配深色模式。
        let full = NSView()
        full.wantsLayer = true
        full.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        full.translatesAutoresizingMaskIntoConstraints = false
        full.isHidden = true
        content.addSubview(full)
        NSLayoutConstraint.activate([
            full.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            full.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            full.topAnchor.constraint(equalTo: content.topAnchor),
            full.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        loadingView = full

        let logo = NSTextField(labelWithString: "")
        logo.attributedStringValue = NSAttributedString(string: "DSH-DOCK", attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .kern: 1.28, // .08em
        ])
        logo.alignment = .center

        bootArt = BootAnimationView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        bootArt.translatesAutoresizingMaskIntoConstraints = false
        bootArt.widthAnchor.constraint(equalToConstant: 20).isActive = true
        bootArt.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let label = NSTextField(labelWithString: "正在启动 dsh…")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 2
        loadingLabel = label

        let stack = NSStackView(views: [logo, bootArt, label])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        full.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: full.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: full.centerYAnchor),
        ])
    }

    /// 启动/重启时的轮播提示语（2.4s 一换）。
    private func bootHints() -> [String] {
        [
            "正在叫醒 dsh…",
            "正在给 \(config.port) 端口铺红毯…",
            "正在破解 token 封印…",
            "正在和 127.0.0.1 握手…",
            "正在梳理日志发型…",
            "正在热机，马上就好…",
        ]
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
                detail: "换个端口，或强制结束占用该端口的进程后重试。",
                logTail: service.log.tail(40),
                retryTitle: nil,
                port: p)
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
        statusViewController?.view.isHidden = true
        webView.isHidden = false
        bootArt.stop()
        hintTimer?.invalidate()
        hintTimer = nil
    }

    private func showLoading(_ text: String) {
        webView.isHidden = true
        statusViewController?.view.isHidden = true
        loadingView.isHidden = false
        loadingLabel.stringValue = text
        bootArt.start()
        hintTimer?.invalidate()
        hintTimer = nil
        let hints = bootHints()
        var i = 0
        hintTimer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: true) { [weak self] _ in
            guard let self = self, !self.loadingView.isHidden else { return }
            self.loadingLabel.stringValue = hints[i % hints.count]
            i += 1
        }
    }

    private func showStatus(title: String, detail: String, logTail: String, retryTitle: String?, port: Int? = nil) {
        webView.isHidden = true
        loadingView.isHidden = true
        bootArt.stop()
        hintTimer?.invalidate()
        hintTimer = nil
        guard let statusVC = statusViewController else { return }
        statusVC.view.isHidden = false
        statusVC.configure(title: title, detail: detail, logTail: logTail, retryTitle: retryTitle)
        guard let port else { return }
        // 端口占用：给"强制结束并重启"红色按钮；占用进程名异步补进详情（lsof）。
        statusVC.setForceKill(occupant: nil)
        statusVC.onForceKillAndRestart = { [weak self] in self?.forceKillAndRestart(port: port) }
        Task.detached { [weak self] in
            let occ = self?.service.portOccupants(port: port) ?? []
            let desc = occ.map(\.description).joined(separator: "、")
            await MainActor.run {
                self?.statusViewController?.setForceKill(occupant: desc.isEmpty ? nil : desc)
            }
        }
    }

    /// 强杀占用进程（SIGKILL）→ 等 OS 释放端口 → 走常规重启。
    private func forceKillAndRestart(port: Int) {
        showLoading("正在强制结束占用端口 \(port) 的进程…")
        Task.detached { [weak self] in
            let killed = self?.service.forceKillPortOccupants(port: port) ?? []
            NSLog("[DshDock] 强制结束占用端口 %d 的进程：%@", port,
                  killed.map(\.description).joined(separator: "、"))
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { self?.didTapRestart() }
        }
    }

    // MARK: - actions

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

    /// 接管开关弹层（参考菜单栏弹层样式：标题 + NSSwitch + 灰色说明）。
    @objc private func didTapInterceptToggle() {
        if popover != nil { return }
        let vc = InterceptToggleViewController(isOn: AppPreferences.interceptPluginRestart)
        vc.onChange = { [weak self] on in
            AppPreferences.interceptPluginRestart = on
            self?.applyRestartHookScript()
        }
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.delegate = self
        self.popover = pop
        pop.show(relativeTo: interceptButton.bounds,
                 of: interceptButton, preferredEdge: .minY)
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
            // 插件重启完成后客户端拿旧 token 做 location.reload()（新进程 token 已换），
            // 放行必 401 白页——发现导航 token ≠ 当前服务 token 就取消并重载当前 token URL。
            if let healed = healedTokenURL(navigating: url) {
                NSLog("[DshDock] 导航携带过期 token，纠正到当前 token URL")
                decisionHandler(.cancel)
                webView.load(URLRequest(url: healed))
                return
            }
            decisionHandler(.allow)
            return
        }
        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    /// 导航 URL 的 token 与当前服务 token 不一致时返回当前 token URL，否则 nil。
    private func healedTokenURL(navigating url: URL) -> URL? {
        guard let current = service.serviceURL else { return nil }
        guard let navToken = Self.queryToken(of: url),
              let currentToken = Self.queryToken(of: current),
              navToken != currentToken else { return nil }
        return current
    }

    private static func queryToken(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "token" }?.value
    }

    /// 注入 WebView 的 fetch 钩子：拦截 dsh-market 的一键重启（客户端用 fetch POST
    /// …/dsh-market/restart，重启守卫与轮询逻辑都建立在它之上）。命中后 postMessage
    /// 给原生并返回合成 202 {ok:true}（与真实端点成功形态一致），真请求不出网——
    /// dsh 的 detached 重启助手永远不会运行，服务上不会出现 App 管不到的接管进程，
    /// 重启完全由原生接管（stop 优雅退出 → 新 token）。客户端随后轮询
    /// /dsh-market/status，bootId 变化后自己 location.reload()，旧 token 由
    /// decidePolicyFor 纠正。
    /// 开关：脚本头部烤入 `__dshDockInterceptEnabled`，fetch 时再读一次——这样
    /// 关闭后"已经包装过的当前页面"也会放行真实请求（配合切换时的 evaluateJavaScript）。
    private static func restartHookSource(enabled: Bool) -> String {
        """
        (function () {
          if (window.__dshDockRestartHooked) return;
          window.__dshDockRestartHooked = true;
          window.__dshDockInterceptEnabled = \(enabled);
          const originalFetch = window.fetch;
          window.fetch = function (input, init) {
            try {
              if (window.__dshDockInterceptEnabled !== false) {
                const url = typeof input === 'string' ? input : (input && input.url) || '';
                const method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
                if (method === 'POST' && url.indexOf('/dsh-market/') !== -1 && /\\/restart$/.test(url.split('?')[0])) {
                  const handlers = window.webkit && window.webkit.messageHandlers;
                  if (handlers && handlers.dshDockRestart) handlers.dshDockRestart.postMessage('restart');
                  return Promise.resolve(new Response(JSON.stringify({ ok: true }), {
                    status: 202,
                    headers: { 'content-type': 'application/json' }
                  }));
                }
              }
            } catch (e) {}
            return originalFetch.apply(this, arguments);
          };
        })();
        """
    }

    /// 按偏好（重）注入钩子脚本：user scripts 只对之后的页面加载生效，
    /// 当前已加载的页面用 evaluateJavaScript 同步开关标记即时生效。
    private func applyRestartHookScript() {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        let enabled = AppPreferences.interceptPluginRestart
        if enabled {
            ucc.addUserScript(WKUserScript(source: Self.restartHookSource(enabled: true),
                                           injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        interceptButton?.image = NSImage(systemSymbolName: enabled ? "hand.raised" : "hand.raised.slash",
                                         accessibilityDescription: "插件重启接管")
        webView.evaluateJavaScript("window.__dshDockInterceptEnabled = \(enabled)", completionHandler: nil)
    }

    // MARK: - WKScriptMessageHandler（插件重启接管）

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "dshDockRestart" else { return }
        NSLog("[DshDock] 插件请求重启，接管执行")
        didTapRestart()
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

/// 接管开关弹层（对齐菜单栏弹层参考稿：标题行 + NSSwitch 靠右 + 灰色说明）。
/// internal 便于无头渲染验证（AGENTS 红线 9）。
final class InterceptToggleViewController: NSViewController {
    var onChange: ((Bool) -> Void)?
    private let switchControl = NSSwitch()

    init(isOn: Bool) {
        super.init(nibName: nil, bundle: nil)
        switchControl.state = isOn ? .on : .off
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        view = root
        // 不透明底：popover 默认半透明，会被背后深色网页染灰（同设置页实测）。
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        let width: CGFloat = 264
        let title = NSTextField(labelWithString: "插件重启接管")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        switchControl.target = self
        switchControl.action = #selector(didToggle)
        let rowSpacer = NSView()
        rowSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        rowSpacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [title, rowSpacer, switchControl])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        let desc = NSTextField(labelWithString: "开启后，插件里的「立即重启」由 DshDock 接管：优雅重启服务并自动恢复页面。关闭后由 dsh 自行重启，服务退出后需手动恢复。")
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        // label 默认单行不折行：必须开 cell.wraps，intrinsic 高度才会按宽约束算成多行。
        desc.cell?.wraps = true
        desc.cell?.lineBreakMode = .byWordWrapping
        desc.usesSingleLineMode = false
        desc.preferredMaxLayoutWidth = width  // 没有它 autolayout 始终按单行测高（实测）

        let stack = NSStackView(views: [row, desc])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            stack.widthAnchor.constraint(equalToConstant: width),
            row.widthAnchor.constraint(equalToConstant: width),
            desc.widthAnchor.constraint(equalToConstant: width),
        ])
    }

    @objc private func didToggle() {
        onChange?(switchControl.state == .on)
    }
}
