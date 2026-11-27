import SwiftUI
import AppKit

// MARK: - 编辑器
//
// 一张白纸，字在中间一栏（最宽 640）。提词的时候不能改字：念过的部分变成雾灰，
// 纸会跟着滚到正在念的那一行。左边空白里有一个蓝色的小 ▶，标出按播放会从哪一句开始（光标所在那一句的开头）。

struct ScriptEditor: NSViewRepresentable {
    @Binding var text: String
    var documentID: UUID?
    var editable: Bool
    /// 提词时：原文里念到哪了。
    var progress: Int?
    /// 播放会从原文哪里开始（左边的 ▶）。
    var startOffset: Int?
    /// 要求把光标放到这里（serial 变了才执行）。top：把这一行滚到最上面（翻幻灯片时用）。
    var focus: (offset: Int, serial: Int, top: Bool)?
    /// 一页一段的稿子：每一页从哪开始，左边空白里标上页码。
    var pageMarks: [(number: Int, offset: Int)] = []
    /// 缩放（⌘= ⌘-）：字号、一栏的宽度跟着变。
    var zoom: CGFloat = 1
    var onCursor: (Int) -> Void
    var onImport: ([URL]) -> Void
    /// 触控板捏合：放大缩小多少（NSEvent.magnification）。
    var onPinch: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 28, left: 0, bottom: 110, right: 0)

        let textView = PaperTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.onImport = { urls in context.coordinator.parent.onImport(urls) }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false   // 白底由外面的滚动视图画：自己画的话会盖住左边空白里画的蓝点和页码
        textView.backgroundColor = .white
        textView.insertionPointColor = Paper.nsAccent
        textView.selectedTextAttributes = [.backgroundColor: Paper.nsAccent.withAlphaComponent(0.22)]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.zoom = zoom
        textView.defaultParagraphStyle = textView.paragraph
        textView.typingAttributes = textView.attributes
        textView.onPinch = { context.coordinator.parent.onPinch($0) }
        textView.placeholder = String(localized: "Paste or drop a script")
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PaperTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        if textView.zoom != zoom { textView.zoom = zoom }

        if coordinator.documentID != documentID {
            coordinator.documentID = documentID
            coordinator.applying = true
            textView.string = text
            textView.restyle()
            coordinator.applying = false
            let offset = min(focus?.offset ?? 0, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: offset, length: 0))
            textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
            coordinator.focusSerial = focus?.serial
            // 在左边列表里点的：键盘留在列表（选中一直是蓝的，↑↓ 接着换稿子），不抢过来
            DispatchQueue.main.async {
                guard !(textView.window?.firstResponder is NSTableView) else { return }
                textView.window?.makeFirstResponder(textView)
            }
        } else if textView.string != text && !coordinator.editing && !textView.hasMarkedText() {
            // 外面改了字（输入法还在组字时不动它）：换掉，光标留在原来的地方，不跳到结尾
            // 这份稿子之前的撤销记录对不上了，丢掉
            coordinator.forgetUndo(for: coordinator.documentID)
            let selection = textView.selectedRange()
            coordinator.applying = true
            textView.string = text
            textView.restyle()
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            coordinator.applying = false
        }

        if let focus, focus.serial != coordinator.focusSerial {
            coordinator.focusSerial = focus.serial
            let offset = min(focus.offset, (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: offset, length: 0))
            if focus.top {
                textView.scrollToTop(characterAt: offset)
            } else {
                textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
            }
        }

        textView.pageMarks = pageMarks
        textView.isEditable = editable
        textView.startOffset = progress == nil ? startOffset : nil
        textView.showProgress(progress)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScriptEditor
        var documentID: UUID?
        var focusSerial: Int?
        var applying = false
        var editing = false

        init(_ parent: ScriptEditor) { self.parent = parent }

        /// 每份稿子自己的撤销记录。以前换稿子时把整个窗口的撤销清空了，删掉一份讲稿后 ⌘Z 就找不回来；
        /// 现在打字的撤销跟着各自的稿子走，窗口的撤销（删除、改名）不受影响。
        private var undoManagers: [UUID: UndoManager] = [:]

        func undoManager(for view: NSTextView) -> UndoManager? {
            guard let id = documentID else { return nil }
            if let manager = undoManagers[id] { return manager }
            let manager = UndoManager()
            undoManagers[id] = manager
            return manager
        }

        func forgetUndo(for id: UUID?) {
            if let id { undoManagers[id] = nil }
        }

        func textDidChange(_ notification: Notification) {
            // 输入法还在组字（拼音、语音输入的半成品）：先不交给外面，等字定下来那一下再交
            // （每打一个拼音字母都存一遍、重排一遍，豆包这类输入法会很卡，还会被换掉的字顶回结尾）
            guard !applying, let textView = notification.object as? NSTextView, !textView.hasMarkedText() else { return }
            editing = true
            parent.text = textView.string
            editing = false
            (textView as? PaperTextView)?.restyle(around: textView.selectedRange().location)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let textView = notification.object as? NSTextView, !textView.hasMarkedText() else { return }
            parent.onCursor(textView.selectedRange().location)
        }
    }
}

final class PaperTextView: NSTextView {
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

    var placeholder = ""
    var onImport: (([URL]) -> Void)?
    private var shownProgress: Int?
    private var progressLine = -1

    var startOffset: Int? {
        didSet { if startOffset != oldValue { needsDisplay = true } }
    }

    var pageMarks: [(number: Int, offset: Int)] = [] {
        didSet { if !pageMarks.elementsEqual(oldValue, by: { $0 == $1 }) { needsDisplay = true } }
    }

    static let columnWidth: CGFloat = 640
    static let font = NSFont.systemFont(ofSize: 17, weight: .regular)

    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.42
        style.paragraphSpacing = 9
        return style
    }()

    static let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: Paper.nsInk, .paragraphStyle: paragraph
    ]

    /// 「## 第 3 页」这样的分页标题：小一号、灰色，和上一页的稿子隔开一点。
    static let headingParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.2
        style.paragraphSpacing = 6
        style.paragraphSpacingBefore = 18
        return style
    }()

    static let headingAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Paper.nsGray,
        .paragraphStyle: headingParagraph
    ]

    // MARK: 缩放

    var zoom: CGFloat = 1 {
        didSet {
            guard zoom != oldValue else { return }
            defaultParagraphStyle = paragraph
            restyle()
            typingAttributes = attributes
            updateInsets()
            needsDisplay = true
        }
    }
    var onPinch: ((CGFloat) -> Void)?

    var bodyFont: NSFont { .systemFont(ofSize: (17 * zoom).rounded(), weight: .regular) }
    var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.42
        style.paragraphSpacing = 9 * zoom
        return style
    }
    var attributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: Paper.nsInk, .paragraphStyle: paragraph]
    }
    var headingAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.2
        style.paragraphSpacing = 6 * zoom
        style.paragraphSpacingBefore = 18 * zoom
        return [.font: NSFont.systemFont(ofSize: (13 * zoom).rounded(), weight: .semibold), .foregroundColor: Paper.nsGray,
                .paragraphStyle: style]
    }

    override func magnify(with event: NSEvent) { onPinch?(event.magnification) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    private func updateInsets() {
        let side = max(40, ((frame.width - PaperTextView.columnWidth * zoom) / 2).rounded())
        if textContainerInset.width != side { textContainerInset = NSSize(width: side, height: 24) }
    }

    func restyle() {
        guard let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(attributes, range: all)
        styleHeadings(in: all)
        storage.endEditing()
        shownProgress = nil
    }

    /// 打字时只重排光标这一段和上一段（回车会把一段拆成两段）。输入法还在组字时不动，免得打断中文输入。
    func restyle(around location: Int) {
        guard let storage = textStorage, !hasMarkedText() else { return }
        let source = storage.string as NSString
        guard source.length > 0 else { return }
        let here = source.paragraphRange(for: NSRange(location: min(location, source.length), length: 0))
        let start = here.location > 0 ? source.paragraphRange(for: NSRange(location: here.location - 1, length: 0)).location : 0
        let span = NSRange(location: start, length: NSMaxRange(here) - start)
        storage.beginEditing()
        storage.setAttributes(attributes, range: span)
        styleHeadings(in: span)
        storage.endEditing()
        typingAttributes = attributes
    }

    private func styleHeadings(in range: NSRange) {
        guard let storage = textStorage else { return }
        let source = storage.string as NSString
        let headingAttributes = self.headingAttributes
        source.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, line, enclosing, _ in
            guard Script.pageNumber(source.substring(with: line)) != nil else { return }
            storage.addAttributes(headingAttributes, range: enclosing)
        }
    }

    /// 念过的部分变灰，并让正在念的那一行留在视野里。
    func showProgress(_ offset: Int?) {
        guard offset != shownProgress, let layoutManager else { return }
        shownProgress = offset
        let length = (string as NSString).length
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        guard let offset else {
            progressLine = -1
            return
        }
        let read = min(offset, length)
        if read > 0 {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: Paper.nsFog,
                                                forCharacterRange: NSRange(location: 0, length: read))
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(read, max(0, length - 1)))
        let line = Int(layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY)
        if line != progressLine {
            progressLine = line
            scrollToCenter(characterAt: read)
        }
    }

    /// 把 offset 那一行滚到最上面：翻到第几页，这一页的稿子就从顶上开始。
    func scrollToTop(characterAt offset: Int) {
        guard let layoutManager, let textContainer, let scroll = enclosingScrollView else { return }
        let length = (string as NSString).length
        guard length > 0 else { return }
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: min(offset, length - 1))
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        // 分页标题的段前空白也在这一行里：让标题的字离上边十几点。
        let top = -scroll.contentInsets.top
        let y = rect.minY + textContainerOrigin.y + PaperTextView.headingParagraph.paragraphSpacingBefore - 16
        let maxY = max(top, frame.height - scroll.contentView.bounds.height + scroll.contentInsets.bottom)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: min(max(top, y), maxY)))
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func scrollToCenter(characterAt offset: Int) {
        guard let layoutManager, let scroll = enclosingScrollView else { return }
        let length = (string as NSString).length
        guard length > 0 else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(offset, length - 1))
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let y = rect.midY + textContainerOrigin.y - scroll.contentView.bounds.height * 0.38
        let maxY = max(0, frame.height - scroll.contentView.bounds.height + scroll.contentInsets.bottom)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: min(max(-scroll.contentInsets.top, y), maxY)))
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func draw(_ dirtyRect: NSRect) {
        // NSTextView 画完字会把裁剪区留在正文那一栏里：存一下、画完还原，左边空白里才画得上蓝点和页码。
        NSGraphicsContext.saveGraphicsState()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        if string.isEmpty {
            let origin = textContainerOrigin
            (placeholder as NSString).draw(at: NSPoint(x: origin.x, y: origin.y + 4), withAttributes: [
                .font: bodyFont, .foregroundColor: Paper.nsFog
            ])
            return
        }
        // 一页一段：每一页第一行的左边标上页码。
        if !pageMarks.isEmpty, let layoutManager {
            let length = (string as NSString).length
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: Paper.nsFog
            ]
            for mark in pageMarks where mark.offset < length {
                let glyph = layoutManager.glyphIndexForCharacter(at: mark.offset)
                let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                let label = "\(mark.number)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: textContainerOrigin.x - 28 - size.width,
                                       y: line.midY + textContainerOrigin.y - size.height / 2), withAttributes: attributes)
            }
        }
        // 「从这里开始」：左边空白里一个蓝色的小播放三角，对着开始的那一行（在最前面也标，一看就知道按播放从哪念）。
        if let startOffset, startOffset >= 0, let layoutManager {
            let length = (string as NSString).length
            guard startOffset < length else { return }
            let glyph = layoutManager.glyphIndexForCharacter(at: startOffset)
            let rect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let center = NSPoint(x: textContainerOrigin.x - 16, y: rect.midY + textContainerOrigin.y)
            let play = NSBezierPath()
            play.move(to: NSPoint(x: center.x - 3, y: center.y - 4.5))
            play.line(to: NSPoint(x: center.x + 4.5, y: center.y))
            play.line(to: NSPoint(x: center.x - 3, y: center.y + 4.5))
            play.close()
            play.lineJoinStyle = .round
            play.lineWidth = 1.5
            let blue = NSColor(srgbRed: 0x4A / 255, green: 0xA8 / 255, blue: 0xFF / 255, alpha: 1)
            blue.setFill()
            blue.setStroke()
            play.fill()
            play.stroke()
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    /// 拖进来的文件交给整个窗口（有提示），这里只接文字。
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

    // 万一文件还是落到了这里：一样导入。
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            onImport?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }
}
