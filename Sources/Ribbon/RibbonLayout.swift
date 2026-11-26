import AppKit
import CoreText

// MARK: - 提词条的位置
//
// 菜单栏中间的一条毛玻璃，高度和菜单栏一样，直角。
//
// 眼睛和嘴不在同一个字上：念出声的时候，眼睛总是比嘴快两三个字。
// 所以对准摄像头的不是「正在念的字」，而是眼睛停的地方：
// - 蓝点 = 眼睛该看的地方，正对摄像头（屏幕正中）。
// - 正在念的字在蓝点左边两三个字（lookahead）；蓝点上面是马上要念的字。
// - 有刘海：摄像头被刘海挡着，蓝点放在刘海右边最近、看得见字的地方。
// 横向偏一度左右，看的人就会觉得你没在看他（往下偏能宽容得多），
// 在 MacBook 上大概就是三个字宽，所以亮的部分集中在蓝点附近，远处的字暗一些。
// 两头伸多远可以拖胶囊的边缘来改，记在设置里（以字号为单位）。

struct RibbonGeometry: Equatable {
    /// 窗口（就是这条胶囊）在屏幕坐标里的位置。
    var frame: NSRect
    /// 刘海在窗口里的横向范围。
    var notch: ClosedRange<CGFloat>?
    /// 下一个要念的字从这里开始（窗口坐标）。
    var anchor: CGFloat
    /// 蓝点的横向位置：眼睛该看的地方。没有刘海时就是摄像头的位置。
    var dot: CGFloat
    var fontSize: CGFloat
    /// 状态文字（暂停、速度、倒数）的右边缘。
    var statusRight: CGFloat
    /// 出现时从这一段往两边打开：刘海，或者摄像头那一点。
    var openFrom: ClosedRange<CGFloat>
    var cornerRadius: CGFloat = 0
    /// 屏幕上摄像头（屏幕正中）在窗口坐标里的位置，拖边缘改宽度时用。
    var camera: CGFloat

    var width: CGFloat { frame.width }
    var height: CGFloat { frame.height }

    /// 眼睛比嘴快多少（以字号为单位）：中文大约两三个字。
    static let lookahead: CGFloat = 2.5

    static func make(screen: NSScreen, size: Int, left: Double, right: Double) -> RibbonGeometry {
        let screenFrame = screen.frame
        let notchHeight = screen.safeAreaInsets.top
        let status = statusItems(on: screen)
        // 菜单栏多高：有刘海就是刘海的高度；否则量右边图标的窗口，量不到再问系统。
        let menuBar = notchHeight > 0 ? notchHeight
            : (status.height ?? max(screenFrame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness, 22))
        let step = min(max(0, size), Preferences.sizeSteps - 1)
        // 字号从菜单栏自己的字号起算：中号就和菜单一样大。
        let menuFont = NSFont.menuBarFont(ofSize: 0).pointSize
        let fontSize = menuFont + [-1, 0, 2, 4, 6][step]
        let height = step <= 1 ? menuBar : max(menuBar, (fontSize * 1.7).rounded())
        let leftExtent = (CGFloat(left) * fontSize).rounded()
        let rightExtent = (CGFloat(right) * fontSize).rounded()

        if notchHeight > 0, let leftArea = screen.auxiliaryTopLeftArea, let rightArea = screen.auxiliaryTopRightArea {
            // 这两块区域的 minX 都是屏幕的左边，不管是不是全局坐标。
            let notch = (leftArea.maxX - leftArea.minX)...(rightArea.minX - leftArea.minX)
            let camera = (notch.lowerBound + notch.upperBound) / 2
            let anchor = notch.upperBound + max(8, fontSize * 0.5)
            let gaze = anchor + fontSize * lookahead
            let start = max(0, min(notch.lowerBound - fontSize * 4, camera - leftExtent))
            let end = min(screenFrame.width, max(anchor + fontSize * 8, camera + rightExtent))
            let local = (notch.lowerBound - start)...(notch.upperBound - start)
            return RibbonGeometry(
                frame: NSRect(x: screenFrame.minX + start, y: screenFrame.maxY - height, width: end - start, height: height),
                notch: local, anchor: anchor - start, dot: gaze - start, fontSize: fontSize,
                statusRight: local.lowerBound - fontSize * 0.6, openFrom: local, camera: camera - start)
        }

        let camera = (screenFrame.width / 2).rounded()
        let start = max(0, camera - max(fontSize * 4, leftExtent))
        let end = min(screenFrame.width, camera + max(fontSize * 8, rightExtent))
        let local = camera - start
        let anchor = (local - fontSize * lookahead).rounded()
        return RibbonGeometry(
            frame: NSRect(x: screenFrame.minX + start, y: screenFrame.maxY - height, width: end - start, height: height),
            notch: nil, anchor: anchor, dot: local, fontSize: fontSize,
            statusRight: anchor - fontSize * 0.8, openFrom: local...local, camera: local)
    }

    /// 菜单栏右边那些图标（状态栏）：最左边从哪里开始、窗口多高（就是菜单栏的高度）。
    /// 读的是窗口的位置，不需要录屏权限。
    static func statusItems(on screen: NSScreen) -> (left: CGFloat?, height: CGFloat?) {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return (nil, nil) }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let top = primaryHeight - screen.frame.maxY
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        var leftmost: CGFloat?
        var heights: [CGFloat] = []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == statusLevel,
                  (window[kCGWindowOwnerPID as String] as? Int) != me,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  abs(rect.minY - top) < 3, rect.height > 12, rect.height < 60,
                  rect.minX > screen.frame.minX + screen.frame.width * 0.5, rect.maxX <= screen.frame.maxX + 1
            else { continue }
            leftmost = min(leftmost ?? .greatestFiniteMagnitude, rect.minX - screen.frame.minX)
            heights.append(rect.height)
        }
        let height = heights.sorted().dropFirst(heights.count / 2).first
        return (leftmost, height)
    }

    /// 带摄像头的那块屏幕：MacBook 自己的屏。找不到就用主屏幕。
    static func screen(for display: RibbonDisplay) -> NSScreen {
        let screens = NSScreen.screens
        if display == .builtIn {
            if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) { return notched }
            if let builtIn = screens.first(where: { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                    .map { CGDisplayIsBuiltin($0) != 0 } ?? false
            }) { return builtIn }
        }
        return NSScreen.screens.first ?? NSScreen.main!
    }
}

// MARK: - 排好的一行字

/// 整份稿子排成一行，切成小段（每段一个 CTLine），只画看得见的那几段。
final class RibbonText {
    struct Chunk {
        var range: NSRange
        var line: CTLine
        var x: CGFloat
        var width: CGFloat
    }

    let script: Script
    let fontSize: CGFloat
    private(set) var chunks: [Chunk] = []
    /// 第 i 个词的起点、终点（横向，从整行开头算）。
    private(set) var starts: [CGFloat] = []
    private(set) var ends: [CGFloat] = []
    private(set) var width: CGFloat = 0
    let ascent: CGFloat
    let descent: CGFloat

    static let paper = NSColor.white

    init(script: Script, fontSize: CGFloat) {
        self.script = script
        self.fontSize = fontSize
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let noteFont = NSFont.systemFont(ofSize: (fontSize * 0.85).rounded(), weight: .regular)
        ascent = font.ascender
        descent = -font.descender

        let text = NSMutableAttributedString(string: script.display, attributes: [
            .font: font, .foregroundColor: RibbonText.paper
        ])
        for span in script.spans {
            switch span.kind {
            case .speech: break
            case .note:
                text.addAttributes([.font: noteFont, .foregroundColor: RibbonText.paper.withAlphaComponent(0.5)], range: span.range)
            case .pause:
                text.addAttributes([.foregroundColor: RibbonText.paper.withAlphaComponent(0.5)], range: span.range)
            case .gap:
                text.addAttributes([.foregroundColor: RibbonText.paper.withAlphaComponent(0.35)], range: span.range)
            }
        }

        // 在每个大空格后面切；太长的一段在词的边界再切一刀。
        var cuts: [Int] = []
        for span in script.spans where span.kind == .gap { cuts.append(span.range.location + span.range.length) }
        var boundaries: [Int] = [0]
        var tokenIndex = 0
        for cut in cuts + [text.length] {
            while let last = boundaries.last, cut - last > 240 {
                while tokenIndex < script.tokens.count && script.tokens[tokenIndex].range.location < last + 200 { tokenIndex += 1 }
                guard tokenIndex < script.tokens.count, script.tokens[tokenIndex].range.location < cut else { break }
                boundaries.append(script.tokens[tokenIndex].range.location)
            }
            if cut > (boundaries.last ?? 0) { boundaries.append(cut) }
        }

        var x: CGFloat = 0
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
            let range = NSRange(location: start, length: end - start)
            let line = CTLineCreateWithAttributedString(text.attributedSubstring(from: range))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            chunks.append(Chunk(range: range, line: line, x: x, width: width))
            x += width
        }
        self.width = x

        starts.reserveCapacity(script.tokens.count)
        ends.reserveCapacity(script.tokens.count)
        var chunkIndex = 0
        for token in script.tokens {
            while chunkIndex + 1 < chunks.count && token.range.location >= chunks[chunkIndex].range.location + chunks[chunkIndex].range.length {
                chunkIndex += 1
            }
            guard chunkIndex < chunks.count else { break }
            let chunk = chunks[chunkIndex]
            let local = token.range.location - chunk.range.location
            starts.append(chunk.x + CTLineGetOffsetForStringIndex(chunk.line, local, nil))
            let localEnd = min(chunk.range.length, local + token.range.length)
            ends.append(chunk.x + CTLineGetOffsetForStringIndex(chunk.line, localEnd, nil))
        }
        // 最后一个词之后：整行的末尾。
    }

    /// 第 i 个词开头到下一个词开头有多宽（含标点、空格、备注）。
    func advance(_ index: Int) -> CGFloat {
        guard index >= 0, index < starts.count else { return 0 }
        return (index + 1 < starts.count ? starts[index + 1] : (ends.last ?? width)) - starts[index]
    }

    /// 平均每个词往前走多宽：匀速模式按它换算成像素速度。
    var averageAdvance: CGFloat {
        guard let first = starts.first, let last = ends.last, !starts.isEmpty else { return 0 }
        return (last - first) / CGFloat(starts.count)
    }

    /// 位置（第几个词，可以带小数）→ 横向坐标。在相邻两个词的开头之间连续地走，没有跳变。
    func x(at position: Double) -> CGFloat {
        guard !starts.isEmpty else { return 0 }
        let end = ends.last ?? width
        if position >= Double(starts.count) { return end }
        let index = max(0, Int(position.rounded(.down)))
        let fraction = CGFloat(position - Double(index))
        return starts[index] + advance(index) * fraction
    }

    /// 横向坐标 → 位置。拖动和滚动用。
    func position(atX x: CGFloat) -> Double {
        guard !starts.isEmpty else { return 0 }
        if x <= starts[0] { return 0 }
        if x >= (ends.last ?? 0) { return Double(starts.count) }
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= x { low = mid } else { high = mid - 1 }
        }
        let span = max(1, advance(low))
        return Double(low) + Double(min(1, max(0, (x - starts[low]) / span)))
    }

    /// 横向坐标落在哪个词上（双击跳转用）：落在空隙里就算后面那个词。
    func token(atX x: CGFloat) -> Int {
        guard !starts.isEmpty else { return 0 }
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if ends[mid] <= x { low = mid + 1 } else { high = mid }
        }
        return min(low, starts.count - 1)
    }
}

// MARK: - 缓动

/// CSS 那样的 cubic-bezier。数值和 OMO 网站一致。
struct Ease {
    let x1, y1, x2, y2: Double

    static let out = Ease(x1: 0.16, y1: 1, x2: 0.3, y2: 1)
    static let inOut = Ease(x1: 0.65, y1: 0, x2: 0.35, y2: 1)

    func callAsFunction(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        // 先由 x 解出曲线参数 u，再算 y。
        var u = t
        for _ in 0..<8 {
            let x = bezier(u, x1, x2) - t
            let dx = derivative(u, x1, x2)
            if abs(x) < 1e-5 || abs(dx) < 1e-6 { break }
            u = min(1, max(0, u - x / dx))
        }
        return bezier(u, y1, y2)
    }

    private func bezier(_ u: Double, _ a: Double, _ b: Double) -> Double {
        let v = 1 - u
        return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u
    }

    private func derivative(_ u: Double, _ a: Double, _ b: Double) -> Double {
        let v = 1 - u
        return 3 * v * v * a + 6 * v * u * (b - a) + 3 * u * u * (1 - b)
    }
}
