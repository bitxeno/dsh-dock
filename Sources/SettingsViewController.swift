import Cocoa

/// 深色圆角 terminal 图标（`>_` + 蓝色辉光边）。
private final class TerminalIconView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14)
        NSColor(white: 0.12, alpha: 1.0).setFill()
        box.fill()
        NSColor.systemBlue.withAlphaComponent(0.55).setStroke()
        box.lineWidth = 2.5
        box.stroke()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (">_" as NSString).draw(
            in: NSRect(x: 0, y: bounds.height / 2 - 15, width: bounds.width, height: 30),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
            ])
    }
}

/// 设置页：对齐 dsh 桌面端设置窗口（图标头 + 图标行 + 右下主按钮，无取消）。
final class SettingsViewController: NSViewController {
    var onApply: ((DshConfig) -> Void)?

    private var config: DshConfig
    private var providerText: String
    /// 竖屏内容宽：输入框独占一行（对齐参考稿 ~300pt 内容宽的窄长卡片）。
    private let contentWidth: CGFloat = 300

    private let binaryField = NSTextField()
    private let extraField = NSTextField()
    private let portField = NSTextField()
    private let portStepper = NSStepper()
    private let errorLabel = NSTextField(labelWithString: "")

    init(config: DshConfig, providerText: String) {
        self.config = config
        self.providerText = providerText
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        view = root
        // 不透明底：popover 默认半透明会被背后深色网页染灰，对齐参考稿的纯白卡片。
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        // ---- 头部 ----
        let icon = TerminalIconView(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let name = NSTextField(labelWithString: "dsh")
        name.font = .boldSystemFont(ofSize: 22)
        let subtitle = NSTextField(labelWithString: "服务设置")
        subtitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let desc = NSTextField(labelWithString: "配置 dsh 相关参数，用于启动和管理服务。")
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [name, subtitle, desc])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        let header = NSStackView(views: [icon, titles])
        header.orientation = .horizontal
        header.spacing = 14
        header.alignment = .centerY

        // ---- 行（竖屏）：图标+标题/副标题在上，输入框独占一行在下 ----
        binaryField.stringValue = config.binaryPath
        binaryField.placeholderString = "dsh"
        binaryField.bezelStyle = .roundedBezel
        // 备注按实际功能（不照抄参考稿）：Binary Path 行 = 输入提示 + 当前生效的
        // provider（供给链解析结果，可能与输入不同：裸名字/自定义/ npx 形态都在这区分）。
        let binaryRow = makeFieldRow(icon: "doc.text", title: "Binary Path",
                                     sub: "请输入 dsh，可填绝对路径\n当前生效：\(providerText)",
                                     field: binaryField)

        extraField.stringValue = config.extraArgs
        extraField.placeholderString = "例如：--verbose"
        extraField.bezelStyle = .roundedBezel
        let extraRow = makeFieldRow(icon: "chevron.left.forwardslash.chevron.right", title: "Extra Args",
                                    sub: "附加参数，端口由下方字段注入", field: extraField)

        portField.stringValue = String(config.port)
        portField.placeholderString = "38811"
        portField.bezelStyle = .roundedBezel
        portStepper.minValue = 1
        portStepper.maxValue = 65535
        portStepper.increment = 1
        portStepper.integerValue = min(max(config.port, 1), 65535)
        portStepper.target = self
        portStepper.action = #selector(didStepPort)
        // stepper 内嵌在输入框右缘（对齐参考稿），不是旁边挂一个独立控件。
        portStepper.translatesAutoresizingMaskIntoConstraints = false
        portStepper.heightAnchor.constraint(equalToConstant: 24).isActive = true
        portField.addSubview(portStepper)
        NSLayoutConstraint.activate([
            portStepper.trailingAnchor.constraint(equalTo: portField.trailingAnchor, constant: -6),
            portStepper.centerYAnchor.constraint(equalTo: portField.centerYAnchor),
        ])
        let portRow = makeFieldRow(icon: "network", title: "Port (1–65535)",
                                   sub: "dsh web 服务监听端口，应用后生效", field: portField)

        // ---- 错误行 + 分割线 + 右下主按钮（无取消，点弹层外关闭） ----
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3
        errorLabel.isHidden = true

        let divider = NSBox()
        divider.boxType = .separator

        // 自绘主按钮对齐参考稿：蓝底圆角矩形（系统 .rounded bezel 在此高度是胶囊形，
        // 与参考稿的圆角矩形不符），白字居中，尺寸 ~118x38。
        let apply = NSButton(title: "", target: self, action: #selector(didApply))
        apply.isBordered = false
        apply.wantsLayer = true
        apply.layer?.backgroundColor = NSColor.systemBlue.cgColor
        apply.layer?.cornerRadius = 8
        let titlePara = NSMutableParagraphStyle()
        titlePara.alignment = .center
        apply.attributedTitle = NSAttributedString(string: "应用并重启", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: titlePara,
        ])
        apply.keyEquivalent = "\r"
        // 右下角单颗主按钮：纵向 stack 左对齐，低 hugging 的 spacer 顶到右边。
        apply.translatesAutoresizingMaskIntoConstraints = false
        apply.widthAnchor.constraint(equalToConstant: 118).isActive = true
        apply.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let btnSpacer = NSView()
        btnSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        btnSpacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let btnRow = NSStackView(views: [btnSpacer, apply])
        btnRow.orientation = .horizontal
        btnRow.spacing = 0
        btnRow.translatesAutoresizingMaskIntoConstraints = false
        btnRow.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let stack = NSStackView(views: [header, binaryRow, extraRow, portRow, errorLabel, divider, btnRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: contentWidth),
        ])
    }

    /// 一行（竖屏）：上 = 图标 + 标题/副标题，下 = 独占一行的输入区。
    private func makeFieldRow(icon symbol: String, title: String, sub: String, field: NSView) -> NSView {
        // 字形放大到 ~18pt（frame 仍 24 宽，保住"缩进 34 = 图标 24 + 间距 10"的对齐）。
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage()
        let img = base.withSymbolConfiguration(.init(pointSize: 18, weight: .regular)) ?? base
        img.isTemplate = true
        let iconView = NSImageView(image: img)
        iconView.contentTintColor = .systemGray
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 24).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let subLabel = NSTextField(labelWithString: sub)
        subLabel.font = .systemFont(ofSize: 12)
        subLabel.textColor = .secondaryLabelColor
        subLabel.maximumNumberOfLines = 3 // 二行结构（提示 + 当前生效），npx 形态可能再折一行
        let left = NSStackView(views: [titleLabel, subLabel])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2

        let labelRow = NSStackView(views: [iconView, left])
        labelRow.orientation = .horizontal
        labelRow.spacing = 10
        labelRow.alignment = .top

        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: contentWidth - 34).isActive = true
        field.heightAnchor.constraint(equalToConstant: 32).isActive = true
        (field as? NSTextField)?.font = .systemFont(ofSize: 13)

        // 输入框左缘与标题文字对齐（图标 24 + 间距 10 = 34pt 缩进），右缘仍到内容右边。
        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let fieldWrap = NSStackView(views: [indent, field])
        fieldWrap.orientation = .horizontal
        fieldWrap.spacing = 0
        fieldWrap.translatesAutoresizingMaskIntoConstraints = false
        fieldWrap.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let row = NSStackView(views: [labelRow, fieldWrap])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 12
        return row
    }

    @objc private func didStepPort() {
        portField.stringValue = String(portStepper.integerValue)
    }

    @objc private func didApply() {
        let binary = binaryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = extraField.stringValue
        guard let port = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            showError("端口必须是数字（1–65535）")
            return
        }
        let cfg = DshConfig(
            binaryPath: binary.isEmpty ? DshConfig.defaultBinary : binary,
            extraArgs: extra,
            port: port
        )
        let errs = cfg.validate()
        if !errs.isEmpty {
            showError(errs.joined(separator: "\n"))
            return
        }
        if cfg.binaryPath.contains("/") && !FileManager.default.isExecutableFile(atPath: cfg.binaryPath) {
            showError("该路径不可执行：\(cfg.binaryPath)")
            return
        }
        onApply?(cfg)
    }

    private func showError(_ s: String) {
        errorLabel.stringValue = s
        errorLabel.isHidden = false
    }
}
