import Cocoa

/// 设置弹层表单：Binary Path + Extra Args + Port + Apply&Restart/Cancel。
final class SettingsViewController: NSViewController {
    var onApply: ((DshConfig) -> Void)?
    var onCancel: (() -> Void)?

    private var config: DshConfig
    private var providerText: String

    private let binaryField = NSTextField()
    private let extraField = NSTextField()
    private let portField = NSTextField()
    private let providerLabel = NSTextField(labelWithString: "")
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
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let title = NSTextField(labelWithString: "dsh 服务设置")
        title.font = .boldSystemFont(ofSize: 14)

        func row(_ label: String, _ field: NSTextField, placeholder: String) -> NSStackView {
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            field.placeholderString = placeholder
            field.font = .systemFont(ofSize: 12)
            let s = NSStackView(views: [l, field])
            s.orientation = .vertical
            s.spacing = 4
            s.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
            return s
        }

        binaryField.stringValue = config.binaryPath
        extraField.stringValue = config.extraArgs
        portField.stringValue = String(config.port)
        providerLabel.stringValue = "当前：\(providerText)"
        providerLabel.font = .systemFont(ofSize: 11)
        providerLabel.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3

        let apply = NSButton(title: "应用并重启", target: self, action: #selector(didApply))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(didCancel))
        cancel.bezelStyle = .rounded
        let btns = NSStackView(views: [cancel, apply])
        btns.orientation = .horizontal
        btns.alignment = .trailing

        let stack = NSStackView(views: [
            title,
            row("Binary Path（默认 dsh，可填绝对路径）", binaryField, placeholder: "dsh"),
            row("Extra Args（附加参数，端口由下方字段注入）", extraField, placeholder: "例如：--verbose"),
            row("Port（1–65535）", portField, placeholder: "38811"),
            providerLabel,
            errorLabel,
            btns,
        ])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            stack.widthAnchor.constraint(equalToConstant: 360),
        ])
    }

    @objc private func didApply() {
        let binary = binaryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = extraField.stringValue
        guard let port = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorLabel.stringValue = "端口必须是数字（1–65535）"
            return
        }
        let cfg = DshConfig(
            binaryPath: binary.isEmpty ? DshConfig.defaultBinary : binary,
            extraArgs: extra,
            port: port
        )
        let errs = cfg.validate()
        if !errs.isEmpty {
            errorLabel.stringValue = errs.joined(separator: "\n")
            return
        }
        // 二进制可执行性软校验：绝对路径直接查，名字走解析（允许 npx fallback，先放行）
        if cfg.binaryPath.contains("/") && !FileManager.default.isExecutableFile(atPath: cfg.binaryPath) {
            errorLabel.stringValue = "该路径不可执行：\(cfg.binaryPath)"
            return
        }
        onApply?(cfg)
    }

    @objc private func didCancel() {
        onCancel?()
    }
}
