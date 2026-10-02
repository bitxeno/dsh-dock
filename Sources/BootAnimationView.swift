import Cocoa

/// dsh web 自带 loading 同款：浅灰圆环轨道 + 深色弧段顺时针旋转。30fps Timer 驱动。
/// showLoading 时 start()，hide 后 stop()，别让它空转。
final class BootAnimationView: NSView {
    private var timer: Timer?
    private var t: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        if timer != nil { return }
        let tm = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            s.t += 1.0 / 30.0
            s.needsDisplay = true
        }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        // 与 CSS 一致：20px 圆，2px 环，72° 弧，0.8s 一圈。
        let lineWidth: CGFloat = 2
        let r = min(bounds.width, bounds.height) / 2 - lineWidth / 2

        // 轨道：浅灰整圆（separatorColor ≈ 黑 10%）
        NSColor.separatorColor.setStroke()
        let track = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        track.lineWidth = lineWidth
        track.stroke()

        // 弧段：label 色 72° 圆弧，顺时针 450°/s，圆头
        NSColor.labelColor.setStroke()
        let a = -t * 450
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: r, startAngle: a, endAngle: a + 72, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        arc.stroke()
    }
}
