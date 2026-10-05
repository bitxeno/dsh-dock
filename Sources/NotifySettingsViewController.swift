import Cocoa

/// 通知方式弹层（对齐接管开关弹层样式：标题 + 说明 + 三选一）。
/// internal 便于无头渲染验证。
final class NotifySettingsViewController: NSViewController {
    var onChange: ((NotifyBackend) -> Void)?

    private var selected: NotifyBackend
    private var radios: [NotifyBackend: NSButton] = [:]

    init(selected: NotifyBackend) {
        self.selected = selected
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        view = root
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        let width: CGFloat = 264
        let title = NSTextField(labelWithString: "通知方式")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        stack.addArrangedSubview(title)
        for backend in NotifyBackend.allCases {
            stack.addArrangedSubview(makeRadioRow(backend: backend, width: width))
        }
        let tip = NSTextField(labelWithString: "刘海悬窗无需系统授权，点正文进会话、点按钮直接裁决；待审批常驻。切换即时生效。")
        tip.font = .systemFont(ofSize: 12)
        tip.textColor = .secondaryLabelColor
        tip.cell?.wraps = true
        tip.cell?.lineBreakMode = .byWordWrapping
        tip.usesSingleLineMode = false
        tip.preferredMaxLayoutWidth = width
        tip.translatesAutoresizingMaskIntoConstraints = false
        tip.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(tip)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
    }

    private func makeRadioRow(backend: NotifyBackend, width: CGFloat) -> NSView {
        let radio = NSButton(radioButtonWithTitle: backend.title, target: self, action: #selector(didSelect(_:)))
        radio.tag = NotifyBackend.allCases.firstIndex(of: backend) ?? 0
        radio.state = backend == selected ? .on : .off
        radios[backend] = radio

        let sub = NSTextField(labelWithString: backend.subtitle)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.cell?.wraps = true
        sub.cell?.lineBreakMode = .byWordWrapping
        sub.usesSingleLineMode = false
        sub.preferredMaxLayoutWidth = width - 24
        sub.translatesAutoresizingMaskIntoConstraints = false
        sub.widthAnchor.constraint(equalToConstant: width - 24).isActive = true

        let col = NSStackView(views: [radio, sub])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2
        col.translatesAutoresizingMaskIntoConstraints = false
        col.widthAnchor.constraint(equalToConstant: width).isActive = true
        return col
    }

    @objc private func didSelect(_ sender: NSButton) {
        let backend = NotifyBackend.allCases[sender.tag]
        selected = backend
        for (b, r) in radios { r.state = b == backend ? .on : .off }
        onChange?(backend)
    }
}
