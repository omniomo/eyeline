import AppKit
import SwiftUI

// MARK: - 录的是哪一块
//
// 倒数的时候：录的那一块四周一圈主色的框（带一点光），框外面压暗（录整块屏幕就只有框）。
// 开始录的那一下：框变红、闪一下，然后淡掉，不挡着你。它不接鼠标，也不会被录进去。

final class RecordingFrame {
    final class State: ObservableObject {
        /// 录的那一块（在这块屏幕里，左上原点）。
        @Published var region: CGRect = .zero
        /// 整块屏幕都录：不压暗。
        @Published var fullScreen = true
        @Published var recording = false
        @Published var visible = false
    }

    let state = State()
    private var panel: NSPanel?

    /// region：AppKit 全局坐标。
    func show(region: CGRect, on screen: NSScreen) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: false)
        state.region = CGRect(x: region.minX - screen.frame.minX, y: screen.frame.maxY - region.maxY,
                              width: region.width, height: region.height)
        state.fullScreen = abs(region.width - screen.frame.width) < 2 && abs(region.height - screen.frame.height) < 2
        state.recording = false
        panel.orderFrontRegardless()
        withAnimation(.omoOut(0.35)) { state.visible = true }
    }

    /// 开始录了：变红闪一下，淡掉。
    func recording() {
        withAnimation(.omoOut(0.2)) { state.recording = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.hide() }
    }

    func hide() {
        withAnimation(.omoOut(0.5)) { state.visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, !self.state.visible else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // 在普通窗口（幻灯片）上面、人像和倒数下面
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FrameView(state: state))
        return panel
    }
}

struct FrameView: View {
    @ObservedObject var state: RecordingFrame.State

    var body: some View {
        let color = state.recording ? Color(rgb: 0xE5484D) : Paper.accent
        let inset: CGFloat = state.fullScreen ? 3 : -3
        ZStack(alignment: .topLeading) {
            // 框外面压暗：录整块屏幕时不压
            if !state.fullScreen {
                Rectangle()
                    .fill(Color.black.opacity(0.32))
                    .mask {
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .frame(width: state.region.width, height: state.region.height)
                                .offset(x: state.region.minX, y: state.region.minY)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
            }
            RoundedRectangle(cornerRadius: state.fullScreen ? 12 : 10, style: .continuous)
                .strokeBorder(color, lineWidth: 3)
                .shadow(color: color.opacity(0.6), radius: 10)
                .frame(width: state.region.width - inset * 2, height: state.region.height - inset * 2)
                .offset(x: state.region.minX + inset, y: state.region.minY + inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(state.visible ? 1 : 0)
        .ignoresSafeArea()
    }
}
