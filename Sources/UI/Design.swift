import SwiftUI
import AppKit

// MARK: - 设计
//
// 和 OMO 其他 App 一样：白纸、墨色、好字。
// - 编辑器是一张白纸，纸上只有字；按钮少，能用图标就不用字。
// - 主色是图标里眼球的蓝（accent，#4AA8FF）：播放键、主按钮、选中、光标、开关、加载都用它；
//   浅一点的 accentSoft 做选中的底色。其余是墨色和灰。
// - 动效只用 OMO 的两条曲线：出现用 ease-out，按下用一点点回弹。
// - 所有文案写英文，在 Localizable.xcstrings 里翻成中文。

enum Paper {
    static let ink = Color(rgb: 0x0B0B0C)
    static let charcoal = Color(rgb: 0x3A3A3C)
    static let gray = Color(rgb: 0x6E6E73)
    static let fog = Color(rgb: 0xA1A1A6)
    static let line = Color(rgb: 0xE6E6E3)
    static let haze = Color(rgb: 0xF4F4F2)
    static let white = Color.white
    static let blue = Color(rgb: 0x4AA8FF)
    /// 主色：眼球的蓝。
    static let accent = Color(rgb: 0x4AA8FF)
    /// 主色压在白字下面时用的渐变（上亮下深一点点，像图标里的玻璃）。
    static let accentFill = LinearGradient(colors: [Color(rgb: 0x62B5FF), Color(rgb: 0x3E9CF8)], startPoint: .top, endPoint: .bottom)
    /// 选中的底色。
    static let accentSoft = Color(rgb: 0x4AA8FF).opacity(0.13)
    /// 写成字的主色（白底上读得清）。
    static let accentText = Color(rgb: 0x2F8CEB)
    /// 左边列表里的标题（比墨色软一点）。
    static let listTitle = Color(rgb: 0x1D1D1F)
    static let nsAccent = NSColor(srgbRed: 0x4A / 255, green: 0xA8 / 255, blue: 0xFF / 255, alpha: 1)

    static let nsInk = NSColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1)
    static let nsFog = NSColor(srgbRed: 0xA1 / 255, green: 0xA1 / 255, blue: 0xA6 / 255, alpha: 1)
    static let nsGray = NSColor(srgbRed: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255, alpha: 1)
}

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, opacity: 1)
    }
}

extension Animation {
    /// OMO 的 ease-out：cubic-bezier(.16, 1, .3, 1)。
    static func omoOut(_ duration: Double = 0.45) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: duration) }
    /// OMO 的轻微回弹：cubic-bezier(.34, 1.56, .64, 1)。
    static func omoSpring(_ duration: Double = 0.32) -> Animation { .timingCurve(0.34, 1.56, 0.64, 1, duration: duration) }
}

/// 按下去缩一点，放开时轻轻弹回来。
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.omoSpring(), value: configuration.isPressed)
    }
}

/// 只有图标的小按钮：选中是墨色，没选中是雾灰，鼠标放上去深一点。
struct IconToggle: View {
    let symbol: String
    let selected: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false
    /// 鼠标停一下就在上面冒出名字（系统的 tooltip 要等一两秒，还不好看）。
    @State private var tip = false
    @State private var tipTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Paper.ink : hovering ? Paper.gray : Paper.fog)
                .frame(width: 30, height: 30)
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
            if tip {
                HoverTip(text: help)
                    .offset(y: -38)
                    .transition(.opacity.combined(with: .offset(y: 3)))
            }
        }
        .animation(.omoOut(0.18), value: tip)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    /// 玻璃：macOS 26 上是系统的 Liquid Glass；老系统退回磨砂材质。
    @ViewBuilder func glass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 0.5).allowsHitTesting(false))
                .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
        }
    }
}

/// 浮在文字上面、能点的东西（底栏、滚动方式面板、上手提示、回放）报上自己盖住了窗口哪一块（窗口坐标）。
/// 文字框只在没被盖住的地方显示 I 形光标，盖住的地方是箭头。
final class CursorShields {
    static let shared = CursorShields()
    static let changed = Notification.Name("EyelineCursorShieldsChanged")
    private(set) var rects: [String: NSRect] = [:]
    /// 每块是谁报的：换了一条录像（.id 变了）新的先报上、旧的淡出后才拿走，旧的不能把新的那块也撤了。
    private var owners: [String: ObjectIdentifier] = [:]

    func set(_ key: String, _ rect: NSRect?, owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        if rect == nil, let current = owners[key], current != id { return }
        owners[key] = rect == nil ? nil : id
        guard rects[key] != rect else { return }
        rects[key] = rect
        NotificationCenter.default.post(name: CursorShields.changed, object: nil)
    }
}

extension View {
    /// 这块盖在文字上面：鼠标在这里是箭头，不露出下面文字框的 I 形光标。
    func shieldsTextCursor(_ key: String) -> some View {
        background(ShieldReporter(key: key))
    }
}

/// 放在背景里的一个看不见的 NSView：随时报上自己在窗口里的位置；拿走了就撤掉。
private struct ShieldReporter: NSViewRepresentable {
    let key: String
    func makeNSView(context: Context) -> Reporter { Reporter(key: key) }
    func updateNSView(_ view: Reporter, context: Context) { view.report() }

    final class Reporter: NSView {
        let key: String
        init(key: String) {
            self.key = key
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            report()
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            report()
        }
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            report()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { CursorShields.shared.set(key, nil, owner: self) }
        }

        func report() {
            guard window != nil else { return }
            CursorShields.shared.set(key, convert(bounds, to: nil), owner: self)
        }
    }
}

/// 文字的 I 形光标只该出现在看得见字、又没被别的东西盖住的地方。
enum TextCursor {
    /// 这个文字框里该显示 I 形光标的几块（框自己的坐标）。
    static func rects(in view: NSView) -> [NSRect] {
        var pieces = [view.visibleRect]
        for shield in CursorShields.shared.rects.values {
            let covered = view.convert(shield, from: nil)
            pieces = pieces.flatMap { subtract(covered, from: $0) }
        }
        return pieces.filter { $0.width > 0.5 && $0.height > 0.5 }
    }

    static func update(_ view: NSView, _ event: NSEvent) {
        let point = view.convert(event.locationInWindow, from: nil)
        (rects(in: view).contains { $0.contains(point) } ? NSCursor.iBeam : NSCursor.arrow).set()
    }

    /// rect 减去 hole：剩下最多四块（上、下、左、右）。
    private static func subtract(_ hole: NSRect, from rect: NSRect) -> [NSRect] {
        let cut = rect.intersection(hole)
        guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [rect] }
        var pieces: [NSRect] = []
        if cut.minY > rect.minY { pieces.append(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY)) }
        if cut.maxY < rect.maxY { pieces.append(NSRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY)) }
        if cut.minX > rect.minX { pieces.append(NSRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height)) }
        if cut.maxX < rect.maxX { pieces.append(NSRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height)) }
        return pieces
    }
}

extension View {
    /// 鼠标停一下就在上面冒出这句（底栏这些地方用；系统的 tooltip 要等一两秒）。
    func hoverTip(_ text: String) -> some View { modifier(HoverTipModifier(text: text)) }
}

private struct HoverTipModifier: ViewModifier {
    let text: String
    @State private var tip = false
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                task?.cancel()
                if inside {
                    task = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        if !Task.isCancelled { tip = true }
                    }
                } else {
                    tip = false
                }
            }
            .overlay(alignment: .top) {
                if tip {
                    HoverTip(text: text)
                        .offset(y: -38)
                        .transition(.opacity.combined(with: .offset(y: 3)))
                }
            }
            .animation(.omoOut(0.18), value: tip)
    }
}

/// 鼠标停在图标上冒出来的名字：一小块玻璃。
struct HoverTip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Paper.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glass(cornerRadius: 9)
            .fixedSize()
            .allowsHitTesting(false)
    }
}

// MARK: - 第一次打开：三步上手

/// 要指给人看的几处（稿子、走字方式、播放）在哪：一层层报上来。
struct CoachAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func coachAnchor(_ key: String) -> some View {
        anchorPreference(key: CoachAnchors.self, value: .bounds) { [key: $0] }
    }
}

/// 在右边那一栏里量出这一步要指的东西在窗口里的位置，交给整个窗口上面那层（CoachMarks）去画。
struct CoachReporter: View {
    @ObservedObject var model: AppModel
    let anchors: [String: Anchor<CGRect>]

    var body: some View {
        GeometryReader { geometry in
            let rect = target(in: geometry)
            Color.clear
                .onAppear { model.coachHole = rect }
                .onChangeOf(rect) { _, new in model.coachHole = new }
        }
        .allowsHitTesting(false)
    }

    private func target(in geometry: GeometryProxy) -> CGRect? {
        guard let index = model.coachStep, index < CoachMarks.steps.count,
              let anchor = anchors[CoachMarks.steps[index].key] else { return nil }
        let origin = geometry.frame(in: .global).origin
        return geometry[anchor].offsetBy(dx: origin.x, dy: origin.y)
    }
}

/// 三步：在哪写稿子、选一种走字方式、怎么开始和停。
/// 整个窗口暗下来，只留要指的那一块亮着、外面一圈主色；旁边一张白卡片写一句话，点「下一步」。
/// 点哪里、按任意键都到下一步；Esc 跳过。
struct CoachMarks: View {
    @ObservedObject var model: AppModel

    enum Placement { case center, above, aboveTrailing }

    static let steps: [(key: String, text: String, placement: Placement)] = [
        ("script", String(localized: "Write here, or drop a script or slides in"), .center),
        ("modes", String(localized: "Pick how the words move"), .above),
        ("play", String(localized: "⌘↩ to start, Esc to stop"), .aboveTrailing),
    ]

    var body: some View {
        GeometryReader { geometry in
            let origin = geometry.frame(in: .global).origin
            if let index = model.coachStep, index < CoachMarks.steps.count, let global = model.coachHole {
                let step = CoachMarks.steps[index]
                let target = global.offsetBy(dx: -origin.x, dy: -origin.y)
                let center = step.placement == .center
                let hole = center ? target.insetBy(dx: 16, dy: 16) : target.insetBy(dx: -8, dy: -6)
                let radius: CGFloat = center ? 20 : 14
                ZStack(alignment: .topLeading) {
                    Spotlight(hole: hole, radius: radius)
                        .fill(Color.black.opacity(0.48), style: FillStyle(eoFill: true))
                        .contentShape(Rectangle())
                        .onTapGesture { model.nextCoachStep() }
                        .shieldsTextCursor("coach")
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Paper.accent, lineWidth: 2)
                        .shadow(color: Paper.accent.opacity(0.6), radius: 12)
                        .frame(width: hole.width, height: hole.height)
                        .position(x: hole.midX, y: hole.midY)
                        .allowsHitTesting(false)
                    card(index: index, text: step.text)
                        .modifier(Placed(placement: step.placement, hole: hole, size: geometry.size))
                        .id(index)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.omoOut(0.35), value: model.coachStep)
        .animation(.omoOut(0.35), value: model.coachHole)
    }

    /// 一张白卡片：一句话；下面是第几步，和「下一步」（最后一步是「知道了」）。
    private func card(index: Int, text: String) -> some View {
        let last = index + 1 == CoachMarks.steps.count
        return VStack(alignment: .leading, spacing: 16) {
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Paper.ink)
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    ForEach(0..<CoachMarks.steps.count, id: \.self) { dot in
                        Capsule()
                            .fill(dot == index ? Paper.accent : Paper.fog.opacity(0.45))
                            .frame(width: dot == index ? 14 : 6, height: 6)
                    }
                }
                Spacer(minLength: 28)
                Button { model.nextCoachStep() } label: {
                    Text(last ? LocalizedStringKey("Got it") : LocalizedStringKey("Next"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Paper.accentFill))
                        .shadow(color: Paper.accent.opacity(0.35), radius: 6, y: 2)
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(minWidth: 280, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white))
        .shadow(color: .black.opacity(0.25), radius: 28, y: 12)
        .fixedSize()
    }

    /// 暗下来的一层：整块，中间挖掉要指的那一块（换一步时，挖掉的地方滑过去）。
    struct Spotlight: Shape {
        var hole: CGRect
        var radius: CGFloat

        var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
            get { AnimatablePair(AnimatablePair(hole.minX, hole.minY), AnimatablePair(hole.width, hole.height)) }
            set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
        }

        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
            return path
        }
    }

    /// 卡片放哪：亮着的那块正中，或者它上面（居中 / 右边对齐）。
    private struct Placed: ViewModifier {
        let placement: Placement
        let hole: CGRect
        let size: CGSize

        func body(content: Content) -> some View {
            switch placement {
            case .center:
                content
                    .frame(width: hole.width, height: hole.height, alignment: .center)
                    .offset(x: hole.minX, y: hole.minY)
            case .above:
                content.frame(width: max(0, min(size.width, hole.midX * 2)), height: max(0, hole.minY - 14), alignment: .bottom)
            case .aboveTrailing:
                content.frame(width: max(0, hole.maxX), height: max(0, hole.minY - 14), alignment: .bottomTrailing)
            }
        }
    }
}


// MARK: - macOS 13 也能跑：14 才有的几个 API，13 上换个写法

extension View {
    /// onChange，新旧两个值都给。macOS 14 起用系统的；13 上自己记着上一次的值。
    @ViewBuilder
    func onChangeOf<V: Equatable>(_ value: V, _ action: @escaping (_ old: V, _ new: V) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value, action)
        } else {
            modifier(OldOnChange(value: value, action: action))
        }
    }

    /// SF Symbol 换图时的过渡（macOS 14 起才有；13 上直接换）。
    @ViewBuilder
    func symbolReplaceTransition() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }
}

private struct OldOnChange<V: Equatable>: ViewModifier {
    let value: V
    let action: (V, V) -> Void
    @State private var last: V?

    func body(content: Content) -> some View {
        content
            .onAppear { last = value }
            .onChange(of: value) { new in
                action(last ?? new, new)
                last = new
            }
    }
}

extension NSApplication {
    /// 把 App 拿到最前面（macOS 14 起的 activate()；13 上用旧的那个）。
    func bringToFront() {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - 自己画的控件（不用系统的）

/// 加载中：一段主色的圆弧在转。
struct Spinner: View {
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.82)
            .stroke(Paper.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .accessibilityLabel(Text("Loading"))
    }
}

/// 开关：开是主色，关是浅灰，白色的小圆点滑过去。
struct Switch: View {
    /// 读屏软件把它当开关读（.isToggle 是 macOS 14 起才有的；13 上当按钮）。
    static var toggleTrait: AccessibilityTraits {
        if #available(macOS 14.0, *) { return .isToggle }
        return .isButton
    }

    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.omoSpring(0.3)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(Paper.accentFill) : AnyShapeStyle(Color.black.opacity(0.1)))
                    .frame(width: 36, height: 21)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .frame(width: 17, height: 17)
                    .padding(2)
            }
            .frame(width: 36, height: 21)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(Switch.toggleTrait)
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }
}

/// 几个选项排成一条：浅灰的轨道，选中的那个是一块白，字是主色。
struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button {
                    withAnimation(.omoOut(0.28)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Paper.accentText : Paper.gray)
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background {
                            if selected {
                                Capsule().fill(.white)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.05)))
        .fixedSize()
    }
}

/// 选项多的时候：一个小按钮写着现在选的，点开往下垂一块玻璃列表（不用系统的菜单）。
struct Dropdown<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @Binding var open: Bool
    @State private var hovering: Value?

    var body: some View {
        let current = options.first { $0.value == selection }?.label ?? ""
        Button {
            withAnimation(.omoOut(0.22)) { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(current)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Paper.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Paper.gray)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(Color.black.opacity(open ? 0.08 : 0.05)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .overlay(alignment: .topTrailing) {
            if open {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(options.indices, id: \.self) { index in
                        let option = options[index]
                        let selected = option.value == selection
                        Button {
                            selection = option.value
                            withAnimation(.omoOut(0.2)) { open = false }
                        } label: {
                            HStack(spacing: 8) {
                                Text(option.label)
                                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                    .foregroundStyle(selected ? Paper.accentText : Paper.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 12)
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Paper.accent)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(hovering == option.value ? Paper.accentSoft : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in hovering = inside ? option.value : (hovering == option.value ? nil : hovering) }
                    }
                }
                .padding(5)
                .frame(minWidth: 190)
                .glass(cornerRadius: 14)
                .fixedSize()
                .offset(y: 32)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }
}

/// 小字的按钮：主色的字，浅主色的底。
struct PillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Paper.accentText)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(Paper.accentSoft))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

/// 主按钮：主色的胶囊，白字。
struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(Capsule().fill(Paper.accentFill))
                .shadow(color: Paper.accent.opacity(0.35), radius: 8, y: 3)
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

/// 窗口里浮起来的一块玻璃（设置、快捷键）：后面压暗一点，玻璃从 97% 放大到原大、淡入；右上角一个 ×。
/// 内容比窗口高就能滚。点外面、Esc 收起。
struct FloatingSheet<Content: View>: View {
    let close: () -> Void
    @ViewBuilder let content: Content
    @State private var shown = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                // 上面空出一行给右上角的 ×
                ViewThatFits(in: .vertical) {
                    content.padding(.top, 24)
                    ScrollView { content.padding(.top, 24) }
                        .scrollIndicators(.never)
                        .frame(height: max(200, geometry.size.height - 56))
                }
                .fixedSize(horizontal: true, vertical: false)
                .overlay(alignment: .topTrailing) {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Paper.gray)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.black.opacity(0.05)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressStyle())
                    .padding(12)
                }
                .glass(cornerRadius: 26)
                .shadow(color: .black.opacity(0.12), radius: 30, y: 12)
                .scaleEffect(shown ? 1 : 0.97)
                .opacity(shown ? 1 : 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .shieldsTextCursor("sheet")
        .onAppear { withAnimation(.omoOut(0.32)) { shown = true } }
    }
}

/// 小标题旁边的图标按钮：图标 13 点，鼠标放上去有一块浅底，冒出名字。
struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Paper.accent : Paper.gray)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Paper.accentSoft : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .hoverTip(help)
        .accessibilityLabel(help)
    }
}


/// 文字框的右键菜单：剪切、拷贝、粘贴。
enum TextMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "")
        return menu
    }
}
