import Cocoa

/// 原生状态/错误页（参考 Chrome 断网页布局）：全页浅底、左对齐内容列——
/// 灰色警示图形 + 大标题 + 灰色说明；左下主按钮（+ 端口占用时的红色强杀按钮），
/// 右下"详情"链接：展开日志块（详细错误日志 + 打开日志文件）。
final class StatusViewController: NSViewController {
    var onRetry: (() -> Void)?
    var onForceKillAndRestart: (() -> Void)?
    var onOpenLogFile: (() -> Void)?

    private var baseDetail = ""
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let logView = NSTextView()
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let forceButton = NSButton(title: "强制结束并重启", target: nil, action: nil)
    private let detailsButton = NSButton(title: "", target: nil, action: nil)
    private let openLogButton = NSButton(title: "", target: nil, action: nil)
    private let logSection = NSStackView()
    private let contentWidth: CGFloat = 520

    override func loadView() {
        let page = NSView()
        view = page
        page.wantsLayer = true
        page.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        // ---- 内容列（左对齐） ----
        // 错误插画（Assets: ErrorWhale）只钉宽度，高度按位图宽高比推，别写死比例。
        iconView.image = NSImage(named: "ErrorWhale")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let iconWidth: CGFloat = 140
        iconView.widthAnchor.constraint(equalToConstant: iconWidth).isActive = true
        if let icon = iconView.image, icon.size.width > 0 {
            iconView.heightAnchor.constraint(
                equalToConstant: iconWidth * icon.size.height / icon.size.width
            ).isActive = true
        }

        titleLabel.font = .systemFont(ofSize: 24)
        titleLabel.maximumNumberOfLines = 2
        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.maximumNumberOfLines = 4

        // ---- 按钮行：左 = 主按钮（+可选红色强杀），右 = "详情"链接 ----
        styleFilled(primaryButton, color: .systemBlue, width: 112)
        primaryButton.target = self
        primaryButton.action = #selector(didRetry)
        styleFilled(forceButton, color: .systemRed, width: 160)
        forceButton.target = self
        forceButton.action = #selector(didForce)
        forceButton.isHidden = true
        styleLink(detailsButton, "详情")
        detailsButton.target = self
        detailsButton.action = #selector(didToggleDetails)

        let leftButtons = NSStackView(views: [primaryButton, forceButton])
        leftButtons.orientation = .horizontal
        leftButtons.spacing = 10
        leftButtons.alignment = .centerY
        let btnSpacer = NSView()
        btnSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        btnSpacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let btnRow = NSStackView(views: [leftButtons, btnSpacer, detailsButton])
        btnRow.orientation = .horizontal
        btnRow.spacing = 0
        btnRow.alignment = .centerY

        // ---- 日志块（默认收起，"详情"展开） ----
        logView.isEditable = false
        logView.isSelectable = true
        logView.drawsBackground = false
        logView.textContainerInset = NSSize(width: 10, height: 8)
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        // 不做宽度跟随的话 documentView 停在零宽 frame，日志一行都画不出来（旧页实测）。
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        let logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.drawsBackground = false
        logScroll.translatesAutoresizingMaskIntoConstraints = false

        let logBox = NSView()
        logBox.wantsLayer = true
        logBox.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        logBox.layer?.cornerRadius = 8
        logBox.addSubview(logScroll)
        NSLayoutConstraint.activate([
            logScroll.leadingAnchor.constraint(equalTo: logBox.leadingAnchor),
            logScroll.trailingAnchor.constraint(equalTo: logBox.trailingAnchor),
            logScroll.topAnchor.constraint(equalTo: logBox.topAnchor),
            logScroll.bottomAnchor.constraint(equalTo: logBox.bottomAnchor),
            logBox.heightAnchor.constraint(equalToConstant: 180),
        ])

        let logHint = NSTextField(labelWithString: "最近日志（含启动命令与错误输出，最多 200 行）")
        logHint.font = .systemFont(ofSize: 12)
        logHint.textColor = .secondaryLabelColor
        styleLink(openLogButton, "打开日志文件")
        openLogButton.target = self
        openLogButton.action = #selector(didOpenLog)
        let logHeaderSpacer = NSView()
        logHeaderSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        logHeaderSpacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let logHeader = NSStackView(views: [logHint, logHeaderSpacer, openLogButton])
        logHeader.orientation = .horizontal
        logHeader.spacing = 0
        logHeader.alignment = .centerY

        logSection.orientation = .vertical
        logSection.alignment = .leading
        logSection.spacing = 8
        logSection.addArrangedSubview(logHeader)
        logSection.addArrangedSubview(logBox)
        logSection.isHidden = true

        // ---- 纵列拼装 ----
        let stack = NSStackView(views: [iconView, titleLabel, detailLabel, btnRow, logSection])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: iconView)
        stack.setCustomSpacing(6, after: titleLabel)
        stack.setCustomSpacing(40, after: detailLabel)
        stack.setCustomSpacing(20, after: btnRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: page.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: contentWidth),
        ])
        // 标题/说明、按钮行、日志区全部铺满列宽（详情链接贴列右缘）。
        [titleLabel, detailLabel].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            btnRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            logSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            logBox.widthAnchor.constraint(equalTo: logSection.widthAnchor),
            logHeader.widthAnchor.constraint(equalTo: logSection.widthAnchor),
        ])
    }

    // MARK: - 样式

    /// 自绘按钮：纯色圆角 + 白字居中（系统 .rounded bezel 是胶囊形，与应用内其他主按钮不一致）。
    private func styleFilled(_ b: NSButton, color: NSColor, width: CGFloat) {
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = color.cgColor
        b.layer?.cornerRadius = 8
        b.attributedTitle = filledTitle(b.title)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    private func filledTitle(_ title: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        return NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ])
    }

    private func styleLink(_ b: NSButton, _ title: String) {
        b.isBordered = false
        b.attributedTitle = linkTitle(title)
    }

    private func linkTitle(_ title: String) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
    }

    // MARK: - 状态注入

    /// retryTitle 传 nil 表示本场景无重试（如端口占用，只剩强制结束并重启）。
    func configure(title: String, detail: String, logTail: String, retryTitle: String?) {
        titleLabel.stringValue = title
        baseDetail = detail
        detailLabel.stringValue = detail
        logView.string = logTail
        logView.scrollToEndOfDocument(nil)
        if let retryTitle {
            primaryButton.isHidden = false
            primaryButton.attributedTitle = filledTitle(retryTitle)
            primaryButton.keyEquivalent = "\r"
        } else {
            primaryButton.isHidden = true
            primaryButton.keyEquivalent = ""
        }
        forceButton.isHidden = true
        onForceKillAndRestart = nil
        setDetailsOpen(false)
    }

    /// 端口占用场景：显示红色强制结束按钮；查到占用进程后在说明里补一行。
    func setForceKill(occupant: String?) {
        forceButton.isHidden = false
        if let occupant, !occupant.isEmpty {
            detailLabel.stringValue = baseDetail + "\n占用进程：\(occupant)"
        }
    }

    /// "详情"展开/收起日志块（也供无头渲染测试驱动）。
    func setDetailsOpen(_ open: Bool) {
        logSection.isHidden = !open
        styleLink(detailsButton, open ? "收起详情" : "详情")
    }

    // MARK: - 动作

    @objc private func didRetry() { onRetry?() }
    @objc private func didForce() { onForceKillAndRestart?() }
    @objc private func didOpenLog() { onOpenLogFile?() }
    @objc private func didToggleDetails() { setDetailsOpen(logSection.isHidden) }
}
