import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ScriptStore
    @Environment(\.openWindow) private var openWindow

    @ObservedObject private var prompter = AppModel.shared.prompter
    @State private var columns: NavigationSplitViewVisibility = .automatic
    /// 放幻灯片之前侧栏是什么样（放完还原）。
    @State private var columnsBeforeShow: NavigationSplitViewVisibility?

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(model: model, store: store, recorder: model.recorder)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            // 右边至少放得下底栏（时间、几个按钮、语速、播放），不然会被挤出窗口
            EditorPane(model: model, prompter: model.prompter, prefs: model.prefs)
                .frame(minWidth: model.presenting ? 0 : AppModel.detailMinWidth)
        }
        // 窗口最小尺寸；放幻灯片时窗口按幻灯片的比例摆，不限
        .frame(minWidth: model.presenting ? 200 : AppModel.detailMinWidth,
               minHeight: model.presenting ? 150 : 440)
        .navigationTitle("")
        // 放幻灯片：侧栏、工具栏都收起来，只剩幻灯片
        .toolbar(model.presenting ? .hidden : .visible, for: .windowToolbar)
        .onChange(of: model.presenting) { _, presenting in
            if presenting {
                columnsBeforeShow = columns
                columns = .detailOnly
            } else if let before = columnsBeforeShow {
                // 原来侧栏开着（.automatic 也算），就明确打开，不然收起后不会自己回来
                columns = before == .detailOnly ? .detailOnly : .all
                columnsBeforeShow = nil
            }
        }
        // 设置、快捷键：窗口里浮起来一块玻璃，点外面或 Esc 收起
        .overlay {
            if let sheet = model.sheet {
                FloatingSheet(close: { withAnimation(.omoOut(0.22)) { model.sheet = nil } }) {
                    switch sheet {
                    case .settings:
                        SettingsView(prefs: model.prefs, openShortcuts: { withAnimation(.omoOut(0.3)) { model.sheet = .shortcuts } }) {
                            model.prompter.ribbon?.relayout()
                        }
                    case .shortcuts:
                        ShortcutsView()
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.omoOut(0.28), value: model.sheet)
        // 整个窗口都能拖文件进来：拖进来时盖一层提示（松开会怎样），弄好了上面冒一句话。
        .overlay {
            if let drag = model.dragging {
                DropOverlay(drag: drag).transition(.opacity)
            }
        }
        .animation(.omoOut(0.2), value: model.dragging)
        .onDrop(of: [.fileURL], delegate: WindowDrop(model: model))
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

// MARK: - 稿子列表，和录好的视频

struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ScriptStore
    @ObservedObject var recorder: TakeRecorder
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $model.sidebarSelection) {
                Section {
                    ForEach(store.documents) { document in
                        ScriptRow(document: document, prompting: model.prompter.isActive && model.prompter.documentID == document.id,
                                  renaming: model.renaming == document.id,
                                  onRename: { model.rename(document.id, to: $0, undoManager: undoManager) })
                            .tag(AppModel.SidebarItem.script(document.id))
                            .listRowBackground(SelectionPill(selected: model.sidebarSelection == .script(document.id)))
                    }
                }
                // 录好的视频：新的在最上面，点一下在右边回放
                if !recorder.takes.isEmpty {
                    Section {
                        ForEach(recorder.takes) { take in
                            TakeRow(take: take, playing: recorder.take == take.url, new: recorder.unseen.contains(take.url))
                                .tag(AppModel.SidebarItem.take(take.url))
                                .listRowBackground(SelectionPill(selected: recorder.take == take.url))
                                .id(take.url)
                        }
                    } header: {
                        // 「在访达中打开」紧跟在标题后面（放最右边会被滚动条挡住）
                        HStack(spacing: 6) {
                            Text("Takes")
                            HeaderButton(symbol: "folder", help: String(localized: "Open in Finder")) { recorder.openFolder() }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // 右键菜单；双击讲稿（或者选中后按回车）改名。用的是列表自己的双击，行上不加手势：单击切换不受影响
            .contextMenu(forSelectionType: AppModel.SidebarItem.self) { items in
                if items.count == 1, let item = items.first { menu(for: item) }
            } primaryAction: { items in
                guard items.count == 1, case .script(let id) = items.first else { return }
                model.renaming = id
            }
            .animation(.omoOut(0.35), value: recorder.takes)
            // 刚录好一条：滚到它那里
            .onChange(of: recorder.takes.first?.url) { _, url in
                if let url { withAnimation(.omoOut(0.35)) { proxy.scrollTo(url) } }
            }
        }
        .onDeleteCommand {
            switch model.sidebarSelection {
            case .script(let id): model.delete(id, undoManager: undoManager)
            case .take(let url): model.trashTake(url)
            case nil: break
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.newScript() } label: { Image(systemName: "square.and.pencil") }
                    .help(String(localized: "New Script"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.show(.settings) } label: { Image(systemName: "gearshape") }
                    .help(String(localized: "Settings"))
            }
        }
    }

    /// 右键菜单：讲稿是改名、创建副本、移除幻灯片、删除；录好的视频是在访达中显示、移到废纸篓。
    @ViewBuilder private func menu(for item: AppModel.SidebarItem) -> some View {
        switch item {
        case .script(let id):
            Button("Rename") { model.renaming = id }
            Button("Duplicate") { model.duplicate(id) }
            if store[id]?.slides != nil {
                Button("Remove Slides") { model.removeSlides(id, undoManager: undoManager) }
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(id, undoManager: undoManager) }
        case .take(let url):
            Button("Show in Finder") { recorder.reveal(url) }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trashTake(url) }
        }
    }
}

/// 左边列表里的一份讲稿：前面一块小图（配了幻灯片是第一页，没配是一张白纸），标题，字数和大约多久。
/// 讲稿和录像每一行都一样高、小图一样大，标题对齐在同一条线上。
struct ScriptRow: View {
    let document: ScriptDocument
    let prompting: Bool
    /// 正在改名：标题变成输入框（回车确定，Esc 取消，点别处也算确定）。
    var renaming = false
    /// nil：取消；空字符串：不要名字了（回到用第一行当标题）。
    var onRename: (String?) -> Void = { _ in }
    /// 配了幻灯片：第一页的小图。
    @State private var thumbnail: NSImage?

    var body: some View {
        SidebarRowLayout(dot: prompting) {
            if document.slides != nil {
                ZStack {
                    Color.white
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    }
                }
                .task(id: document.slidesURL) {
                    if let url = document.slidesURL { thumbnail = await SlideThumbnails.first(of: url) }
                }
            } else {
                PaperTile()
            }
        } title: {
            if renaming {
                RenameField(text: document.title, onDone: onRename)
                    .frame(height: 17)
            } else {
                Text(document.title.isEmpty ? String(localized: "Untitled") : document.title)
                    .foregroundStyle(document.title.isEmpty ? Paper.fog : Paper.listTitle)
            }
        } detail: {
            Text(ScriptStats.of(document))
        }
        .background(SystemSelectionOff())
    }
}

/// 没配幻灯片的讲稿：一张小白纸，上面三行浅灰的字。
struct PaperTile: View {
    var body: some View {
        ZStack(alignment: .leading) {
            Color.white
            VStack(alignment: .leading, spacing: 3.5) {
                ForEach([20.0, 26.0, 14.0], id: \.self) { width in
                    Capsule().fill(Paper.fog.opacity(0.45)).frame(width: width, height: 2)
                }
            }
            .padding(.leading, 8)
        }
    }
}

/// 列表里一行的样子：小图（44×28，圆角、细边），右边两行字（标题 13 点，下面一行 11 点浅灰）。
/// dot：小图右上角一个主色的小点（正在提词、没看过的录像）。
struct SidebarRowLayout<Tile: View, Title: View, Detail: View>: View {
    var dot = false
    @ViewBuilder let tile: Tile
    @ViewBuilder let title: Title
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(spacing: 11) {
            tile
                .frame(width: 44, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    if dot {
                        Circle().fill(Paper.accent)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                            .offset(x: 3, y: -3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.system(size: 13))
                    .lineLimit(1)
                detail
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Paper.fog)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// 左边列表里选中的那一行：一块浅灰的圆角底（不用系统的深蓝；列表有没有键盘焦点都一样，不会先蓝后灰）。
struct SelectionPill: View {
    let selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Paper.accentSoft : .clear)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
    }
}

/// 把左边列表（系统的 NSTableView）自己画的选中底关掉，只留 SelectionPill。
struct SystemSelectionOff: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var node = superview
            while let current = node {
                if let table = current as? NSTableView {
                    table.selectionHighlightStyle = .none
                    return
                }
                node = current.superview
            }
        }

        /// 只是用来找列表的，点不到它。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// 改名的输入框：一出来就有光标、标题全选；回车确定，Esc 取消，点别处也算确定。
struct RenameField: NSViewRepresentable {
    let text: String
    let onDone: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeNSView(context: Context) -> Field {
        let field = Field(string: text)
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = Paper.nsInk
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.onDone = onDone
    }

    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 放进窗口以后再拿光标（列表还在排，马上拿会被抢走）
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
                self.currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onDone: (String?) -> Void
        var finished = false

        init(onDone: @escaping (String?) -> Void) {
            self.onDone = onDone
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Esc：不改了
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finish(nil)
                return true
            }
            return false
        }

        /// 回车、点别处：用输入框里的字。
        func controlTextDidEndEditing(_ notification: Notification) {
            finish((notification.object as? NSTextField)?.stringValue)
        }

        private func finish(_ value: String?) {
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async { self.onDone(value) }
        }
    }
}

/// 左边列表里幻灯片第一页的小图（高 54 像素，列表里显示 27 点）。按文件和修改时间缓存：重新导出了就重画。
@MainActor
enum SlideThumbnails {
    private static var cache: [String: NSImage] = [:]

    static func first(of url: URL) async -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)#\(modified)"
        if let hit = cache[key] { return hit }
        let image = await Task.detached { () -> NSImage? in
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            let box = page.bounds(for: .cropBox)
            let height: CGFloat = 54
            let width = (height * box.width / max(1, box.height)).rounded()
            return page.thumbnail(of: CGSize(width: width, height: height), for: .cropBox)
        }.value
        if let image { cache[key] = image }
        return image
    }
}

/// 列表里的「多少字 · 大约多久」。按文字缓存，不用每次重新拆。
enum ScriptStats {
    private static var cache: [UUID: (String, String)] = [:]

    static func of(_ document: ScriptDocument) -> String {
        if let hit = cache[document.id], hit.0 == document.text { return hit.1 }
        let script = Script(text: document.text, skipCuts: Preferences.shared.skipCuts)
        let speed = Preferences.shared.speed(for: script)
        let count = script.count
        let length = Prompter.clock(script.duration(perMinute: speed))
        let value = count == 0 ? String(localized: "Empty") :
            script.isCJK ? String(localized: "\(count) chars · \(length)") : String(localized: "\(count) words · \(length)")
        cache[document.id] = (document.text, value)
        return value
    }
}

// MARK: - 编辑器和播放

struct EditorPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prompter: Prompter
    @ObservedObject var prefs: Preferences

    var body: some View {
        ZStack(alignment: .bottom) {
            // 稿子配了幻灯片：分镜表（每页一行，左边幻灯片、右边这页的话）。
            // 还没配上（按页写的稿子、或者等着拖 PDF 进来）：上面一块幻灯片的地方，下面稿子，中间的线可以上下拖。
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    if model.presenting {
                        SlideShow(model: model, deck: model.deck, prompter: prompter)
                    } else if model.showsStoryboard {
                        Storyboard(model: model, deck: model.deck, prompter: prompter, prefs: prefs)
                    } else {
                        if model.showsStage {
                            SlideStage(deck: model.deck, model: model)
                                .frame(height: stageHeight(geometry.size.height))
                                .transition(.move(edge: .top).combined(with: .opacity))
                            StageDivider(prefs: prefs, total: geometry.size.height)
                        }
                        editor
                    }
                }
                .coachAnchor("script")
            }
            if let take = model.recorder.take, !prompter.isActive {
                TakeOverlay(recorder: model.recorder, url: take)
                    .shieldsTextCursor("take")
                    .id(take)
                    .transition(.opacity)
            }
            if !model.presenting {
                ControlBar(model: model, prompter: prompter, prefs: prefs)
                    .shieldsTextCursor("bar")
            }
            // 要录屏幕、还没有权限：说明一下，等权限
            if let step = model.screenPermission {
                ScreenPermissionCard(model: model, step: step)
                    .shieldsTextCursor("permission")
                    .transition(.opacity)
            }
            // 一句话提示：底栏上面一点，居中
            // 正在转幻灯片、上面那块已经在说「正在变成一页一页」的时候，就不再重复一遍
            if let notice = model.notice, !(notice.busy && model.showsStage) {
                NoticeBanner(notice: notice)
                    .padding(.bottom, 92)
                    .id(notice.id)
                    .transition(.offset(y: 8).combined(with: .opacity))
            }
        }
        .overlayPreferenceValue(CoachAnchors.self) { anchors in
            ZStack {
                if model.showingModes, let anchor = anchors["modes"] {
                    ModesOverlay(model: model, prompter: prompter, prefs: prefs, anchor: anchor)
                }
                if model.showingShots, let anchor = anchors["shot"] {
                    ShotsOverlay(model: model, prefs: prefs, anchor: anchor)
                }
                CoachMarks(model: model, anchors: anchors)
            }
        }
        .animation(.omoOut(0.3), value: model.notice)
        .animation(.omoOut(0.3), value: model.screenPermission)
        .animation(.omoOut(0.35), value: model.recorder.take)
        .animation(.omoOut(0.35), value: model.showsStage)
        .animation(.omoOut(0.3), value: model.showsStoryboard)
        .animation(.omoOut(0.4), value: model.presenting)
        .background(Paper.white)
    }

    @ViewBuilder private var editor: some View {
        if let document = model.document {
            ScriptEditor(
                text: Binding(get: { model.document?.text ?? "" }, set: { model.store.update(document.id, text: $0) }),
                documentID: document.id,
                editable: !model.promptingSelection,
                progress: model.progressOffset,
                startOffset: model.cursor,
                focus: model.focusRequest,
                pageMarks: model.pageMarks,
                zoom: prefs.zoom,
                onCursor: { model.setCursor($0) },
                onImport: { model.importFiles($0) },
                onPinch: { prefs.setZoom(prefs.zoom * (1 + $0)) })
        } else {
            EmptyLibrary(model: model)
        }
    }

    /// 幻灯片的高度：按拖出来的比例，但上下都留够地方（稿子至少 240 点高）。
    private func stageHeight(_ total: CGFloat) -> CGFloat {
        max(170, min(total * prefs.slideStage, total - 240))
    }
}

/// 一份讲稿都没有：一把摊开的文件卡片（讲稿、PDF、PowerPoint）——拖进来，或者点一下选文件；下面一个 + 新建空白的。
struct EmptyLibrary: View {
    @ObservedObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 22) {
            FileFan(spread: hovering || model.dragging != nil, kinds: FileFan.scripts)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture { model.openFiles() }
                .help(String(localized: "Open…"))
            Button { model.newScript() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Paper.charcoal)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.black.opacity(0.05)))
            }
            .buttonStyle(PressStyle())
            .help(String(localized: "New Script"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.white)
    }
}

struct ControlBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prompter: Prompter
    @ObservedObject var prefs: Preferences

    var body: some View {
        let active = prompter.isActive
        let mode = active ? prompter.activeMode : prefs.mode
        HStack(spacing: 6) {
                if let issue = prompter.permissionIssue {
                    PermissionNote(issue: issue)
                } else if prompter.slidesDenied {
                    SlidesNote()
                } else if model.shot != nil, let problem = model.recorder.problem {
                    CameraNote(problem: problem)
                }
                Spacer(minLength: 12)
                TimeLabel(model: model, prompter: prompter, prefs: prefs)
                    .padding(.trailing, 4)
                // 画面：录什么（人像 / 幻灯片 / 幻灯片 + 人像 / 不录制）、横屏还是竖屏。按播放直接照这里录
                ShotButton(model: model, prefs: prefs, disabled: active)
                    .coachAnchor("shot")
                    .padding(.trailing, 2)
                // 滚动方式：只放一个按钮（当前这种的图标），点开是四张带动画的卡片（见 ModePicker）；⌘1–4 直接换
                ModeButton(model: model, mode: mode)
                    .coachAnchor("modes")
                PlayButton(active: active, starting: model.starting, enabled: (active || model.canPlay) && !model.starting) { model.play() }
                    .coachAnchor("play")
                    .padding(.leading, 10)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
        .background(alignment: .bottom) {
            LinearGradient(colors: [Paper.white.opacity(0), Paper.white, Paper.white],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 96)
                .allowsHitTesting(false)
        }
        .animation(.omoOut(0.3), value: mode)
    }
}

/// 打开的滚动方式面板：浮在按钮上面（右边和播放键差不多对齐），点外面收起。
struct ModesOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prompter: Prompter
    @ObservedObject var prefs: Preferences
    let anchor: Anchor<CGRect>

    var body: some View {
        GeometryReader { geometry in
            let rect = geometry[anchor]
            let mode = prompter.isActive ? prompter.activeMode : prefs.mode
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .shieldsTextCursor("modes")
                ModePanel(mode: mode, options: ModeOptions.applies(mode) ? AnyView(ModeOptions(model: model, prompter: prompter, prefs: prefs, mode: mode)) : nil) { item in
                    withAnimation(.omoOut(0.3)) { prompter.setMode(item) }
                    // 换到还有选项的方式（速度、跟随语速）：面板留着，让人顺手调；别的就收起
                    if !ModeOptions.applies(item) { close() }
                }
                .frame(width: min(geometry.size.width - 8, max(rect.maxX + 44, 600)),
                       height: max(0, rect.minY - 10), alignment: .bottomTrailing)
                .transition(.scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
    }

    private func close() {
        withAnimation(.omoOut(0.22)) { model.showingModes = false }
    }
}

struct PlayButton: View {
    let active: Bool
    /// 摄像头正在打开：按钮先变成红色的录制点，开始录了提词条就出来。
    var starting = false
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(starting ? AnyShapeStyle(Color(rgb: 0xE5484D)) : enabled ? AnyShapeStyle(Paper.accentFill) : AnyShapeStyle(Paper.line))
                    .shadow(color: enabled && !starting ? Paper.accent.opacity(0.35) : .clear, radius: 8, y: 3)
                if starting {
                    Circle().fill(.white).frame(width: 12, height: 12)
                } else {
                    Image(systemName: active ? "stop.fill" : "play.fill")
                        .font(.system(size: active ? 13 : 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: active ? 0 : 1.5)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 46, height: 46)
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .keyboardShortcut(.return, modifiers: .command)
        .hoverTip(active ? String(localized: "Stop  ⌥Esc") : String(localized: "Start  ⌘↩"))
        .accessibilityLabel(active ? String(localized: "Stop") : String(localized: "Start"))
    }
}

/// 没开始：从光标处念完大约多久。提词中：已经念了多久。
struct TimeLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prompter: Prompter
    @ObservedObject var prefs: Preferences

    var body: some View {
        if prompter.isActive {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                HStack(spacing: 6) {
                    if model.recorder.isRecording {
                        Circle().fill(Color(rgb: 0xE5484D)).frame(width: 7, height: 7)
                    }
                    Text(Prompter.clock(prompter.elapsed))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(Paper.ink)
                }
            }
        } else if prefs.mode == .keywords, let document = model.document {
            // 关键词模式：一共几个关键词（写了时长的话，加上一共多久）
            let cues = Cues(text: document.text, skipCuts: prefs.skipCuts)
            if !cues.isEmpty {
                Text(cues.count == 1 ? (cues.timed > 0 ? String(localized: "1 keyword · \(Prompter.clock(cues.timed))") : String(localized: "1 keyword"))
                     : cues.timed > 0 ? String(localized: "\(cues.count) keywords · \(Prompter.clock(cues.timed))")
                     : String(localized: "\(cues.count) keywords"))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Paper.gray)
                    .hoverTip(cues.fromBold ? String(localized: "The bold words in this script") : String(localized: "One keyword per line"))
            }
        } else if model.document != nil {
            let script = model.currentScript
            let from = script.token(atRaw: model.cursor) >= script.count ? 0 : script.token(atRaw: model.cursor)
            if !script.isEmpty {
                Text("≈ \(Prompter.clock(script.duration(from: from, perMinute: prefs.speed(for: script))))")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Paper.gray)
                    .hoverTip(String(localized: "From the blue dot to the end, at your speed"))
            }
        }
    }
}

/// 滚动方式面板里卡片下面那一行：匀速是速度；说话时滚动是「跟随语速 / 固定速度」，固定的话再加速度。
struct ModeOptions: View {
    static func applies(_ mode: PromptMode) -> Bool { mode == .steady || mode == .pace }

    @ObservedObject var model: AppModel
    @ObservedObject var prompter: Prompter
    @ObservedObject var prefs: Preferences
    let mode: PromptMode

    var body: some View {
        HStack(spacing: 14) {
            if mode == .pace {
                PaceChoice(adaptive: Binding(get: { prefs.adaptivePace },
                                             set: { value in withAnimation(.omoOut(0.28)) { prompter.setAdaptivePace(value) } }))
            }
            if SpeedControl.applies(mode, prefs) {
                SpeedControl(model: model, prompter: prompter, prefs: prefs)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(.vertical, 2)
    }
}

/// 跟随语速 / 固定速度：一条小轨道，选中的那边一块白。
private struct PaceChoice: View {
    @Binding var adaptive: Bool
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            option(true, String(localized: "Match my pace"))
            option(false, String(localized: "Fixed speed"))
        }
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.05)))
    }

    private func option(_ value: Bool, _ label: String) -> some View {
        let selected = adaptive == value
        return Button {
            adaptive = value
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Paper.accentText : Paper.gray)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        Capsule().fill(.white)
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "pace", in: namespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SpeedControl: View {
    /// 这种方式用得上速度（匀速；说话时滚动且没跟着语速）。
    static func applies(_ mode: PromptMode, _ prefs: Preferences) -> Bool {
        mode == .steady || (mode == .pace && !prefs.adaptivePace)
    }

    @ObservedObject var model: AppModel
    @ObservedObject var prompter: Prompter
    @ObservedObject var prefs: Preferences

    var body: some View {
        let script = prompter.isActive ? prompter.script : model.currentScript
        let value = Int(prefs.speed(for: script))
        let unit = script.isCJK ? 20.0 : 10.0
        HStack(spacing: 0) {
            IconToggle(symbol: "minus", selected: false, help: String(localized: "Slower  ⌥↓")) {
                prefs.setSpeed(prefs.speed(for: script) - unit, for: script)
            }
            Text(script.isCJK ? String(localized: "\(value) chars/min") : String(localized: "\(value) wpm"))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Paper.charcoal)
                .frame(minWidth: 70)
            IconToggle(symbol: "plus", selected: false, help: String(localized: "Faster  ⌥↑")) {
                prefs.setSpeed(prefs.speed(for: script) + unit, for: script)
            }
        }
    }
}

/// 缺了某个权限：一个图标、几个字、一个「打开设置」（直接跳到系统设置里对应的那一页）。
struct SettingsNote: View {
    let symbol: String
    let text: String
    /// 系统设置「隐私与安全性」里哪一页；nil 就没有按钮（比如找不到摄像头）。
    var pane: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(rgb: 0xD0574F))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Paper.charcoal)
                .lineLimit(1)
            if let pane {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Open Settings")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Paper.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.06)))
                }
                .buttonStyle(PressStyle())
            }
        }
    }
}

/// 没让 Eyeline 控制 Keynote / PowerPoint：去系统设置的「自动化」里打开。
struct SlidesNote: View {
    var body: some View {
        SettingsNote(symbol: "rectangle.on.rectangle.slash", text: String(localized: "Keynote control is off"), pane: "Privacy_Automation")
    }
}

struct PermissionNote: View {
    let issue: Listener.State

    var body: some View {
        if issue == .micDenied {
            SettingsNote(symbol: "mic.slash", text: String(localized: "Microphone is off"), pane: "Privacy_Microphone")
        } else {
            SettingsNote(symbol: "waveform.slash", text: String(localized: "Speech recognition is off"), pane: "Privacy_SpeechRecognition")
        }
    }
}
