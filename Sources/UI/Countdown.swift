import AppKit
import SwiftUI

// MARK: - 录屏前的倒数
//
// 按播放（录屏幕）：窗口先变成要录的样子、圆框人像先放上去，录的那块正中间浮一个玻璃圆，3、2、1 倒数，
// 一圈主色的线跟着走完。倒数的这几秒正好看看画面、挪挪人像：一抓圆框，倒数就停（圈变灰），松手后重新从 3 开始。
// 空格 / 回车：马上开始；Esc：不录了。倒数结束才真的开始录，所以这几秒不会进视频。
// 它自己不接鼠标（点得穿），也不会被录进去。

final class CountdownPanel {
    final class State: ObservableObject {
        /// 什么时候倒数完；nil：停着（正在挪人像）。
        @Published var deadline: Date?
        let length: TimeInterval = 3
    }

    let state = State()
    private var panel: NSPanel?

    func show(in region: CGRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: (region.midX - size.width / 2).rounded(), y: (region.midY - size.height / 2).rounded()))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        state.deadline = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// 从头倒数。
    func restart() { state.deadline = Date().addingTimeInterval(state.length) }

    /// 停住（正在挪人像）。
    func pause() { state.deadline = nil }

    private func makePanel() -> NSPanel {
        let side: CGFloat = 170
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CountdownView(state: state).frame(width: side, height: side))
        return panel
    }
}

private struct CountdownView: View {
    @ObservedObject var state: CountdownPanel.State

    var body: some View {
        TimelineView(.animation) { timeline in
            let left = state.deadline.map { max(0, $0.timeIntervalSince(timeline.date)) }
            let progress = left.map { 1 - $0 / state.length } ?? 0
            let number = left.map { max(1, Int(ceil($0))) } ?? Int(state.length)
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.08), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Paper.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(number)")
                    .font(.system(size: 54, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(left == nil ? Paper.fog : Paper.ink)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.omoOut(0.3), value: number)
            }
            .padding(14)
            .frame(width: 128, height: 128)
            .glass(cornerRadius: 64)
        }
        .environment(\.colorScheme, .light)
    }
}
