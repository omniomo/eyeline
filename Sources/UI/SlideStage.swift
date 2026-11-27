import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - 稿子上面的幻灯片
//
// 当前这一页的大图，下面一排缩略图；左上角是页码，右上角「放映」。
// 点缩略图、点大图两边的箭头、或者点一下大图再按 ← →，就翻页：稿子跟着滚到这一页（见 AppModel.deckFlipped）。
// 稿子分了页、还没配 PDF：这里是一块「把 PDF 拖到这里」。

struct SlideStage: View {
    @ObservedObject var deck: SlideDeck
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        Group {
            if deck.isLoaded {
                loaded
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.haze)
    }

    // MARK: 有幻灯片

    private var loaded: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Arrow(symbol: "chevron.left", visible: hovering, enabled: deck.page > 1) { deck.step(-1) }
                PageView(deck: deck)
                    .aspectRatio(deck.aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.06), lineWidth: 1))
                    .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
                    .contentShape(Rectangle())
                    .onTapGesture { focused = true }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Arrow(symbol: "chevron.right", visible: hovering, enabled: deck.page < deck.pageCount) { deck.step(1) }
            }
            Filmstrip(deck: deck)
                .frame(height: 48)
        }
        .padding(.horizontal, 18)
        .padding(.top, 34)
        .padding(.bottom, 10)
        .overlay(alignment: .top) {
            HStack {
                Text("\(deck.page) / \(deck.pageCount)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Paper.gray)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.omoOut(0.2)) { hovering = inside } }
        .focusable()
        .focused($focused)
        .modifier(SlideKeys(deck: deck))
    }

    // MARK: 还没配幻灯片

    /// 一把摊开的文件图标（Keynote、PDF、PowerPoint）：一看就知道往这儿拖什么。
    /// 鼠标移上去、拖着文件进窗口时摊得更开；点一下选文件。正在转 PowerPoint 时下面一个小菊花。
    private var placeholder: some View {
        VStack(spacing: 18) {
            FileFan(spread: hovering || model.dragging != nil)
            if model.convertingSlides {
                Spinner(size: 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in hovering = inside }
        .onTapGesture { if !model.convertingSlides { model.chooseSlides() } }
        .help(String(localized: "Choose slides…"))
    }
}

/// 三张文件卡片（KEY、PDF、PPT）像一手牌一样摊开：白卡片、几道淡灰的线、角上一个彩色的类型标签。
struct FileFan: View {
    var spread: Bool
    var size: CGFloat = 80
    var kinds: [(label: String, color: Color)] = FileFan.slides

    /// 幻灯片：Keynote、PDF、PowerPoint。
    static let slides: [(label: String, color: Color)] = [
        ("KEY", Color(rgb: 0x3D8BFD)),
        ("PDF", Color(rgb: 0xE5484D)),
        ("PPT", Color(rgb: 0xE8743B)),
    ]
    /// 讲稿：文字、PDF、PowerPoint。
    static let scripts: [(label: String, color: Color)] = [
        ("TXT", Color(rgb: 0x8E8E93)),
        ("PDF", Color(rgb: 0xE5484D)),
        ("PPT", Color(rgb: 0xE8743B)),
    ]

    var body: some View {
        ZStack {
            ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
                let side = CGFloat(index - 1)
                FileCard(label: kind.label, color: kind.color, size: size, tagOnRight: side > 0)
                    .rotationEffect(.degrees(side * (spread ? 16 : 10)), anchor: .bottom)
                    .offset(x: side * size * (spread ? 0.52 : 0.4), y: abs(side) * (spread ? 7 : 3) - (spread && side == 0 ? 6 : 0))
                    .zIndex(side == 0 ? 1 : 0)
            }
        }
        .frame(width: size * 2.4, height: size * 1.3)
        .animation(.omoSpring(0.4), value: spread)
    }
}

private struct FileCard: View {
    let label: String
    let color: Color
    let size: CGFloat
    /// 右边那张的标签放右下角（左下角会被中间那张挡住）。
    var tagOnRight = false

    var body: some View {
        let radius = size * 0.1
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.white)
            VStack(alignment: .leading, spacing: size * 0.065) {
                ForEach(0..<3, id: \.self) { line in
                    Capsule()
                        .fill(Color.black.opacity(0.07))
                        .frame(width: size * (line == 2 ? 0.28 : 0.46), height: size * 0.045)
                }
            }
            .padding(.top, size * 0.15)
            .padding(.leading, size * 0.11)
            Text(label)
                .font(.system(size: size * 0.14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, size * 0.07)
                .padding(.vertical, size * 0.03)
                .background(RoundedRectangle(cornerRadius: size * 0.05, style: .continuous).fill(color))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tagOnRight ? .bottomTrailing : .bottomLeading)
                .padding(size * 0.1)
        }
        .frame(width: size * 0.78, height: size)
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: size * 0.08, y: size * 0.03)
    }
}

/// 大图两边的箭头：鼠标移进来才出现。
private struct Arrow: View {
    let symbol: String
    let visible: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Paper.charcoal)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white))
                .overlay(Circle().strokeBorder(Paper.line, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
        .opacity(visible && enabled ? 1 : 0)
        .disabled(!enabled)
    }
}

/// 一排缩略图，现在这页带一圈黑框，翻页时滚到中间。
private struct Filmstrip: View {
    @ObservedObject var deck: SlideDeck
    private let height: CGFloat = 40

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(0..<deck.pageCount, id: \.self) { index in
                        thumb(index + 1).id(index + 1)
                    }
                }
                .padding(.horizontal, 4)
                .frame(maxHeight: .infinity)
            }
            .onAppear { proxy.scrollTo(deck.page, anchor: .center) }
            .onChangeOf(deck.page) { _, page in
                withAnimation(.omoOut(0.3)) { proxy.scrollTo(page, anchor: .center) }
            }
        }
    }

    private func thumb(_ number: Int) -> some View {
        let current = number == deck.page
        return Button { deck.select(number) } label: {
            Group {
                if let image = deck.thumbnail(number, height: height) {
                    Image(nsImage: image).resizable()
                } else {
                    Color.white
                }
            }
            .aspectRatio(deck.aspect, contentMode: .fit)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 1))
            .padding(2.5)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(current ? Paper.ink : .clear, lineWidth: 1.5))
            .opacity(current ? 1 : 0.8)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Slide \(number)"))
    }
}

/// 大图：PDF 的这一页（矢量，多大都清楚）。点击交给外面。
struct PageView: NSViewRepresentable {
    @ObservedObject var deck: SlideDeck
    var background: NSColor = .white

    func makeNSView(context: Context) -> StagePDFView {
        let view = StagePDFView()
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.displayBox = .cropBox
        view.autoScales = true
        view.backgroundColor = background
        view.pageShadowsEnabled = false
        return view
    }

    func updateNSView(_ view: StagePDFView, context: Context) {
        if view.backgroundColor != background { view.backgroundColor = background }
        if view.document !== deck.document { view.document = deck.document }
        if let document = deck.document, let page = document.page(at: max(0, deck.page - 1)), view.currentPage != page {
            view.go(to: page)
        }
    }
}

final class StagePDFView: PDFView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 幻灯片和稿子中间的分隔线：上下拖改幻灯片的高度。
struct StageDivider: View {
    @ObservedObject var prefs: Preferences
    let total: CGFloat
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Paper.line)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let from = start ?? prefs.slideStage
                    start = from
                    prefs.slideStage = min(0.7, max(0.2, from + Double(value.translation.height / max(1, total))))
                }
                .onEnded { _ in start = nil })
            .padding(.vertical, -4)
    }
}

/// 有幻灯片的稿子在提词：整个窗口只有这一页幻灯片（窗口已经按幻灯片的比例摆好，见 AppModel.presentationChanged）。
/// 台词在屏幕顶上的提词条里，这里不重复。点一下、← →、翻页笔：翻页，提词条跟着到那一页的话。Esc 停。
struct SlideShow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var deck: SlideDeck
    @ObservedObject var prompter: Prompter

    var body: some View {
        let page = deck.page
        // 窗口铺满整块屏幕；顶上让出提词条那一条，幻灯片在剩下的地方放到最大（和录的那一块一样）
        GeometryReader { geometry in
            let top = model.presentationTopInset
            let size = fitted(in: CGSize(width: geometry.size.width, height: geometry.size.height - top))
            ZStack(alignment: .top) {
                Paper.white
                // 顶上让给提词条的那一条涂黑：和屏幕的黑边框、提词条连成一片，不留一道白缝
                // （系统全屏时菜单栏那一行也是黑的）
                Color.black.frame(height: top)
                if let image = deck.render(page, fitting: size) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .position(x: geometry.size.width / 2, y: top + (geometry.size.height - top) / 2)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { prompter.perform(.clickerForward) }
        .ignoresSafeArea()
    }

    /// 按幻灯片的比例，在这么大的地方里能放多大。
    private func fitted(in space: CGSize) -> CGSize {
        guard space.width > 0, space.height > 0 else { return .zero }
        let aspect = deck.aspect
        return space.width / space.height > aspect
            ? CGSize(width: (space.height * aspect).rounded(), height: space.height)
            : CGSize(width: space.width, height: (space.width / aspect).rounded())
    }
}


/// 幻灯片上的方向键、空格、Home / End 翻页（macOS 14 起；13 上用菜单和全局快捷键翻）。
private struct SlideKeys: ViewModifier {
    @ObservedObject var deck: SlideDeck

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .focusEffectDisabled()
                .onKeyPress(keys: [.leftArrow, .upArrow, .pageUp]) { _ in
                    deck.step(-1)
                    return .handled
                }
                .onKeyPress(keys: [.rightArrow, .downArrow, .pageDown, .space]) { _ in
                    deck.step(1)
                    return .handled
                }
                .onKeyPress(keys: [.home, .end]) { press in
                    deck.select(press.key == .home ? 1 : deck.pageCount)
                    return .handled
                }
        } else {
            content
        }
    }
}
