import AppKit
import SwiftUI

// MARK: - 提词条下面的小按钮
//
// 鼠标移到提词条上（或者右键）：提词条下面、蓝点正下方垂下来一条深色玻璃胶囊，
// 上一句、暂停 / 继续、下一句 | 慢一点、快一点（用得上速度时）| 字小、字大 | 停止。
// 鼠标从提词条挪到胶囊上不会收；两边都离开一会儿才收起。录屏时隐藏的设置对它一样生效。

final class RibbonControls {
    private var panel: ControlsPanel?
    private var hosting: NSHostingView<RibbonToolbar>?
    private var hideWork: DispatchWorkItem?
    private var overRibbon = false
    private var overToolbar = false
    private weak var prompter: Prompter?

    func attach(_ prompter: Prompter) { self.prompter = prompter }

    /// 鼠标进出提词条。frame：提词条窗口（屏幕坐标）；centerX：挂在哪个横坐标下面（屏幕坐标）。
    func ribbonHover(_ inside: Bool, ribbon frame: NSRect, centerX: CGFloat) {
        overRibbon = inside
        if inside { show(below: frame, centerX: centerX) } else { scheduleHide() }
    }

    /// 右键：直接出来（鼠标还在提词条上，挪开才收）。
    func show(below frame: NSRect, centerX: CGFloat) {
        guard let prompter, prompter.isActive else { return }
        hideWork?.cancel()
        let panel = self.panel ?? makePanel(prompter)
        guard let hosting else { return }
        let size = hosting.fittingSize
        let origin = NSPoint(x: (centerX - size.width / 2).rounded(), y: (frame.minY - size.height - 6).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.sharingType = prompter.prefs.hideFromCapture ? .none : .readOnly
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    /// 测试用：画成图片，返回窗口位置（没出来是 nil）。
    func snapshot(to url: URL) -> NSRect? {
        guard let panel, panel.isVisible, let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return panel.frame
    }

    func hideNow() {
        hideWork?.cancel()
        overRibbon = false
        overToolbar = false
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    /// 内容变了（暂停 / 继续、换了方式）：重新量大小，还在原来的中心。
    func refit() {
        guard let panel, panel.isVisible, let hosting else { return }
        let size = hosting.fittingSize
        guard size != panel.frame.size else { return }
        let center = panel.frame.midX
        panel.setFrame(NSRect(x: (center - size.width / 2).rounded(), y: panel.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.overRibbon, !self.overToolbar else { return }
            self.hideNow()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func makePanel(_ prompter: Prompter) -> ControlsPanel {
        let panel = ControlsPanel()
        let toolbar = RibbonToolbar(prompter: prompter, prefs: prompter.prefs) { [weak self] inside in
            self?.overToolbar = inside
            if !inside { self?.scheduleHide() } else { self?.hideWork?.cancel() }
        } onLayout: { [weak self] in
            DispatchQueue.main.async { self?.refit() }
        }
        let hosting = FirstMouseHostingView(rootView: toolbar)
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }
}

/// 不抢焦点、和提词条同一层的小窗口。
private final class ControlsPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        appearance = NSAppearance(named: .darkAqua)
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 窗口不是当前窗口也能一下点中（不用先点一下激活）。
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 胶囊里的按钮。
struct RibbonToolbar: View {
    @ObservedObject var prompter: Prompter
    @ObservedObject var prefs: Preferences
    let onHover: (Bool) -> Void
    let onLayout: () -> Void

    var body: some View {
        let paused = prompter.phase == .paused || prompter.phase == .finished
        let speed = SpeedControl.applies(prompter.activeMode, prefs)
        HStack(spacing: 2) {
            RibbonButton(symbol: "chevron.left", label: prompter.activeMode == .keywords
                         ? String(localized: "Previous Keyword") : String(localized: "Back One Line")) { prompter.perform(.back) }
            RibbonButton(symbol: paused ? "play.fill" : "pause.fill",
                         label: paused ? String(localized: "Resume") : String(localized: "Pause")) { prompter.togglePause() }
            RibbonButton(symbol: "chevron.right", label: prompter.activeMode == .keywords
                         ? String(localized: "Next Keyword") : String(localized: "Next Line")) { prompter.perform(.forward) }
            if speed {
                divider
                RibbonButton(symbol: "tortoise.fill", label: String(localized: "Slower")) { prompter.changeSpeed(-1) }
                RibbonButton(symbol: "hare.fill", label: String(localized: "Faster")) { prompter.changeSpeed(1) }
            }
            divider
            RibbonButton(symbol: "textformat.size.smaller", label: String(localized: "Smaller")) { prompter.changeSize(-1) }
            RibbonButton(symbol: "textformat.size.larger", label: String(localized: "Bigger")) { prompter.changeSize(1) }
            divider
            RibbonButton(symbol: "stop.fill", label: String(localized: "Stop")) { prompter.stop() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        // 和提词条一样是深色的玻璃：下面是白的（浏览器、文档）也看得清白色的图标
        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.black.opacity(0.42)))
        .glass(cornerRadius: 19)
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .onHover(perform: onHover)
        .onChangeOf(speed) { _, _ in onLayout() }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.16)).frame(width: 1, height: 16).padding(.horizontal, 4)
    }
}

private struct RibbonButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.82))
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}
