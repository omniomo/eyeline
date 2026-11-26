import AppKit
import SwiftUI

// MARK: - 屏幕录制权限
//
// 要录屏幕、还没有权限：不开始录，窗口里先出一张卡片；点「打开系统设置」直接跳到「屏幕与系统录音」那一页，
// 同时在系统设置窗口上浮一个拖拽引导：下面是 Eyeline 的图标，一支大箭头弯进上面的列表，
// 一个半透明的图标带着小手顺着箭头一遍遍滑进去。不写字，也不弹系统那个对话框。
// 等权限真的给了，引导收起，Eyeline 回到前面，接着开始录。
// 有的系统要重新打开 Eyeline 权限才生效：等一会儿还没生效，卡片上出现「重新打开 Eyeline」。

/// 窗口里的卡片。
struct ScreenPermissionCard: View {
    @ObservedObject var model: AppModel
    let step: AppModel.ScreenPermissionStep

    var body: some View {
        ZStack {
            Color.white.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(spacing: 0) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Paper.accent)
                    .padding(.bottom, 14)
                Text("Allow Eyeline to record the screen")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Paper.ink)
                    .padding(.bottom, 20)
                switch step {
                case .ask:
                    PrimaryButton(title: String(localized: "Open System Settings")) { model.openScreenRecordingSettings() }
                case .waiting(let since):
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        VStack(spacing: 12) {
                            HStack(spacing: 8) {
                                Spinner()
                                Text("Waiting for permission…")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Paper.charcoal)
                            }
                            .frame(height: 34)
                            if context.date.timeIntervalSince(since) > 5 {
                                Button { model.reopenForScreenPermission() } label: {
                                    Text("Turned it on? Reopen Eyeline")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Paper.accentText)
                                }
                                .buttonStyle(.plain)
                                .transition(.opacity)
                            }
                        }
                        .animation(.omoOut(0.3), value: context.date.timeIntervalSince(since) > 5)
                    }
                }
                Button { model.dismissScreenPermission() } label: {
                    Text("Not now")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Paper.gray)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 28)
            .frame(width: 300)
            .glass(cornerRadius: 24)
        }
    }
}

// MARK: - 系统设置上的拖拽引导

/// 浮在系统设置窗口上：箭头的尖落在右边的列表里，Eyeline 的图标在窗口下边。跟着系统设置窗口走；系统设置关了它也收起。
final class PermissionHelper {
    private var panel: NSPanel?
    private var timer: Timer?
    private var sawSettings = false

    /// 引导的大小，箭头尖在里面的位置（左上原点）。
    static let size = CGSize(width: 300, height: 270)
    static let tip = CGPoint(x: 58, y: 30)

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        sawSettings = false
        follow()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            panel.animator().alphaValue = 1
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.follow() }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: PermissionHelper.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        let guide = DragGuide(close: { [weak self] in self?.close() },
                              dragging: { [weak panel] on in panel?.ignoresMouseEvents = on })
        panel.contentView = NSHostingView(rootView: guide)
        return panel
    }

    /// 箭头尖放进系统设置右边（列表那块）靠下的地方；还没找到系统设置：屏幕下方正中。
    private func follow() {
        guard let panel else { return }
        let size = PermissionHelper.size, tip = PermissionHelper.tip
        if let settings = PermissionHelper.settingsWindow() {
            sawSettings = true
            let target = CGPoint(x: settings.minX + settings.width * 0.64, y: settings.minY + 150)
            var origin = CGPoint(x: target.x - tip.x, y: target.y + tip.y - size.height)
            if let area = (NSScreen.screens.first { $0.frame.intersects(settings) } ?? NSScreen.main)?.visibleFrame {
                origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
                origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
            }
            let frame = NSRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
            if frame != panel.frame { panel.setFrame(frame, display: true) }
        } else if sawSettings {
            // 系统设置关掉了
            close()
        } else if let area = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: (area.midX - size.width / 2).rounded(), y: area.minY + 24))
        }
    }

    /// 系统设置主窗口在屏幕上的位置（AppKit 坐标）。窗口的位置不用屏幕录制权限也拿得到。
    private static func settingsWindow() -> CGRect? {
        let ids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").map(\.processIdentifier))
        guard !ids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let rects = list.compactMap { info -> CGRect? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, ids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 300, rect.height > 200 else { return nil }
            return CGRect(x: rect.minX, y: primary - rect.maxY, width: rect.width, height: rect.height)
        }
        return rects.max { $0.width * $0.height < $1.width * $1.height }
    }
}

/// 拖拽引导：Eyeline 的图标（真的能拖），一支大箭头弯进列表，一个半透明的图标带着小手顺着箭头滑进去。
struct DragGuide: View {
    let close: () -> Void
    let dragging: (Bool) -> Void
    @State private var isDragging = false
    @State private var hovering = false

    /// 箭头：从图标上方出发，往上再弯向左上，尖在 PermissionHelper.tip。
    static let start = CGPoint(x: 206, y: 140)
    static let control1 = CGPoint(x: 214, y: 66)
    static let control2 = CGPoint(x: 100, y: 96)
    static let tile = CGPoint(x: 228, y: 202)

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, _ in
                    drawArrow(context)
                    drawGhost(context, t)
                }
            }
            .opacity(isDragging ? 0 : 1)
            .allowsHitTesting(false)

            // Eyeline 的图标：按住拖进列表
            ZStack(alignment: .topTrailing) {
                AppIconDrag(dragging: { on in
                    withAnimation(.omoOut(0.2)) { isDragging = on }
                    dragging(on)
                })
                .frame(width: 92, height: 92)
                .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
                .scaleEffect(hovering && !isDragging ? 1.04 : 1)
                .onHover { hovering = $0 }
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Paper.gray)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white).shadow(color: .black.opacity(0.15), radius: 3, y: 1))
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
                .opacity(hovering ? 1 : 0)
            }
            .animation(.omoOut(0.2), value: hovering)
            .position(DragGuide.tile)
        }
        .frame(width: PermissionHelper.size.width, height: PermissionHelper.size.height)
        .environment(\.colorScheme, .light)
    }

    private func point(_ t: CGFloat) -> CGPoint {
        let p0 = DragGuide.start, p1 = DragGuide.control1, p2 = DragGuide.control2, p3 = PermissionHelper.tip
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    private func drawArrow(_ context: GraphicsContext) {
        let tip = PermissionHelper.tip
        // 线停在箭头头部的根上
        let end = point(0.9)
        var line = Path()
        line.move(to: DragGuide.start)
        line.addCurve(to: end, control1: DragGuide.control1, control2: CGPoint(x: (DragGuide.control2.x + end.x) / 2, y: (DragGuide.control2.y + end.y) / 2))
        let angle = atan2(tip.y - end.y, tip.x - end.x)
        let length: CGFloat = 30, spread: CGFloat = 0.62
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread)))
        head.addLine(to: CGPoint(x: tip.x - length * 0.62 * cos(angle), y: tip.y - length * 0.62 * sin(angle)))
        head.addLine(to: CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread)))
        head.closeSubpath()
        let blue = Color(rgb: 0x4AA8FF)
        // 白边 + 一点影子，压在系统设置上也看得清
        var halo = context
        halo.addFilter(.shadow(color: .black.opacity(0.18), radius: 6, y: 2))
        halo.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 16, lineCap: .round))
        halo.fill(head, with: .color(.white))
        halo.stroke(head, with: .color(.white), style: StrokeStyle(lineWidth: 8, lineJoin: .round))
        context.stroke(line, with: .color(blue), style: StrokeStyle(lineWidth: 9, lineCap: .round))
        context.fill(head, with: .color(blue))
        context.stroke(head, with: .color(blue), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
    }

    /// 半透明的图标带着小手（合上的手）顺着箭头滑进去，一遍 2.4 秒。
    private func drawGhost(_ context: GraphicsContext, _ time: TimeInterval) {
        let cycle = 2.4
        let phase = CGFloat(time.truncatingRemainder(dividingBy: cycle) / cycle)
        // 0–0.15 浮出来，0.15–0.8 滑过去，0.8–1 在尖上淡掉
        let move = min(1, max(0, (phase - 0.15) / 0.65))
        let eased = move < 0.5 ? 2 * move * move : 1 - pow(-2 * move + 2, 2) / 2
        let fade = phase < 0.15 ? phase / 0.15 : phase > 0.8 ? max(0, 1 - (phase - 0.8) / 0.2) : 1
        let along = DragGuide.start.y > 0 ? eased * 0.97 : 0
        let start = CGPoint(x: DragGuide.tile.x, y: DragGuide.tile.y)
        let onCurve = point(along)
        // 先从图标块里提起来，再接到箭头上
        let lift = min(1, phase / 0.15)
        let center = phase < 0.15
            ? CGPoint(x: start.x + (DragGuide.start.x - start.x) * lift, y: start.y + (DragGuide.start.y - start.y) * lift)
            : onCurve
        let size: CGFloat = 46 * (1 - 0.18 * eased)
        var ghost = context
        ghost.opacity = 0.82 * fade
        ghost.addFilter(.shadow(color: .black.opacity(0.2), radius: 6, y: 3))
        if let icon = NSApp.applicationIconImage {
            ghost.draw(Image(nsImage: icon), in: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
        }
        var hand = context
        hand.opacity = fade
        hand.draw(Image(nsImage: NSCursor.closedHand.image), at: CGPoint(x: center.x + 4, y: center.y + 6))
    }
}

/// Eyeline 的图标：按住拖出去，拖的就是 Eyeline.app 本身（系统设置的列表收到它就加上）。
private struct AppIconDrag: NSViewRepresentable {
    let dragging: (Bool) -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.dragging = dragging
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.dragging = dragging
    }

    final class DragView: NSView, NSDraggingSource {
        var dragging: ((Bool) -> Void)?
        private let icon = NSApp.applicationIconImage ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

        override func draw(_ dirtyRect: NSRect) {
            icon.draw(in: bounds)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            NSCursor.closedHand.set()
        }

        override func mouseDragged(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            item.setDraggingFrame(bounds, contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            dragging?(true)
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging?(false)
        }
    }
}
