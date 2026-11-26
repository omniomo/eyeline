import AppKit
import CoreText

// MARK: - 提词条
//
// 和菜单栏一样的毛玻璃，白字，直角。唯一的颜色是蓝点（OMO 的玻璃指尖蓝）：它正对摄像头，
// 是眼睛该停的地方；它上面是马上要念的字，正在念的字在它左边两三个字。
// 最亮的是蓝点附近那几个字，念过的变淡，远处的也暗一些，眼睛自然就待在摄像头下面。
// 字在走的时候点不动；字停下来等你的时候，它慢慢地呼吸；暂停时它是一个空心的圈。
// 底边一根细线是全文的进度。
//
// 手可以直接摆弄它：单击暂停，拖动或者两指横滑把稿子拨前拨后，双击一个字从那里开始。
// 鼠标移上来（或右键），下面垂下来一排小按钮（见 RibbonControls）。
// 有幻灯片时，左边一个淡淡的「3 / 12」，翻页时亮一下。

final class RibbonView: NSView {
    private weak var prompter: Prompter?
    /// 毛玻璃底：跟着胶囊打开、收起。
    weak var background: NSVisualEffectView?
    /// 鼠标进出（下面的小按钮跟着出来、收起）；右键。
    var onHover: ((Bool) -> Void)?
    var onRightClick: (() -> Void)?
    /// 幻灯片页码：上次画的是第几页、什么时候翻的（翻页时亮一下）。
    private var counterPage = 0
    private var counterChangedAt: CFTimeInterval = 0
    private var maskRadius: CGFloat = -1
    private(set) var geometry: RibbonGeometry?
    private var text: RibbonText?
    private var textKey: (String, CGFloat)?

    /// 屏幕上字的位置（横向，整行坐标）。每一帧向目标靠一点。
    private var shownX: CGFloat = 0
    private var moving = false
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0

    // 出现、收起：从刘海（或者正中）往两边打开。
    private var reveal: Double = 0
    private var revealFrom: Double = 0
    private var revealTo: Double = 0
    private var revealStart: CFTimeInterval = 0
    private var revealDuration: Double = 0.55
    private var revealDone: (() -> Void)?

    private var statusAlpha: CGFloat = 0
    private var lastStatus: String?

    // 手势
    private enum Edge { case left, right }
    private var resizing: Edge?
    private var resizeCamera: CGFloat = 0
    private var dragStartX: CGFloat = 0
    private var dragStartShown: CGFloat = 0
    private var dragging = false
    private var clickToggledPause = false
    private var scrollEnd: DispatchWorkItem?

    static let blue = NSColor(srgbRed: 0x4A / 255, green: 0xA8 / 255, blue: 0xFF / 255, alpha: 1)

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(_ prompter: Prompter, geometry: RibbonGeometry) {
        self.prompter = prompter
        self.geometry = geometry
        rebuildText(force: true)
        shownX = text?.x(at: prompter.target) ?? 0
        startLink()
        needsDisplay = true
    }

    /// 关键词模式：字整体往右挪一点，左边的计时才不会碰到字。
    private var textOffset: CGFloat {
        prompter?.activeMode == .keywords ? (geometry?.fontSize ?? 16) * 0.75 : 0
    }

    /// 稿子换了（逐字和关键词之间切）：重新排字，直接跳到现在的位置。
    func reload() {
        rebuildText(force: true)
        if let prompter { shownX = text?.x(at: prompter.target) ?? 0 }
        needsDisplay = true
    }

    func update(geometry: RibbonGeometry) {
        self.geometry = geometry
        rebuildText(force: false)
        if let prompter { shownX = text?.x(at: prompter.target) ?? 0 }
        needsDisplay = true
    }

    private func rebuildText(force: Bool) {
        guard let prompter, let geometry else { return }
        let key = (prompter.script.display, geometry.fontSize)
        if !force, let textKey, textKey == key { return }
        let text = RibbonText(script: prompter.script, fontSize: geometry.fontSize)
        self.text = text
        textKey = key
        prompter.metrics = Prompter.Metrics(average: text.averageAdvance) { [weak text] index in text?.advance(index) ?? 0 }
    }

    // MARK: 出现、收起

    func open() {
        animateReveal(to: 1, duration: 0.55, done: nil)
    }

    func close(_ done: @escaping () -> Void) {
        animateReveal(to: 0, duration: 0.4, done: done)
    }

    private func animateReveal(to value: Double, duration: Double, done: (() -> Void)?) {
        revealFrom = reveal
        revealTo = value
        revealStart = CACurrentMediaTime()
        revealDuration = duration
        revealDone = done
        startLink()
    }

    private func startLink() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastFrame = 0
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = lastFrame == 0 ? 1.0 / 60 : min(0.05, now - lastFrame)
        lastFrame = now

        // 出现、收起
        if reveal != revealTo {
            let t = (now - revealStart) / revealDuration
            let eased = revealTo > revealFrom ? Ease.out(t) : Ease.inOut(t)
            reveal = revealFrom + (revealTo - revealFrom) * eased
            if t >= 1 {
                reveal = revealTo
                if let done = revealDone {
                    revealDone = nil
                    done()
                }
            }
        }

        if let prompter, prompter.isActive {
            prompter.tick(now: now, dt: dt)
            if let text {
                let target = text.x(at: prompter.target)
                if dragging || prompter.scrubbing {
                    moving = abs(target - shownX) > 0.5
                    if !dragging { shownX = target }
                } else {
                    let before = shownX
                    let steady = (prompter.activeMode == .steady || prompter.activeMode == .pace) && prompter.phase == .running
                    if steady && abs(target - shownX) < (geometry?.fontSize ?? 16) * 1.5 {
                        // 匀速：每一帧走一样的距离，不加缓动。
                        shownX = target
                    } else {
                        shownX += (target - shownX) * CGFloat(1 - exp(-dt / 0.14))
                        if abs(target - shownX) < 0.05 { shownX = target }
                    }
                    moving = abs(shownX - before) > 0.02
                }
            }
            let wanted: CGFloat = prompter.status == nil && !prompter.isWaitingForVoice ? 0 : 1
            statusAlpha += (wanted - statusAlpha) * CGFloat(1 - exp(-dt / 0.09))
            if let status = prompter.status { lastStatus = status }
        }
        updateBackground()
        needsDisplay = true

        if reveal == 0 && revealTo == 0 && revealDone == nil { stopLink() }
    }

    // MARK: 画

    /// 胶囊现在打开到哪了（窗口坐标）。
    private var openedRange: (left: CGFloat, right: CGFloat) {
        guard let geometry else { return (0, 0) }
        let opened = CGFloat(reveal)
        let left = geometry.openFrom.lowerBound * (1 - opened)
        let right = geometry.openFrom.upperBound + (bounds.width - geometry.openFrom.upperBound) * opened
        return (left, right)
    }

    private func updateBackground() {
        guard let background, let geometry else { return }
        let range = openedRange
        background.isHidden = reveal <= 0.001
        let frame = NSRect(x: range.left, y: 0, width: max(0, range.right - range.left), height: bounds.height)
        if background.frame != frame { background.frame = frame }
        if maskRadius != geometry.cornerRadius {
            maskRadius = geometry.cornerRadius
            background.maskImage = geometry.cornerRadius > 0 ? RibbonView.maskImage(radius: geometry.cornerRadius) : nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let geometry, let text, let prompter else { return }
        let width = bounds.width
        let height = bounds.height
        guard reveal > 0 else { return }

        // 只在打开的胶囊里画。
        let range = openedRange
        let shape = RibbonView.pill(CGRect(x: range.left, y: 0, width: max(0, range.right - range.left), height: height),
                                    radius: min(geometry.cornerRadius, (range.right - range.left) / 2))
        context.saveGState()
        context.addPath(shape)
        context.clip()

        // 字先画在一层里，再用一张横向的透明度蒙版：念过的淡、蓝点那里一道缝、两头隐去。
        let anchor = geometry.anchor + textOffset
        let baseline = ((height - (text.ascent + text.descent)) / 2 + text.descent).rounded()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.textMatrix = .identity
        let firstVisible = shownX - anchor
        let lastVisible = firstVisible + width
        for chunk in text.chunks where chunk.x + chunk.width >= firstVisible && chunk.x <= lastVisible {
            context.textPosition = CGPoint(x: anchor + chunk.x - shownX, y: baseline)
            CTLineDraw(chunk.line, context)
        }
        let past = 0.4 * (1 - statusAlpha)
        let fade = min(geometry.fontSize * 3, width * 0.12)
        let size = geometry.fontSize
        let far = min(width - fade * 1.4, geometry.dot + size * 6)
        var stops: [(CGFloat, CGFloat)] = [
            (0, 0), (fade, past), (anchor - size * 1.1, past), (anchor - 1, 1),
            (geometry.dot + size * 3, 1), (far, 0.72), (width - fade * 1.4, 0.72), (width, 0)
        ]
        if let span = prompter.cueSpan, span.upperBound > span.lowerBound, span.upperBound - 1 < text.ends.count,
           span.lowerBound < text.starts.count {
            // 关键词：现在这个整个是亮的，后面的下一个淡一点，左边留给计时
            let cueWidth = text.ends[span.upperBound - 1] - text.starts[span.lowerBound]
            let lit = min(width - fade * 1.4 - size, anchor + cueWidth + size * 0.35)
            stops = [
                (0, 0), (fade, past), (anchor - size * 1.1, past), (anchor - 1, 1),
                (lit, 1), (lit + size * 1.4, 0.4), (width - fade * 1.4, 0.4), (width, 0)
            ]
        }
        context.setBlendMode(.destinationIn)
        RibbonView.horizontalMask(stops, in: context, size: bounds.size)
        // 有幻灯片：只显示这一页的话，这一页最后一个字后面渐隐（下一页的话翻页了才出来）
        if let last = prompter.pageLastToken, last >= 0, last < text.ends.count {
            let cut = anchor + text.ends[last] - shownX
            if cut < width {
                RibbonView.horizontalMask([(0, 1), (cut + size * 0.2, 1), (cut + size * 0.9, 0), (width, 0)], in: context, size: bounds.size)
            }
        }
        context.setBlendMode(.normal)
        context.endTransparencyLayer()

        if statusAlpha > 0.01 {
            if prompter.isWaitingForVoice {
                drawWave(context, geometry: geometry, level: CGFloat(prompter.level), nudged: prompter.nudgedAt, alpha: statusAlpha)
            } else if let status = lastStatus {
                drawStatus(status, in: context, geometry: geometry, alpha: statusAlpha)
            }
        }

        if let notch = geometry.notch {
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: notch.lowerBound, y: 0, width: notch.upperBound - notch.lowerBound, height: height))
        }

        // 进度：底边一根细线。
        let progress = CGFloat(prompter.progress)
        if progress > 0 {
            context.setFillColor(NSColor.white.withAlphaComponent(0.32).cgColor)
            context.fill(CGRect(x: range.left, y: 0, width: (range.right - range.left) * progress, height: 1))
        }

        if let counter = prompter.slideCounter {
            drawCounter(counter, in: context, geometry: geometry, left: range.left)
        }
        drawDot(context, geometry: geometry, prompter: prompter, textBottom: baseline - text.descent)
        context.restoreGState()
    }

    /// 一条横向的透明度渐变，stops 是（横坐标, 透明度）。
    static func horizontalMask(_ stops: [(CGFloat, CGFloat)], in context: CGContext, size: CGSize) {
        guard size.width > 0 else { return }
        let sorted = stops.map { (min(max($0.0, 0), size.width), $0.1) }.sorted { $0.0 < $1.0 }
        let colors = sorted.map { NSColor(white: 0, alpha: $0.1).cgColor } as CFArray
        let locations = sorted.map { $0.0 / size.width }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations) else { return }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// 毛玻璃的形状：顶边平，下面两个圆角；九宫格拉伸。
    static func maskImage(radius: CGFloat) -> NSImage {
        let r = max(1, radius)
        let image = NSImage(size: NSSize(width: r * 2 + 2, height: r * 2 + 2), flipped: false) { rect in
            NSColor.black.setFill()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY + r))
            path.appendArc(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.minX + r, y: rect.minY), radius: r)
            path.line(to: NSPoint(x: rect.maxX - r, y: rect.minY))
            path.appendArc(from: NSPoint(x: rect.maxX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.minY + r), radius: r)
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.close()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }

    /// 顶边平、底下两个圆角的形状。
    static func pill(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let r = max(0, min(radius, rect.height, rect.width / 2))
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    /// 等你开口时：一个麦克风图标（跟读、跟声音的模式）。被点一下会弹一下。
    private func drawWave(_ context: CGContext, geometry: RibbonGeometry, level: CGFloat, nudged: CFTimeInterval, alpha: CGFloat) {
        let since = CACurrentMediaTime() - nudged
        let bounce = since < 0.5 ? 1 + 0.25 * CGFloat(sin(since / 0.5 * .pi)) : 1
        let size = geometry.fontSize * 0.9 * bounce
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.9 * alpha)]))
        guard let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let rect = NSRect(x: geometry.statusRight - image.size.width, y: (bounds.height - image.size.height) / 2,
                          width: image.size.width, height: image.size.height)
        image.draw(in: rect)
    }

    private func drawStatus(_ status: String, in context: CGContext, geometry: RibbonGeometry, alpha: CGFloat) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: (geometry.fontSize * 0.9).rounded(), weight: .medium)
        let string = NSAttributedString(string: status, attributes: [
            .font: font, .foregroundColor: RibbonText.paper.withAlphaComponent(0.92 * alpha)
        ])
        let line = CTLineCreateWithAttributedString(string)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let y = ((bounds.height - (font.ascender - font.descender)) / 2 - font.descender).rounded()
        context.textPosition = CGPoint(x: geometry.statusRight - width, y: y)
        CTLineDraw(line, context)
    }

    /// 幻灯片页码「3 / 12」：左边，平时淡淡的；刚翻页时亮一下再暗回去。
    private func drawCounter(_ counter: (page: Int, count: Int), in context: CGContext, geometry: RibbonGeometry, left: CGFloat) {
        let now = CACurrentMediaTime()
        if counter.page != counterPage {
            counterChangedAt = counterPage == 0 ? 0 : now
            counterPage = counter.page
        }
        let flash = counterChangedAt == 0 ? 0 : max(0, 1 - (now - counterChangedAt) / 1.4)
        let alpha = 0.42 + 0.5 * CGFloat(flash)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(10, (geometry.fontSize * 0.62).rounded()), weight: .semibold)
        let string = NSAttributedString(string: "\(counter.page) / \(counter.count)", attributes: [
            .font: font, .foregroundColor: NSColor.white.withAlphaComponent(alpha)
        ])
        let line = CTLineCreateWithAttributedString(string)
        let y = ((bounds.height - (font.ascender - font.descender)) / 2 - font.descender).rounded()
        context.textPosition = CGPoint(x: left + max(12, geometry.cornerRadius), y: y)
        CTLineDraw(line, context)
    }

    /// 蓝点在眼睛该看的地方的正下方（没有刘海时正对摄像头）。textBottom 是字的下沿。
    private func drawDot(_ context: CGContext, geometry: RibbonGeometry, prompter: Prompter, textBottom: CGFloat) {
        let radius = max(1.9, geometry.fontSize * 0.13)
        let center = CGPoint(x: geometry.dot, y: max(radius + 1.5, (textBottom * 0.5).rounded()))
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        switch prompter.phase {
        case .paused, .finished:
            context.setStrokeColor(RibbonView.blue.cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: rect.insetBy(dx: 0.6, dy: 0.6))
        case .countdown:
            context.setFillColor(RibbonView.blue.withAlphaComponent(0.5).cgColor)
            context.fillEllipse(in: rect)
        default:
            // 静止时才动：字在走，点就停着；字停下来等你，点才呼吸。
            let still = !moving && !(prompter.activeMode == .steady)
            let phase = CACurrentMediaTime().truncatingRemainder(dividingBy: 2.4) / 2.4
            let alpha = still ? 0.35 + 0.65 * (0.5 + 0.5 * cos(phase * 2 * .pi)) : 1
            context.setFillColor(RibbonView.blue.withAlphaComponent(CGFloat(alpha)).cgColor)
            context.fillEllipse(in: rect)
        }
    }

    // MARK: 手

    private static let edgeWidth: CGFloat = 7

    private func edge(at x: CGFloat) -> Edge? {
        if x < RibbonView.edgeWidth { return .left }
        if x > bounds.width - RibbonView.edgeWidth { return .right }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard resizing == nil, !dragging else { return }
        let x = convert(event.locationInWindow, from: nil).x
        (edge(at: x) != nil ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        if resizing == nil { NSCursor.arrow.set() }
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let prompter, let text else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if event.clickCount == 1, let edge = edge(at: x), let window, let geometry {
            // 拖两头：改胶囊的宽度。
            resizing = edge
            resizeCamera = window.frame.minX + geometry.camera
            return
        }
        if event.clickCount >= 2 {
            // 双击：从这个字开始。第一下点出来的暂停撤回去。
            if clickToggledPause { prompter.togglePause() }
            clickToggledPause = false
            prompter.jump(to: text.token(atX: shownX + x - (geometry?.anchor ?? 0) - textOffset))
            return
        }
        dragStartX = x
        dragStartShown = shownX
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        if let resizing, let prompter, let geometry {
            let mouse = NSEvent.mouseLocation.x
            let size = geometry.fontSize
            switch resizing {
            case .left: prompter.prefs.ribbonLeft = Double(max(4, (resizeCamera - mouse) / size))
            case .right: prompter.prefs.ribbonRight = Double(max(8, (mouse - resizeCamera) / size))
            }
            NSCursor.resizeLeftRight.set()
            prompter.ribbon?.relayout()
            return
        }
        guard let prompter, let text else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let dx = x - dragStartX
        if !dragging && abs(dx) < 3 { return }
        dragging = true
        NSCursor.closedHand.set()
        shownX = min(max(0, dragStartShown - dx), text.width)
        prompter.scrub(to: text.position(atX: shownX))
    }

    override func mouseUp(with event: NSEvent) {
        if resizing != nil {
            resizing = nil
            return
        }
        guard let prompter else { return }
        if dragging {
            dragging = false
            NSCursor.arrow.set()
            prompter.endScrub()
            return
        }
        if event.clickCount == 1 {
            let wasWaiting = prompter.waitingForVoice
            prompter.clicked()
            clickToggledPause = !wasWaiting
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) { [weak self] in
                self?.clickToggledPause = false
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let prompter, let text else { return }
        let horizontal = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
        var delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= 14 }
        guard delta != 0 else { return }
        let base = prompter.scrubbing ? shownX : text.x(at: prompter.target)
        shownX = min(max(0, base - delta), text.width)
        prompter.scrub(to: text.position(atX: shownX))
        scrollEnd?.cancel()
        let work = DispatchWorkItem { [weak prompter] in prompter?.endScrub() }
        scrollEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}
