import AppKit
import AVFoundation

// MARK: - 圆框人像
//
// 录「屏幕 + 人像」时，屏幕上浮着一个圆：镜头里的你，一圈白边、一点阴影。它就是屏幕上的一个窗口，录屏时照原样录进去，
// 看到什么就录到什么。拖它换位置；双指捏合或滚轮改大小。松手时如果有一部分跑出了录的那块，就轻轻弹回来。
// 位置、大小按录的那块记（中心在哪、直径占短边多少；默认短边的 18%，整块屏幕大约 160 点），下次还在同一个角。不录的时候收起来。

final class CameraBubble {
    private var panel: BubblePanel?
    /// 屏幕上的那个窗口（录屏时要留下它）。
    var window: NSWindow? { panel }
    /// 拖完、改完大小：中心在录的那块里的位置（0…1，左上原点），直径占那块短边的比例。
    var onChange: ((CGPoint, CGFloat) -> Void)?
    /// 开始拖、开始改大小（倒数先停一下）。
    var onGrab: (() -> Void)?
    /// 录的那块（AppKit 全局坐标）。
    private(set) var region: CGRect = .zero

    static let minSize: CGFloat = 0.1
    static let maxSize: CGFloat = 0.45

    /// 录的那块的短边。
    private var side: CGFloat { max(1, min(region.width, region.height)) }

    func show(session: AVCaptureSession, in region: CGRect, center: CGPoint, size: CGFloat) {
        self.region = region
        let panel = self.panel ?? BubblePanel(session: session, fake: UserDefaults.standard.bool(forKey: "fakeCamera"))
        panel.owner = self
        let d = diameter(size)
        let point = CGPoint(x: region.minX + center.x * region.width, y: region.maxY - center.y * region.height)
        panel.place(diameter: d, center: clamped(point, diameter: d))
        Log.info("bubble: show at \(Int(center.x * 100))%, \(Int(center.y * 100))% of \(Int(region.width))x\(Int(region.height)) → circle \(Int(panel.circleFrame.minX)),\(Int(panel.circleFrame.minY)) \(Int(d))")
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// 屏幕上的圆（测试用）。
    var circle: CGRect? { panel.map { $0.circleFrame } }

    fileprivate func diameter(_ size: CGFloat) -> CGFloat {
        (min(CameraBubble.maxSize, max(CameraBubble.minSize, size)) * side).rounded()
    }

    /// 圆整个留在录的那块里。
    fileprivate func clamped(_ center: CGPoint, diameter d: CGFloat) -> CGPoint {
        guard region.width > d, region.height > d else { return CGPoint(x: region.midX, y: region.midY) }
        return CGPoint(x: min(max(center.x, region.minX + d / 2), region.maxX - d / 2),
                       y: min(max(center.y, region.minY + d / 2), region.maxY - d / 2))
    }

    /// 拖完、改完：弹回录的那块里面，记下来。
    fileprivate func settle(_ panel: BubblePanel) {
        let d = panel.diameter
        let center = CGPoint(x: panel.circleFrame.midX, y: panel.circleFrame.midY)
        let inside = clamped(center, diameter: d)
        if inside != center { panel.place(diameter: d, center: inside, animate: true) }
        Log.info("bubble: settled at \(Int(inside.x)),\(Int(inside.y)) d \(Int(d))\(inside != center ? " (pulled back in)" : "")")
        guard region.width > 0, region.height > 0 else { return }
        onChange?(CGPoint(x: (inside.x - region.minX) / region.width, y: (region.maxY - inside.y) / region.height), d / side)
    }

    fileprivate func grabbed() { onGrab?() }

    fileprivate func resize(_ panel: BubblePanel, by factor: CGFloat) {
        let size = min(CameraBubble.maxSize, max(CameraBubble.minSize, panel.diameter * factor / side))
        let d = (size * side).rounded()
        let center = CGPoint(x: panel.circleFrame.midX, y: panel.circleFrame.midY)
        panel.place(diameter: d, center: center)
    }
}

private final class BubblePanel: NSPanel {
    weak var owner: CameraBubble?
    private(set) var diameter: CGFloat = 200
    private let bubble: BubbleView
    private var moveObserver: NSObjectProtocol?
    private var settleWork: DispatchWorkItem?

    init(session: AVCaptureSession, fake: Bool) {
        bubble = BubbleView(session: session, fake: fake)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 240), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = bubble
        bubble.onGrab = { [weak self] in self?.owner?.grabbed() }
        bubble.onResize = { [weak self] factor in
            guard let self else { return }
            self.owner?.grabbed()
            self.owner?.resize(self, by: factor)
            self.scheduleSettle()
        }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            guard let self, !self.placing else { return }
            self.scheduleSettle()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 圆可以贴着屏幕边、压在菜单栏上（四周留给阴影的透明边跑出屏幕也没关系），系统别把它往里推。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// 圆在屏幕上的位置（不算阴影的边）。
    var circleFrame: CGRect { frame.insetBy(dx: BubbleView.margin(for: diameter), dy: BubbleView.margin(for: diameter)) }

    private var placing = false

    func place(diameter d: CGFloat, center: CGPoint, animate: Bool = false) {
        diameter = d
        bubble.diameter = d
        let side = d + BubbleView.margin(for: d) * 2
        let rect = NSRect(x: (center.x - side / 2).rounded(), y: (center.y - side / 2).rounded(), width: side, height: side)
        placing = true
        setFrame(rect, display: true, animate: animate)
        placing = false
    }

    private func scheduleSettle() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.owner?.settle(self)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

/// 圆：阴影、白边、镜头的画面。
private final class BubbleView: NSView {
    var diameter: CGFloat = 200 { didSet { needsLayout = true } }
    var onResize: ((CGFloat) -> Void)?
    var onGrab: (() -> Void)?
    private let shade = CALayer()
    private let ring = CALayer()
    private let face: CALayer

    /// 圆四周给阴影留的地方。
    static func margin(for d: CGFloat) -> CGFloat { (d * 0.12).rounded() }

    init(session: AVCaptureSession, fake: Bool) {
        if fake {
            let gradient = CAGradientLayer()
            gradient.colors = [NSColor(srgbRed: 0.29, green: 0.66, blue: 1, alpha: 1).cgColor,
                               NSColor(srgbRed: 0.95, green: 0.55, blue: 0.35, alpha: 1).cgColor]
            gradient.startPoint = CGPoint(x: 0, y: 0)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            face = gradient
        } else {
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.backgroundColor = NSColor(white: 0.9, alpha: 1).cgColor
            face = preview
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear
        shade.shadowColor = NSColor.black.cgColor
        shade.shadowOpacity = 0.28
        ring.backgroundColor = NSColor.white.cgColor
        face.masksToBounds = true
        layer?.addSublayer(shade)
        layer?.addSublayer(ring)
        layer?.addSublayer(face)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let d = diameter
        let border = max(3, (d * 0.025).rounded())
        let circle = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        let outer = circle.insetBy(dx: -border, dy: -border)
        ring.frame = outer
        ring.cornerRadius = outer.width / 2
        shade.frame = outer
        shade.shadowPath = CGPath(ellipseIn: CGRect(origin: .zero, size: outer.size), transform: nil)
        shade.shadowRadius = d * 0.05
        shade.shadowOffset = CGSize(width: 0, height: -d * 0.025)
        face.frame = circle
        face.cornerRadius = d / 2
        CATransaction.commit()
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        onGrab?()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
        super.mouseUp(with: event)
    }

    /// 只有圆里面接鼠标，四周阴影的地方点下去是后面的窗口。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = diameter / 2 + 4
        return hypot(local.x - center.x, local.y - center.y) <= r ? self : nil
    }

    override func magnify(with event: NSEvent) {
        onResize?(1 + event.magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        guard delta != 0 else { return }
        onResize?(1 + delta / 300)
    }
}
