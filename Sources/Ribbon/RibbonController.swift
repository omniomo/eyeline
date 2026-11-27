import AppKit

/// 管提词条的窗口：放在哪块屏幕、多高、要不要在录屏里藏起来。
final class RibbonController {
    private var panel: RibbonPanel?
    private var view: RibbonView?
    private weak var prompter: Prompter?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private let prefs = Preferences.shared
    /// 鼠标移上来时垂下来的那排小按钮。
    private let controls = RibbonControls()

    func show(_ prompter: Prompter) {
        self.prompter = prompter
        let geometry = currentGeometry()
        NSLog("Eyeline ribbon frame=%@ anchor=%.0f font=%.0f notch=%@", NSStringFromRect(geometry.frame), geometry.anchor,
              geometry.fontSize, geometry.notch.map { "\($0)" } ?? "none")
        let panel = self.panel ?? makePanel()
        panel.setFrame(geometry.frame, display: false)
        panel.sharingType = prefs.hideFromCapture ? .none : .readOnly
        view?.frame = NSRect(origin: .zero, size: geometry.frame.size)
        view?.configure(prompter, geometry: geometry)
        controls.attach(prompter)
        view?.onHover = { [weak self] inside in
            guard let self, let panel = self.panel, let geometry = self.view?.geometry else { return }
            self.controls.ribbonHover(inside, ribbon: panel.frame, centerX: panel.frame.minX + geometry.dot)
        }
        view?.onRightClick = { [weak self] in
            guard let self, let panel = self.panel, let geometry = self.view?.geometry else { return }
            self.controls.show(below: panel.frame, centerX: panel.frame.minX + geometry.dot)
        }
        panel.orderFrontRegardless()
        view?.open()

        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                self?.relayout()
            }
        }
    }

    /// 提词条的窗口（录屏时要留下它就用这个；下面那排小按钮不算）。
    var windows: [NSWindow] { [panel].compactMap { $0 } }

    func hide() {
        controls.hideNow()
        guard let view, let panel else { return }
        view.close { [weak self] in
            panel.orderOut(nil)
            if let observer = self?.screenObserver { NotificationCenter.default.removeObserver(observer) }
            self?.screenObserver = nil
        }
    }

    /// 测试用：把下面那排小按钮叫出来，返回它在屏幕上的位置；再画成图片。
    func testShowControls() {
        guard let panel, let geometry = view?.geometry else { return }
        controls.show(below: panel.frame, centerX: panel.frame.minX + geometry.dot)
    }

    func testControls(to url: URL) -> NSRect? { controls.snapshot(to: url) }

    /// 把提词条画成图片（测试用：看排版）。
    func snapshot(to url: URL) {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// 稿子换了（逐字和关键词之间切）：重新排字。
    func reload() {
        view?.reload()
    }

    /// 字号、屏幕、录屏设置变了。
    func relayout() {
        guard let panel, let view, let prompter, prompter.isActive else { return }
        let geometry = currentGeometry()
        panel.sharingType = prefs.hideFromCapture ? .none : .readOnly
        if geometry != view.geometry {
            panel.setFrame(geometry.frame, display: false)
            view.frame = NSRect(origin: .zero, size: geometry.frame.size)
            view.update(geometry: geometry)
        }
    }

    private func currentGeometry() -> RibbonGeometry {
        RibbonGeometry.make(screen: RibbonGeometry.screen(for: prefs.display), size: prefs.size,
                            left: prefs.ribbonLeft, right: prefs.ribbonRight)
    }

    private func makePanel() -> RibbonPanel {
        let panel = RibbonPanel()
        let container = NSView(frame: .zero)
        // 和菜单栏一样的毛玻璃（深色，白字才看得清）。
        let glass = NSVisualEffectView(frame: .zero)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.isHidden = true
        let view = RibbonView(frame: .zero)
        view.background = glass
        container.addSubview(glass)
        container.addSubview(view)
        view.autoresizingMask = [.width, .height]
        panel.contentView = container
        self.panel = panel
        self.view = view
        return panel
    }
}

/// 不抢焦点、浮在菜单栏上面、所有桌面和全屏 App 里都在的窗口。
final class RibbonPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
