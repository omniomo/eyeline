import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 分镜表
//
// 配了幻灯片的稿子：一页一页往下排，每页幻灯片放大，这一页要说的话浅浅地盖在它底下，直接在上面打字。
// 绑定靠的就是这一页本身（存成一页一段，见 PagedScript）。
// - 点幻灯片、翻幻灯片：那一页滚出来，光标放进它的话里。光标进了哪一页，幻灯片就翻到哪一页。
// - ↑ ↓ 走到头、Tab、在空行上回车：到上一页 / 下一页（空一行就是翻一页）。粘贴整篇稿子：按空行分到后面几页。
// - 提词时整个窗口变成放映（见 SlideShow）。

struct Storyboard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var deck: SlideDeck
    @ObservedObject var prompter: Prompter
    @ObservedObject var prefs: Preferences
    @State private var width: CGFloat = 800
    /// 捏合开始时的缩放。
    @State private var pinchStart: Double?

    var body: some View {
        let paged = model.paged
        let prompting = model.promptingSelection
        let active = model.activePage
        let rows = max(1, deck.pageCount, paged.pages.count)
        // 幻灯片默认 640 宽，⌘= ⌘- 或捏合缩放；窗口窄了就跟着窗口
        let zoom = CGFloat(prefs.zoom)
        let card = max(240, min(width - 64, (640 * zoom).rounded()))
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: (26 * zoom).rounded()) {
                    ForEach(Array(1...rows), id: \.self) { number in
                        SlideCard(number: number, width: card, text: paged.text(ofPage: number), inDeck: number <= deck.pageCount,
                                  active: number == active, prompting: prompting,
                                  progress: model.pageProgress(number),
                                  focus: model.pageFocus.flatMap { $0.page == number ? ($0.serial, $0.atEnd) : nil },
                                  deck: deck, model: model)
                            .id(number)
                    }
                    if let removed = model.document?.removedSlides, !removed.isEmpty {
                        RemovedSlides(texts: removed) { model.dropRemovedSlide($0) }
                            .frame(width: card)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
                .padding(.bottom, 120)
            }
            .onChangeOf(model.pageFocus?.serial) { _, _ in
                // 先确保那一页排出来了（看得见就不动）；光标放进去以后，台词框自己滚到看得见（见 CaptionScrollView.reveal）
                guard let focus = model.pageFocus else { return }
                proxy.scrollTo(focus.page)
            }
            .onChangeOf(active) { _, page in
                guard prompting else { return }
                withAnimation(.omoOut(0.4)) { proxy.scrollTo(page, anchor: .top) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .simultaneousGesture(
            MagnificationGesture()   // macOS 13 也有；14 起的 MagnifyGesture 一样用
                .onChanged { magnification in
                    let start = pinchStart ?? prefs.zoom
                    pinchStart = start
                    prefs.setZoom(start * magnification)
                }
                .onEnded { _ in pinchStart = nil })
        .background(Paper.haze)
    }
}

/// 一页：幻灯片，底下盖着这一页的话。
private struct SlideCard: View {
    let number: Int
    let width: CGFloat
    let text: String
    let inDeck: Bool
    let active: Bool
    let prompting: Bool
    let progress: Int?
    let focus: (serial: Int, atEnd: Bool)?
    @ObservedObject var deck: SlideDeck
    let model: AppModel
    /// 鼠标在这一页上：浮起来一点（点幻灯片会选中这一页）。
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if inDeck, let image = deck.thumbnail(number, height: width / deck.aspect) {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Rectangle().fill(Paper.white)
                }
            }
            .aspectRatio(deck.aspect, contentMode: .fit)
            .frame(width: width)
            .contentShape(Rectangle())
            .onTapGesture { if inDeck { model.selectPage(number) } }
            SlideCaption(text: text, editable: !prompting, progress: progress, focus: focus,
                         fontSize: max(11, min(28, (width / 640 * 15).rounded())),
                         maxHeight: max(60, width / deck.aspect * 0.45),
                         placeholder: String(localized: "What to say on this slide…"),
                         onChange: { model.setPageText(number, $0) },
                         onCaret: { model.focusPage(number, at: $0) },
                         onLeave: { model.movePage(from: number, by: $0) },
                         onSpread: { model.pastePages($0, intoPage: number, replacing: $1, undo: $2) })
        }
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5).allowsHitTesting(false))
        // 选中的这一页：外面隔一点绕一圈淡蓝（像系统的焦点环），不压在幻灯片上
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Paper.blue.opacity(active ? 0.55 : 0), lineWidth: 2.5)
            .padding(-4.5)
            .allowsHitTesting(false))
        .shadow(color: .black.opacity(active || hovering ? 0.09 : 0.05), radius: active || hovering ? 15 : 8, y: active || hovering ? 5 : 2)
        .onHover { hovering = $0 }
        .animation(.omoOut(0.2), value: hovering)
        .overlay(alignment: .topLeading) {
            Text(inDeck ? "\(number)" : String(localized: "Not in the slides"))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Paper.gray)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.9)))
                .padding(10)
                .allowsHitTesting(false)
        }
        .animation(.omoOut(0.25), value: active)
    }
}

/// 浮在幻灯片底部的一块台词板：一块玻璃（macOS 26 的 Liquid Glass），一看就是 Eyeline 放上去的，不是幻灯片自己的字。
/// 编辑时直接在里面打字，放映时念过的字变淡。
struct SlideCaption: View {
    let text: String
    var editable: Bool
    var progress: Int?
    var focus: (serial: Int, atEnd: Bool)?
    var fontSize: CGFloat
    /// 台词板最高多高（不算四周留白）；超过就在里面滚。
    var maxHeight: CGFloat = .greatestFiniteMagnitude
    var placeholder: String = ""
    var onChange: (String) -> Void = { _ in }
    var onCaret: (Int) -> Void = { _ in }
    var onLeave: (Int) -> Void = { _ in }
    var onSpread: (String, NSRange, UndoManager?) -> Bool = { _, _, _ in false }

    var body: some View {
        let radius = fontSize * 0.9
        PageTextView(text: text, editable: editable, progress: progress, focus: focus, fontSize: fontSize,
                     maxHeight: maxHeight, placeholder: placeholder, onChange: onChange, onCaret: onCaret, onLeave: onLeave, onSpread: onSpread)
            .padding(.horizontal, fontSize * 1.0)
            .padding(.vertical, fontSize * 0.7)
            .glass(cornerRadius: radius)
            .padding(fontSize * 0.8)
    }
}

/// 幻灯片里删掉的那几页的话：不念了，先留着。
private struct RemovedSlides: View {
    let texts: [String]
    let onDrop: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Removed from the slides")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Paper.gray)
            ForEach(Array(texts.enumerated()), id: \.offset) { index, text in
                HStack(alignment: .top, spacing: 10) {
                    Text(text)
                        .font(.system(size: 14))
                        .foregroundStyle(Paper.gray)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    IconToggle(symbol: "xmark", selected: false, help: String(localized: "Remove")) { onDrop(index) }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }
}

/// 拖进来的文件（.onDrop 给的）读成 URL，在主线程交出去。
enum FileDrop {
    static func load(_ providers: [NSItemProvider], then handle: @escaping ([URL]) -> Void) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url { urls.append(url) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { handle(urls) } }
        return true
    }
}

// MARK: - 一行里的编辑框

/// 一页的话：会跟着字数长高的编辑框（自己不滚动，外面的分镜表滚）。
struct PageTextView: NSViewRepresentable {
    let text: String
    var editable: Bool
    /// 提词时这一行念到哪了（这一行里的位置）。
    var progress: Int?
    /// 要求把光标放进来（serial 变了才执行）。
    var focus: (serial: Int, atEnd: Bool)?
    var fontSize: CGFloat = 16
    /// 最高多高：字再多就在里面滚（跟着光标），不再往上盖住幻灯片。
    var maxHeight: CGFloat = .greatestFiniteMagnitude
    var placeholder: String
    var onChange: (String) -> Void
    var onCaret: (Int) -> Void
    var onLeave: (Int) -> Void
    /// 粘贴了一整篇（带空行）：交给外面分到后面几页；返回 false 就照普通粘贴。
    var onSpread: (String, NSRange, UndoManager?) -> Bool = { _, _, _ in false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CaptionScrollView {
        let scroll = CaptionScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        let view = RowTextView(usingTextLayoutManager: false)
        view.fontSize = fontSize
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.insertionPointColor = Paper.nsAccent
        view.selectedTextAttributes = [.backgroundColor: Paper.nsAccent.withAlphaComponent(0.22)]
        view.typingAttributes = view.attributes
        view.string = text
        view.restyle()
        context.coordinator.known = text
        scroll.documentView = view
        scroll.maxHeight = maxHeight
        return scroll
    }

    func updateNSView(_ scroll: CaptionScrollView, context: Context) {
        let view = scroll.text
        let coordinator = context.coordinator
        coordinator.parent = self
        if scroll.maxHeight != maxHeight {
            scroll.maxHeight = maxHeight
            scroll.invalidateIntrinsicContentSize()
        }
        view.fontSize = fontSize
        view.placeholder = placeholder
        view.onLeave = { onLeave($0) }
        view.onSpread = { onSpread($0, $1, $2) }
        // 外面改了这一页（幻灯片改了、全文里改了）才换掉；自己刚打的字不换（打到一半的换行之类）
        if text != coordinator.known, !view.hasMarkedText() {
            coordinator.known = text
            if view.string != text {
                // 外面改了这一页：换掉，光标留在原来的地方
                let selection = view.selectedRange()
                defer { view.setSelectedRange(NSRange(location: min(selection.location, (view.string as NSString).length), length: 0)) }
                coordinator.applying = true
                view.string = text
                view.restyle()
                // 排好版再画：不然画的时候才排、框跟着变高，SwiftUI 又得重新排一遍
                if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
                coordinator.applying = false
            }
        }
        view.isEditable = editable
        view.showProgress(progress)
        if let focus, focus.serial != coordinator.focusSerial {
            coordinator.focusSerial = focus.serial
            DispatchQueue.main.async {
                // 在左边列表里刚选的这份稿子：键盘留在列表，不抢过来（不然选中先蓝后灰闪一下）
                if !(view.window?.firstResponder is NSTableView) { view.window?.makeFirstResponder(view) }
                let location = focus.atEnd ? (view.string as NSString).length : 0
                view.setSelectedRange(NSRange(location: location, length: 0))
                view.scrollRangeToVisible(view.selectedRange())
            }
            // 等分镜表自己那一下「滚到这一页」落定了再滚（不然会被它盖回去：台词框停在底栏下面）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { scroll.reveal() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CaptionScrollView, context: Context) -> CGSize? {
        let width = max(80, proposal.width ?? 400)
        return CGSize(width: width, height: min(nsView.text.height(forWidth: width), nsView.maxHeight))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PageTextView
        var applying = false
        var focusSerial: Int?
        /// 外面那份这一页的字，上次是什么（自己打字送出去的也算，按存进去的样子：去掉空行）。
        var known = ""
        /// 上次告诉外面的光标位置：没变就不再说（开始 / 结束提词时编辑框会自己发一次）。
        private var reported: Int?

        init(_ parent: PageTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            // 输入法还在组字：等字定下来再交给外面（见 ScriptEditor）
            guard !applying, let view = notification.object as? RowTextView, !view.hasMarkedText() else { return }
            view.restyle()
            if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
            // 回车出来的空行不会存进稿子（外面的字没变，不会重新排版），自己叫外面重新量一下高度
            view.enclosingScrollView?.invalidateIntrinsicContentSize()
            view.revealCaret()
            known = PagedScript.lines(view.string).joined(separator: "\n")
            parent.onChange(view.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let view = notification.object as? NSTextView, view.window?.firstResponder === view,
                  !view.hasMarkedText(), view.selectedRange().location != reported else { return }
            reported = view.selectedRange().location
            parent.onCaret(view.selectedRange().location)
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            reported = view.selectedRange().location
            parent.onCaret(view.selectedRange().location)
        }
    }
}

/// 台词板里的滚动框：字不多时跟字一样高；超过 maxHeight 就在里面滚。
/// 里面不用滚的时候，滚轮交给外面（整页往下翻），不会被它吃掉。
final class CaptionScrollView: NSScrollView {
    var maxHeight: CGFloat = .greatestFiniteMagnitude
    var text: RowTextView { documentView as! RowTextView }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: min(text.height(forWidth: max(1, contentView.bounds.width)), maxHeight))
    }

    /// 整个台词框露出来：外面的分镜表滚过来，底下给底栏留出地方，顶上留一点。
    func reveal() {
        guard let outer = enclosingScrollView else { return }
        let bar: CGFloat = 104, top: CGFloat = 16
        let rect = isFlipped
            ? NSRect(x: 0, y: -top, width: bounds.width, height: bounds.height + top + bar)
            : NSRect(x: 0, y: -bar, width: bounds.width, height: bounds.height + top + bar)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            scrollToVisible(rect)
        }
        outer.reflectScrolledClipView(outer.contentView)

    }

    override func scrollWheel(with event: NSEvent) {
        let overflows = text.frame.height > contentView.bounds.height + 1
        if overflows { super.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
    }
}

final class RowTextView: NSTextView {
    // 右键菜单只留剪切、拷贝、粘贴：系统那一长串（写作工具、自动填充、服务、语音……）用不上
    override func menu(for event: NSEvent) -> NSMenu? { TextMenu.make() }

    // 鼠标：只在看得见字、没被盖住的地方是 I 形；底栏、面板、回放盖着的地方是箭头（见 TextCursor）
    override func resetCursorRects() {
        for rect in TextCursor.rects(in: self) { addCursorRect(rect, cursor: .iBeam) }
    }
    private var shieldObserver: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard shieldObserver == nil else { return }
        shieldObserver = NotificationCenter.default.addObserver(forName: CursorShields.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, let window = self.window else { return }
            window.invalidateCursorRects(for: self)
        }
    }
    override func cursorUpdate(with event: NSEvent) { TextCursor.update(self, event) }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        TextCursor.update(self, event)
    }

    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    var onLeave: ((Int) -> Void)?
    var onSpread: ((String, NSRange, UndoManager?) -> Bool)?
    private var shownProgress: Int?

    /// 粘贴：话都进这一行。带空行的一大段，下面会问要不要按空行分到后面几页（见 AppModel.pastePages）。
    override func paste(_ sender: Any?) {
        if spreadPaste() { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if spreadPaste() { return }
        super.pasteAsPlainText(sender)
    }

    private func spreadPaste() -> Bool {
        guard isEditable, let pasted = NSPasteboard.general.string(forType: .string), let onSpread else { return false }
        return onSpread(pasted, selectedRange(), undoManager)
    }

    /// 拖进来的文件不归这一行管（交给分镜表：导入、配幻灯片），这里只接文字。
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

    /// 字号：分镜表里跟着幻灯片大小，放映时更大。
    var fontSize: CGFloat = 16 {
        didSet {
            guard fontSize != oldValue else { return }
            restyle()
            needsDisplay = true
        }
    }
    var rowFont: NSFont { .systemFont(ofSize: fontSize) }
    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.38
        style.paragraphSpacing = 2
        return style
    }()
    var attributes: [NSAttributedString.Key: Any] {
        [.font: rowFont, .foregroundColor: Paper.nsInk, .paragraphStyle: RowTextView.paragraph]
    }

    func restyle() {
        guard let storage = textStorage, !hasMarkedText() else { return }
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        typingAttributes = attributes
        shownProgress = nil
    }

    /// 这么宽的时候要多高。
    /// 用一套单独的排版来量，不动正在显示的这一套：量的时候改了它的宽，画的时候它会自己改大小，
    /// SwiftUI 跟着再排一遍又来量……大段粘贴时停不下来，AppKit 直接退出。
    func height(forWidth width: CGFloat) -> CGFloat {
        let line = ceil(ceil(rowFont.ascender - rowFont.descender + rowFont.leading) * 1.38)
        guard let storage = textStorage else { return line }
        let key = Measure(text: storage.string, width: width, fontSize: fontSize)
        if let measured, measured.key == key { return measured.height }
        let copy = NSTextStorage(attributedString: storage)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
        manager.addTextContainer(container)
        copy.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        // 末尾刚回车出来的空行（光标在那儿）也要算上高度，不然光标掉到框外面
        var used = manager.usedRect(for: container).maxY
        let extra = manager.extraLineFragmentRect
        if !extra.isEmpty { used = max(used, extra.maxY) }
        let height = max(line, ceil(used))
        measured = (key, height)
        return height
    }
    private struct Measure: Equatable {
        let text: String
        let width: CGFloat
        let fontSize: CGFloat
    }
    private var measured: (key: Measure, height: CGFloat)?

    /// 光标那一行露出来：框里字多到要滚时在框里滚；框本身被挡住了，外面的分镜表也滚过来。
    func revealCaret() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self else { return }
            self.scrollRangeToVisible(self.selectedRange())
            (self.enclosingScrollView as? CaptionScrollView)?.reveal()
        }
    }

    /// 念过的字变淡。
    func showProgress(_ offset: Int?) {
        guard offset != shownProgress, let layoutManager else { return }
        shownProgress = offset
        let length = (string as NSString).length
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        if let offset, offset > 0 {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: Paper.nsFog,
                                                forCharacterRange: NSRange(location: 0, length: min(offset, length)))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(at: NSPoint(x: 0, y: 1), withAttributes: [
            .font: rowFont, .foregroundColor: Paper.nsFog
        ])
    }

    /// 在空行上回车：这一页写完了，到下一页（空一行就是翻一页）。
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let caret = selectedRange()
        if caret.length == 0, caret.location == text.length, text.length == 0 || text.hasSuffix("\n") {
            if text.length > 0 { insertText("", replacementRange: NSRange(location: text.length - 1, length: 1)) }
            onLeave?(1)
            return
        }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) { onLeave?(1) }
    override func insertBacktab(_ sender: Any?) { onLeave?(-1) }

    override func moveUp(_ sender: Any?) {
        if caretLine(first: true) { onLeave?(-1) } else { super.moveUp(sender) }
    }

    override func moveDown(_ sender: Any?) {
        if caretLine(first: false) { onLeave?(1) } else { super.moveDown(sender) }
    }

    /// 光标在第一行（first）/ 最后一行。
    private func caretLine(first: Bool) -> Bool {
        guard let layoutManager, let textContainer else { return true }
        let length = (string as NSString).length
        guard length > 0 else { return true }
        layoutManager.ensureLayout(for: textContainer)
        let caret = selectedRange().location
        let used = layoutManager.usedRect(for: textContainer)
        let rect: NSRect
        if caret >= length {
            rect = layoutManager.extraLineFragmentTextContainer != nil ? layoutManager.extraLineFragmentRect
                : layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: length - 1), effectiveRange: nil)
        } else {
            rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: caret), effectiveRange: nil)
        }
        return first ? rect.minY <= used.minY + 1 : rect.maxY >= used.maxY - 1
    }
}
