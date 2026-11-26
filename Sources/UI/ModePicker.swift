import SwiftUI

// MARK: - 滚动方式
//
// 底栏上一个按钮（现在这种的图标）；点开是一块玻璃，四张卡片并排，每张一个小动画演示它怎么走：
// - 识别跟随：声波一跳，蓝色就跳到下一个字；不出声就停。
// - 说话时滚动：出声时整片字平平往上走，不出声就停；不认字。
// - 匀速滚动：没有声波，字一直匀速往上走。
// - 关键词提纲：中间一次一个词（讲稿里加粗的，按顺序），下面的小圆点是第几个，按 → 换下一个。
// 点卡片选它；点外面、按 Esc 收起。

/// 底栏上的按钮：现在这种的图标，鼠标停上去冒出名字，点一下打开面板。
struct ModeButton: View {
    @ObservedObject var model: AppModel
    let mode: PromptMode
    @State private var hovering = false
    @State private var tip = false
    @State private var tipTask: Task<Void, Never>?

    var body: some View {
        Button {
            withAnimation(.omoOut(0.28)) { model.showingModes.toggle() }
        } label: {
            Image(systemName: mode.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(model.showingModes ? Paper.accent : hovering ? Paper.ink : Paper.charcoal)
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { inside in
            hovering = inside
            tipTask?.cancel()
            if inside {
                tipTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if !Task.isCancelled { tip = true }
                }
            } else {
                tip = false
            }
        }
        .overlay(alignment: .top) {
            if tip && !model.showingModes {
                HoverTip(text: mode.title)
                    .offset(y: -38)
                    .transition(.opacity.combined(with: .offset(y: 3)))
            }
        }
        .animation(.omoOut(0.18), value: tip)
        .accessibilityLabel(mode.title)
    }
}

/// 打开的面板：四张卡片并排。
struct ModePanel: View {
    let mode: PromptMode
    /// 这种方式还有选项时（速度、跟随语速），卡片下面一行。
    var options: AnyView?
    let choose: (PromptMode) -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                ForEach(PromptMode.allCases) { item in
                    ModeCard(mode: item, selected: item == mode) { choose(item) }
                }
            }
            if let options {
                options
                    .padding(.bottom, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(8)
        .glass(cornerRadius: 22)
        .fixedSize()
        .animation(.omoOut(0.25), value: options == nil)
    }
}

private struct ModeCard: View {
    let mode: PromptMode
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                ModeAnimation(mode: mode)
                    .frame(width: 124, height: 80)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.85)))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? Paper.blue.opacity(0.8) : Color.black.opacity(0.06), lineWidth: selected ? 2 : 0.5)
                    )
                Text(mode.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Paper.ink : Paper.charcoal)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(hovering && !selected ? 0.04 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 每种方式的小动画（一直循环）。画的是一小段稿子：几行字（灰色的小胶囊），中间那条是正在念的位置。
struct ModeAnimation: View {
    let mode: PromptMode
    private static let start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(ModeAnimation.start)
            Canvas { context, size in draw(context, size, t) }
        }
    }

    func draw(_ context: GraphicsContext, _ size: CGSize, _ t: Double) {
        switch mode {
        case .follow: drawFollow(context, size, t)
        case .pace: drawPace(context, size, t)
        case .steady: drawSteady(context, size, t)
        case .keywords: drawKeywords(context, size, t)
        }
    }

    // MARK: 字

    /// 每一行有几个词、每个词多宽（循环用）。
    private static let lines: [[CGFloat]] = [
        [16, 24, 12, 20], [22, 14, 26], [12, 20, 16, 22], [26, 18, 14], [14, 22, 20, 12], [20, 16, 24],
    ]
    private static let spacing: CGFloat = 13
    private static let left: CGFloat = 12
    private static let gap: CGFloat = 4

    private static func words(ofLine index: Int) -> [CGFloat] { lines[((index % lines.count) + lines.count) % lines.count] }

    /// 念到哪：读的那一行固定在这个高度。
    private func readY(_ size: CGSize) -> CGFloat { size.height * 0.42 }

    /// 画一片字：offset 是往上滚了多少（以第 0 行为准）。
    /// highlight：识别跟随时正在念的那个词（第几行、第几个）；它前面的字深一点，后面的浅。
    private func drawLines(_ context: GraphicsContext, _ size: CGSize, offset: CGFloat, highlight: (line: Int, word: Int)? = nil) {
        let spacing = ModeAnimation.spacing
        let read = readY(size)
        let first = Int(floor((offset - read) / spacing)) - 1
        let last = first + Int(size.height / spacing) + 3
        for line in first...last {
            let y = read + CGFloat(line) * spacing - offset
            guard y > -6, y < size.height + 6 else { continue }
            var x = ModeAnimation.left
            for (index, width) in ModeAnimation.words(ofLine: line).enumerated() {
                let rect = CGRect(x: x, y: y - 2.5, width: width, height: 5)
                let color: Color
                if let highlight {
                    if line == highlight.line && index == highlight.word {
                        color = Paper.blue
                    } else if line < highlight.line || (line == highlight.line && index < highlight.word) {
                        color = Color.black.opacity(0.13)
                    } else {
                        color = Color.black.opacity(0.32)
                    }
                } else {
                    let distance = y - read
                    color = distance < -spacing * 0.5 ? Color.black.opacity(0.13)
                        : distance < spacing * 0.5 ? Color.black.opacity(0.55) : Color.black.opacity(0.28)
                }
                context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(color))
                x += width + ModeAnimation.gap
            }
        }
    }

    // MARK: 声音

    /// 说两秒多、停一秒，一直这样。返回到现在一共说了多久、现在在不在说。
    private func talking(_ t: Double) -> (time: Double, now: Bool) {
        let cycle = 3.3, talk = 2.3
        let phase = t.truncatingRemainder(dividingBy: cycle)
        return (floor(t / cycle) * talk + min(phase, talk), phase < talk)
    }

    /// 右下角的小声波：在说话就跳，不说话就平。
    private func drawWave(_ context: GraphicsContext, _ size: CGSize, _ t: Double, on: Bool) {
        let bars = 4
        let width: CGFloat = 2.5, gapX: CGFloat = 2.5
        let total = CGFloat(bars) * width + CGFloat(bars - 1) * gapX
        let base = CGPoint(x: size.width - 10 - total, y: size.height - 9)
        // 底下一块白，免得和字叠在一起
        context.fill(Path(roundedRect: CGRect(x: base.x - 5, y: base.y - 13, width: total + 10, height: 17), cornerRadius: 6),
                     with: .color(.white.opacity(0.92)))
        for index in 0..<bars {
            let wobble = on ? (0.35 + 0.65 * abs(sin(t * 9 + Double(index) * 1.7))) : 0.12
            let height = max(2.5, 11 * CGFloat(wobble))
            let rect = CGRect(x: base.x + CGFloat(index) * (width + gapX), y: base.y - height / 2 - 4, width: width, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: 1.25), with: .color(on ? Paper.blue : Color.black.opacity(0.2)))
        }
    }

    // MARK: 四种

    /// 识别跟随：说一个词，蓝色跳到下一个词；整片字跟着正在念的那一行走。
    private func drawFollow(_ context: GraphicsContext, _ size: CGSize, _ t: Double) {
        let voice = talking(t)
        var remaining = Int(voice.time * 2.6)
        var line = 0
        while remaining >= ModeAnimation.words(ofLine: line).count {
            remaining -= ModeAnimation.words(ofLine: line).count
            line += 1
        }
        let count = CGFloat(ModeAnimation.words(ofLine: line).count)
        let offset = (CGFloat(line) + CGFloat(remaining) / count) * ModeAnimation.spacing
        drawLines(context, size, offset: offset, highlight: (line, remaining))
        drawWave(context, size, t, on: voice.now)
    }

    /// 说话时滚动：出声就平平往上走，不出声就停；不认字。
    private func drawPace(_ context: GraphicsContext, _ size: CGSize, _ t: Double) {
        let voice = talking(t)
        drawLines(context, size, offset: CGFloat(voice.time) * 8)
        drawWave(context, size, t, on: voice.now)
    }

    /// 匀速滚动：一直匀速往上走。
    private func drawSteady(_ context: GraphicsContext, _ size: CGSize, _ t: Double) {
        drawLines(context, size, offset: CGFloat(t) * 8)
    }

    /// 关键词提纲：讲稿里加粗的词（或每行一个）按顺序一次出一个；下面的小圆点是一共几个、到第几个；
    /// 右下角的 → 键按一下，换下一个。
    private func drawKeywords(_ context: GraphicsContext, _ size: CGSize, _ t: Double) {
        let words = [String(localized: "Intro"), String(localized: "Story"), String(localized: "Demo"), String(localized: "Thanks")]
        let each = 1.8
        let index = Int(t / each) % words.count
        let phase = t.truncatingRemainder(dividingBy: each)
        // 换上来的词：淡入、往上浮一点
        let appear = min(1, phase / 0.18)
        var text = context.resolve(Text(words[index]).font(.system(size: 15, weight: .semibold)).foregroundColor(Paper.ink))
        text.shading = .color(Paper.ink.opacity(appear))
        context.draw(text, at: CGPoint(x: size.width / 2, y: size.height * 0.4 + CGFloat(1 - appear) * 4), anchor: .center)
        // 一共几个、到第几个
        let step: CGFloat = 9
        let startX = size.width / 2 - step * CGFloat(words.count - 1) / 2
        for dot in 0..<words.count {
            let center = CGPoint(x: startX + CGFloat(dot) * step, y: size.height * 0.68)
            let radius: CGFloat = dot == index ? 2.6 : 2.1
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(dot == index ? Paper.blue : Color.black.opacity(0.14)))
        }
        // 右下角的 → 键：换词前按下去一下
        let pressed = phase > each - 0.42 && phase < each - 0.12
        var key = CGRect(x: size.width - 30, y: size.height - 24, width: 20, height: 16)
        if pressed { key = key.offsetBy(dx: 0, dy: 1) }
        let shape = Path(roundedRect: key, cornerRadius: 4)
        context.fill(shape, with: .color(pressed ? Paper.blue.opacity(0.16) : .white))
        context.stroke(shape, with: .color(pressed ? Paper.blue.opacity(0.7) : Color.black.opacity(0.18)), lineWidth: 0.8)
        let arrow = context.resolve(Text("→").font(.system(size: 10, weight: .semibold))
            .foregroundColor(pressed ? Paper.blue : Paper.gray))
        context.draw(arrow, at: CGPoint(x: key.midX, y: key.midY), anchor: .center)
    }
}

/// 动画的某一帧（测试时拼图看用）。
struct ModeFrame: View {
    let mode: PromptMode
    let t: Double

    var body: some View {
        Canvas { context, size in ModeAnimation(mode: mode).draw(context, size, t) }
    }
}
