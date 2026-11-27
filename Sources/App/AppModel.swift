import AppKit
import SwiftUI
import Combine
import PDFKit
import AVFoundation
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 把稿子、编辑器和提词连在一起。
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// 稿子库。`-storeFolder /路径` 换一个文件夹（测试用，不碰你的稿子）。
    let store = ScriptStore(folder: UserDefaults.standard.string(forKey: "storeFolder").map { URL(fileURLWithPath: $0, isDirectory: true) })
    let prompter = Prompter()
    let prefs = Preferences.shared
    let recorder = TakeRecorder()
    /// 稿子配的幻灯片：主窗口里在稿子上面，翻页带着稿子走。
    let deck = SlideDeck()
    private let ribbon = RibbonController()

    @Published var selection: UUID? {
        didSet {
            guard selection != oldValue, document != nil else { return }
            // 打开一份稿子：光标和 ▶ 都在最上面，从头开始。上次停在哪不记着（记着反而让人摸不着头脑）；
            // 刚停下时 ▶ 会留在停下的那一句（见 prompter.onStop），想接着念就接着念。
            focus(textStart)
            loadDeck()
        }
    }
    /// 左边列表里选中的：一份稿子，或者一条录好的视频（在右边回放）。点稿子（哪怕就是选着的那份）就关掉回放。
    enum SidebarItem: Hashable {
        case script(UUID)
        case take(URL)
    }

    var sidebarSelection: SidebarItem? {
        get {
            if let take = recorder.take { return .take(take) }
            return selection.map { .script($0) }
        }
        set {
            switch newValue {
            case .script(let id):
                if recorder.take != nil { recorder.dismiss() }
                selection = id
            case .take(let url):
                recorder.show(url)
            case nil:
                break
            }
        }
    }

    /// 侧栏里正在改名的那份讲稿。
    @Published var renaming: UUID?

    /// 改名：nil 是取消；空的就不要名字了（标题回到用第一行）。能撤销。
    func rename(_ id: UUID, to name: String?, undoManager: UndoManager? = nil) {
        defer { renaming = nil }
        guard let name, let old = store[id]?.name ?? Optional.some(nil) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let new: String? = trimmed.isEmpty ? nil : trimmed
        guard new != old else { return }
        setName(id, new, was: old, undoManager: undoManager)
    }

    private func setName(_ id: UUID, _ name: String?, was old: String?, undoManager: UndoManager?) {
        store.modify(id) { $0.name = name }
        undoManager?.registerUndo(withTarget: self) { model in model.setName(id, old, was: name, undoManager: undoManager) }
        undoManager?.setActionName(String(localized: "Rename"))
    }

    /// 不要这份幻灯片了：台词留着（还是一页一段），上面回到「把幻灯片拖进来」。能撤销。
    func removeSlides(_ id: UUID, undoManager: UndoManager?) {
        guard let old = store[id]?.slides else { return }
        if prompter.documentID == id { prompter.stop() }
        store.modify(id) { $0.slides = nil }
        if selection == id { deck.unload() }
        announce(String(localized: "Slides removed · ⌘Z to undo"))
        undoManager?.registerUndo(withTarget: self) { model in
            model.store.modify(id) { $0.slides = old }
            if model.selection == id { model.loadDeck() }
        }
        undoManager?.setActionName(String(localized: "Remove Slides"))
    }

    /// 录好的视频移到废纸篓：说一声。
    /// 删一条录像。正在看的就是它：接着看它旁边的那条（下面一条，没有就上面一条），不跳回讲稿。
    func trashTake(_ url: URL) {
        let takes = recorder.takes.map(\.url)
        var neighbour: URL?
        if recorder.take == url, let index = takes.firstIndex(of: url) {
            neighbour = index + 1 < takes.count ? takes[index + 1] : (index > 0 ? takes[index - 1] : nil)
        }
        let wasShown = recorder.take == url
        let undoManager = mainWindow?.undoManager
        recorder.trash(url) { [weak self] trashed in
            guard let self else { return }
            // 找回来：⌘Z（列表里）和提示上的「撤销」都走这里，和删讲稿一样；已经找回来了就不再来一遍
            var restored = false
            let restore: () -> Void = { [weak self] in
                guard let self, !restored else { return }
                restored = true
                guard self.recorder.restore(trashed, to: url) else { return }
                self.notice = nil
                if wasShown { self.recorder.show(url) }
            }
            undoManager?.registerUndo(withTarget: self) { _ in restore() }
            undoManager?.setActionName(String(localized: "Move to Trash"))
            self.announce(String(localized: "Moved to the Trash"), action: NoticeAction(title: String(localized: "Undo"), run: restore))
        }
        if let neighbour { recorder.show(neighbour) }
    }

    /// 剪头去尾：留下 start…end 这一段（不重新编码，几乎一下就好），换掉原来那条（文件名、排的位置不变）。
    /// 原来的进废纸篓：⌘Z（列表里）和提示上的「撤销」把它拿回来。
    func trimTake(_ url: URL, from start: Double, to end: Double) {
        guard end - start >= Playback.shortestTrim,
              let export = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetPassthrough) else { return }
        // 先写到同一个文件夹里的隐藏文件（列表里看不见），好了再换上去
        let temp = url.deletingLastPathComponent().appendingPathComponent(".trimming-\(UUID().uuidString).\(url.pathExtension)")
        export.outputURL = temp
        export.outputFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        let undoManager = mainWindow?.undoManager
        announce(String(localized: "Trimming…"), busy: true)
        export.exportAsynchronously { [weak self] in
            let done = export.status == .completed
            let error = export.error?.localizedDescription
            DispatchQueue.main.async {
                guard let self else { return }
                guard done else {
                    try? FileManager.default.removeItem(at: temp)
                    Log.info("trim failed: \(error ?? "?")")
                    self.announce(String(localized: "Couldn’t trim the take"), problem: true)
                    return
                }
                // 新文件记原来的录制时间：在列表里还排在原处
                if let created { try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: temp.path) }
                self.recorder.trash(url) { [weak self] original in
                    guard let self else { return }
                    do {
                        try FileManager.default.moveItem(at: temp, to: url)
                    } catch {
                        self.recorder.restore(original, to: url)
                        try? FileManager.default.removeItem(at: temp)
                        self.announce(String(localized: "Couldn’t trim the take"), problem: true)
                        return
                    }
                    TakeRow.forget(url)
                    self.recorder.refreshTakes()
                    self.recorder.markSeen(url)
                    self.recorder.show(url)
                    var undone = false
                    let undo: () -> Void = { [weak self] in
                        guard let self, !undone else { return }
                        undone = true
                        self.recorder.trash(url) { [weak self] _ in
                            guard let self else { return }
                            TakeRow.forget(url)
                            if self.recorder.restore(original, to: url) { self.recorder.show(url) }
                            self.notice = nil
                        }
                    }
                    undoManager?.registerUndo(withTarget: self) { _ in undo() }
                    undoManager?.setActionName(String(localized: "Trim"))
                    self.announce(String(localized: "Trimmed · the original is in the Trash"),
                                  action: NoticeAction(title: String(localized: "Undo"), run: undo))
                }
            }
        }
    }

    /// 设置、快捷键：在主窗口里浮起来的一块玻璃（不另开窗口）。
    enum Sheet: Equatable { case settings, shortcuts }
    @Published var sheet: Sheet? { didSet { if sheet != nil { showingModes = false; showingShots = false } } }

    func show(_ sheet: Sheet) {
        openMainWindow?()
        withAnimation(.omoOut(0.3)) { self.sheet = sheet }
    }

    /// 滚动方式的面板开着（底栏上那个按钮点开的）。
    @Published var showingModes = false { didSet { if showingModes { showingShots = false } } }
    /// 「画面」面板开着（录什么、横屏还是竖屏）。
    @Published var showingShots = false { didSet { if showingShots { showingModes = false } } }

    // MARK: 录什么

    /// 按播放会录什么：nil 是不录制。底栏「画面」里改，会记住。
    var shot: RecordLayout? { prefs.recordTakes ? prefs.recordLayout : nil }

    func setShot(_ layout: RecordLayout?) {
        guard let layout else {
            prefs.recordTakes = false
            return
        }
        prefs.recordTakes = true
        prefs.recordLayout = layout
    }

    /// 录屏幕、有幻灯片：按了播放，先把窗口变成幻灯片（录的就是这一块），然后才开始录、出提词条。
    @Published private(set) var preparingShow = false

    // MARK: 录屏前的倒数

    /// 正在倒数（录屏幕之前，见 CountdownPanel）：这时可以挪人像，空格马上开始，Esc 不录了。
    @Published private(set) var staging = false
    private let countdown = CountdownPanel()
    /// 录的那一块四周的框（倒数时显示，开始录时闪一下淡掉）。
    private let recordingFrame = RecordingFrame()
    /// 录整块屏幕时先把 Eyeline 的窗口最小化到 Dock，让你看见真正在录的东西；录完、不录了再拿出来。
    private var hiddenWindow: NSWindow?

    private func bringBackWindow() {
        guard let window = hiddenWindow else { return }
        hiddenWindow = nil
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.bringToFront()
    }
    private var countdownWork: DispatchWorkItem?
    /// 倒数完要做的：真的开始录。
    private var afterCountdown: (() -> Void)?

    private func startCountdown(in region: CGRect, on screen: NSScreen, then start: @escaping () -> Void) {
        afterCountdown = start
        staging = true
        recordingFrame.show(region: region, on: screen)
        countdown.show(in: region)
        restartCountdown()
    }

    /// 从 3 开始倒数（刚开始、挪完人像）。
    private func restartCountdown() {
        guard staging else { return }
        countdownWork?.cancel()
        countdown.restart()
        prompter.hold(until: CACurrentMediaTime() + countdown.state.length)
        let work = DispatchWorkItem { [weak self] in self?.finishCountdown() }
        countdownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + countdown.state.length, execute: work)
    }

    /// 有人在挪人像：先停。
    private func pauseCountdown() {
        guard staging else { return }
        countdownWork?.cancel()
        countdown.pause()
        prompter.hold(until: nil)
    }

    /// 倒数完（或者按了空格）：开始录。
    func finishCountdown() {
        guard staging else { return }
        countdownWork?.cancel()
        countdown.hide()
        recordingFrame.recording()
        staging = false
        let start = afterCountdown
        afterCountdown = nil
        start?()
    }

    /// 不录了（Esc）：人像收起，镜头关掉，窗口还原。
    func cancelCountdown() {
        guard staging else { return }
        countdownWork?.cancel()
        countdown.hide()
        recordingFrame.hide()
        staging = false
        afterCountdown = nil
        recorder.cancelPreparation()
        starting = false
        preparingShow = false
        if prompter.held { prompter.stop() }
        restoreWindowAfterShow()
        bringBackWindow()
    }

    // MARK: 屏幕录制权限

    /// 要录屏幕、还没有权限：窗口里的卡片（见 ScreenPermission）。ask：说明一下；waiting：已经打开了系统设置，等权限。
    enum ScreenPermissionStep: Equatable {
        case ask
        case waiting(since: Date)
    }
    @Published private(set) var screenPermission: ScreenPermissionStep?
    private let permissionHelper = PermissionHelper()
    private var permissionTimer: Timer?

    /// 跳到系统设置「屏幕与系统录音」，旁边浮一张可以拖图标的小卡片；每秒看一次权限给了没有。
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        screenPermission = .waiting(since: Date())
        // 系统让重新打开 Eyeline 的话：打开后告诉一声
        UserDefaults.standard.set(true, forKey: "screenPermissionPending")
        permissionHelper.show()
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, ScreenCapture.allowed else { return }
            self.screenPermissionGranted()
        }
    }

    /// 不录了（卡片上的「以后再说」）。
    func dismissScreenPermission() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        permissionHelper.close()
        UserDefaults.standard.removeObject(forKey: "screenPermissionPending")
        withAnimation(.omoOut(0.25)) { screenPermission = nil }
    }

    /// 权限给了：卡片收起，回到 Eyeline，接着开始录。
    private func screenPermissionGranted() {
        dismissScreenPermission()
        openMainWindow?()
        NSApp.bringToFront()
        announce(String(localized: "Screen recording is allowed"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.play() }
    }

    /// 开关打开了、权限还没生效：重新打开 Eyeline。
    func reopenForScreenPermission() {
        UserDefaults.standard.set(true, forKey: "screenPermissionPending")
        AppLanguage.relaunch()
    }

    /// 录这一块屏幕：原样的画面，比例和像素跟着这一块走。
    private func composition(_ shot: RecordLayout, region: CGRect, screen: NSScreen) -> Composition {
        Composition(layout: shot, contentAspect: region.width / max(1, region.height), backdrop: .none,
                    pixelWidth: region.width * screen.backingScaleFactor)
    }

    /// 录哪块屏幕、圆框人像放哪。Eyeline 自己的窗口不录（除了 keeping 里的），提词条也就不会进画面。
    private func screenShot(_ shot: RecordLayout, region: CGRect, screen: NSScreen, keeping: [NSWindow]) -> TakeRecorder.ScreenShot {
        TakeRecorder.ScreenShot(region: region, screen: screen,
                                bubble: shot.needsCamera ? (center: CGPoint(x: prefs.bubbleX, y: prefs.bubbleY), size: CGFloat(prefs.bubbleSize)) : nil,
                                hideOwnWindows: true, keeping: keeping,
                                // 设置里关了「录屏时隐藏」：提词条也录进去（做演示时要看见它）
                                alsoKeeping: { [weak self] in
                                    guard let self, !self.prefs.hideFromCapture else { return [] }
                                    return self.ribbon.windows
                                })
    }

    /// 三步上手现在在第几步（nil：没在看）。第一次打开时自动出来，菜单「帮助 › 快速上手」再看一遍。
    @Published var coachStep: Int?
    /// 从 dmg / 「下载」里直接打开的：窗口里问一下要不要搬进「应用程序」。
    @Published var offerMove = false

    func moveToApplications() {
        if !Installer.moveAndRelaunch() {
            withAnimation(.omoOut(0.25)) { offerMove = false }
            announce(String(localized: "Couldn’t move Eyeline — drag it into Applications"), problem: true)
        }
    }

    func declineMove() {
        Installer.decline()
        withAnimation(.omoOut(0.25)) { offerMove = false }
    }
    /// 这一步要指的东西在窗口里的位置（右边那一栏量好了报上来）。
    @Published var coachHole: CGRect?

    func startQuickStart() { coachStep = 0 }

    func nextCoachStep() {
        if let step = coachStep, step + 1 < CoachMarks.steps.count {
            coachStep = step + 1
        } else {
            endQuickStart()
        }
    }

    func endQuickStart() {
        coachStep = nil
        coachHole = nil
        UserDefaults.standard.set(true, forKey: "quickStartDone")
    }

    /// 编辑器的光标（原文位置）。播放从这里开始。
    @Published private(set) var cursor = 0
    /// 按了播放、摄像头正在打开（开始录了才出提词条）。
    @Published private(set) var starting = false
    /// 正在把 .pptx / .key 变成一页一页的图。
    @Published private(set) var convertingSlides = false

    /// 正在往窗口里拖文件：松开会怎样（窗口上的提示用）。
    enum Drag: Equatable {
        case files(Int)
        case slides
        case attach(String)
    }
    @Published private(set) var dragging: Drag?

    /// 窗口上方的一句话。busy：转圈，直到下一句；problem：出错了。
    struct Notice: Equatable {
        var text: String
        var busy = false
        var problem = false
        /// 句子后面一个可以点的字（比如「按空行分成 3 页」）。
        var action: NoticeAction?
        var id = UUID()
        static func == (a: Notice, b: Notice) -> Bool {
            a.id == b.id && a.text == b.text && a.busy == b.busy && a.problem == b.problem && a.action?.title == b.action?.title
        }
    }
    struct NoticeAction {
        let title: String
        let run: () -> Void
    }
    @Published private(set) var notice: Notice?
    /// 让编辑器把光标挪到某处（top：把那一行滚到最上面）。
    @Published private(set) var focusRequest: (offset: Int, serial: Int, top: Bool)?
    private var focusSerial = 0
    private var keyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    var openMainWindow: (() -> Void)?

    private init() {
        prompter.ribbon = ribbon
        prompter.deck = deck
        deck.onPage = { [weak self] number in self?.deckFlipped(to: number) }
        prompter.onStop = { [weak self] id, offset in
            guard let self else { return }
            // 倒数的时候提词条被停了（⌥Esc、提词条上的停止）：不录了
            if self.staging { self.cancelCountdown() }
            self.recorder.stopRecording()
            // 收起来的窗口：录好了会跟着回放出来；没录成的话这里拿回来
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.bringBackWindow() }
            self.store.setResume(id, offset)
            guard id == self.selection else { return }
            self.focus(offset)
            // 分镜表：光标放进停下时那一页（不然还留在之前那一行，幻灯片会被它翻回去）
            if self.showsStoryboard { self.requestPageFocus(self.deck.page, atEnd: true) }
        }
        selection = store.documents.first?.id
        if document != nil { focus(textStart) }
        loadDeck()
        // 换了界面语言、自己重新打开的：把设置再打开，接着看
        if UserDefaults.standard.bool(forKey: "reopenSettings") {
            UserDefaults.standard.removeObject(forKey: "reopenSettings")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.show(.settings) }
        }
        // 为了屏幕录制权限重新打开的：告诉一声可以录了
        if UserDefaults.standard.bool(forKey: "screenPermissionPending") {
            UserDefaults.standard.removeObject(forKey: "screenPermissionPending")
            if ScreenCapture.allowed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.announce(String(localized: "Screen recording is allowed · press ⌘↩ to start"))
                }
            }
        }
        // 第一次打开：三步上手（测试用的单独稿子库里不出来）
        // `-coachStep 1`：直接停在三步上手的某一步（截图看样子用）
        if UserDefaults.standard.object(forKey: "coachStep") != nil {
            let step = UserDefaults.standard.integer(forKey: "coachStep")
            Log.info("coach test: step \(step)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.coachStep = step }
            if let shot = UserDefaults.standard.string(forKey: "coachShot") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.shootWindow(to: URL(fileURLWithPath: shot)) }
            }
        }
        // 不在「应用程序」里、而且现在哪里都搜不到它（直接从 dmg 里打开的）：问一下要不要搬过去。
        // 不用问的话，第一次打开就是三步上手。
        Installer.decideOffer { [weak self] offer in
            guard let self else { return }
            if offer {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation(.omoOut(0.3)) { self.offerMove = true }
                }
                if let shot = UserDefaults.standard.string(forKey: "moveShot") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.shootWindow(to: URL(fileURLWithPath: shot)) }
                }
            } else if !UserDefaults.standard.bool(forKey: "quickStartDone"), UserDefaults.standard.string(forKey: "storeFolder") == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self.startQuickStart() }
            }
        }
        // 放幻灯片放到一半退出：先把窗口还原，下次打开还是原来的大小
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.restoreWindowAfterShow() }
        }
        // 打开时窗口不对劲就摆回正常大小：以前的版本放幻灯片会进全屏（放到一半退出，系统会按全屏恢复出来）；
        // 记下来的大小太小（比如放幻灯片时的大小）会把侧栏和底栏挤坏
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.prompter.isActive, let window = self.mainWindow else { return }
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                Log.info("slides: opened in full screen, back to a window")
            } else if window.frame.width < AppModel.detailMinWidth + 220 || window.frame.height < 440 {
                window.setFrame(self.normalFrame(for: window), display: true, animate: false)
                Log.info("window: opened too small, back to \(Int(window.frame.width))x\(Int(window.frame.height))")
            }
        }

        // 提词时、Eyeline 在最前面：不用按 ⌥ 也能控制。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 设置、快捷键开着：Esc 收起
            if let self, self.sheet != nil, event.keyCode == 53 {
                withAnimation(.omoOut(0.22)) { self.sheet = nil }
                return nil
            }
            // 滚动方式、画面面板开着：Esc 收起
            if let self, self.showingModes || self.showingShots, event.keyCode == 53 {
                withAnimation(.omoOut(0.22)) {
                    self.showingModes = false
                    self.showingShots = false
                }
                return nil
            }
            // 录屏前的倒数：Esc 不录了，空格 / 回车马上开始
            if let self, self.staging {
                switch Int(event.keyCode) {
                case 53: self.cancelCountdown(); return nil
                case 49, 36, 76: self.finishCountdown(); return nil
                default: return event
                }
            }
            // 三步上手：Esc 跳过，别的键下一步
            if let self, self.coachStep != nil {
                if event.keyCode == 53 { self.endQuickStart() } else { self.nextCoachStep() }
                return nil
            }
            // 左边列表里：⌘⌫ 才删；光按 ⌫ 只提示一下怎么删
            if let self, event.keyCode == 51, NSApp.keyWindow?.firstResponder is NSTableView, self.sidebarSelection != nil {
                let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if flags == .command { self.deleteSidebarSelection(); return nil }
                if flags.isEmpty { self.announce(String(localized: "Press ⌘⌫ to delete")); return nil }
            }
            guard let self, self.prompter.isActive else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard modifiers.isEmpty else { return event }
            switch Int(event.keyCode) {
            case 49: self.prompter.perform(.pause)
            // ← →：稿子配了幻灯片就翻一页（稿子跟着到那一页），没配就退 / 进一行。⌥← ⌥→ 一直是一行。
            case 123, 116: self.prompter.perform(.clickerBack)
            case 124, 121: self.prompter.perform(.clickerForward)
            case 126: self.prompter.perform(.faster)
            case 125: self.prompter.perform(.slower)
            case 53: self.prompter.perform(.stop)
            default: return event
            }
            return nil
        }

        // 试听模式（开发用）：不开摄像头、不自动开始。
        guard !ProcessInfo.processInfo.arguments.contains("--probe") else { return }

        // 录好一条：把窗口叫到前面，马上回放这一条。
        recorder.onFinished = { [weak self] _ in
            guard let self else { return }
            if let window = self.hiddenWindow ?? self.mainWindow, window.isMiniaturized { window.deminiaturize(nil) }
            self.hiddenWindow = nil
            self.openMainWindow?()
            NSApp.bringToFront()
        }
        // 倒数的时候按空格（⌥空格）：马上开始
        prompter.onStartNow = { [weak self] in self?.finishCountdown() }
        // 圆框人像拖完、改完大小：记下来，下次还在这里；倒数的时候从 3 重新开始
        recorder.bubble.onChange = { [weak self] center, size in
            guard let self else { return }
            self.prefs.bubbleX = center.x
            self.prefs.bubbleY = center.y
            self.prefs.bubbleSize = size
            self.restartCountdown()
        }
        // 一抓人像，倒数先停
        recorder.bubble.onGrab = { [weak self] in self?.pauseCountdown() }
        // 摄像头：只在录的时候开（按播放才开，结束就关）。打开开关时先把权限问好。
        prefs.$recordTakes
            .removeDuplicates()
            .sink { [weak self] on in
                guard let self else { return }
                if on { self.recorder.prepare() } else if !self.prompter.isActive { self.recorder.close() }
            }
            .store(in: &cancellables)
        prompter.$phase
            .map { $0 != .idle }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] active in self?.presentationChanged(active: active) }
            .store(in: &cancellables)
        deck.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 回到 Eyeline：幻灯片可能刚重新导出过（同一个文件），重新读一下；没改过就什么也不做。
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, let url = self.deck.url, !self.promptingSelection else { return }
                self.deck.load(url, at: self.deck.page)
                if let id = self.selection { self.followMovedPage(self.syncSlides(id)) }
            }
            .store(in: &cancellables)
        recorder.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // 编辑器跟着提词的进度走。
        prompter.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        autostartForTesting()
    }

    var document: ScriptDocument? { store[selection] }

    /// 正在提词的是不是这一份。
    var promptingSelection: Bool { prompter.isActive && prompter.documentID == selection }

    /// 提词时编辑器里念到的原文位置。
    var progressOffset: Int? {
        guard promptingSelection else { return nil }
        return prompter.documentOffset(ofToken: prompter.spoken)
    }

    /// 提词时第 page 页的话念到了哪里（这一页里的位置）；没在提词、还没念到是 nil。
    func pageProgress(_ page: Int) -> Int? {
        progressOffset.flatMap { paged.local(of: $0, page: page) }
    }

    func setCursor(_ offset: Int) {
        guard !promptingSelection, cursor != offset else { return }
        cursor = offset
        // 在稿子里点到哪一页的稿子，幻灯片就翻到哪一页。
        if deck.isLoaded, let page = page(at: offset) { deck.go(to: page) }
    }

    func focus(_ offset: Int, top: Bool = false) {
        focusSerial += 1
        cursor = offset
        focusRequest = (offset, focusSerial, top)
    }

    // MARK: 播放

    func play(fromBeginning: Bool = false) {
        // 倒数的时候再按一下：马上开始
        if staging {
            finishCountdown()
            return
        }
        if prompter.isActive {
            prompter.stop()
            return
        }
        guard let document, !starting else { return }
        // 第一次播放：这一次要用到的权限（摄像头、麦克风、语音识别）先一个接一个问完，再摆提词条、倒数，
        // 不然倒数完、录上了才一下子蹦出一串系统对话框。要录屏幕又还没给屏幕权限的，先走下面那张屏幕权限的卡片。
        let records = shot != nil && canPlay
        if !(records && (shot?.needsScreen ?? false) && !ScreenCapture.allowed) {
            let mode = prefs.mode
            let camera = records && (shot?.needsCamera ?? false) && !UserDefaults.standard.bool(forKey: "fakeCamera")
            let microphone = records || mode == .follow || mode == .pace
            let speech = mode == .follow || (mode == .pace && prefs.adaptivePace)
            if Permissions.unasked(camera: camera, microphone: microphone, speech: speech) {
                starting = true
                Permissions.ask(camera: camera, microphone: microphone, speech: speech) { [weak self] in
                    guard let self else { return }
                    self.starting = false
                    self.play(fromBeginning: fromBeginning)
                }
                return
            }
        }
        recorder.dismiss()
        var offset = fromBeginning ? 0 : playStart
        // 配了幻灯片：光标停在某一页的话末尾（刚导入、刚粘贴完、点进那一行时都会这样），这一页就没得念了，
        // 一开始就停在页末等翻页。这时从这一页开头念。停在一页中间（上次念到这里）照旧接着念。
        if showsStoryboard, !fromBeginning {
            let page = paged.number(at: offset)
            let start = paged.start(ofPage: page)
            let length = (paged.text(ofPage: page) as NSString).length
            if length > 0, offset >= start + length { offset = start }
        }
        guard let shot, canPlay else {
            prompter.start(document, fromRaw: offset)
            return
        }
        // 要录屏幕、还没有权限：先不开始，等权限给了再录
        if shot.needsScreen, !ScreenCapture.allowed {
            withAnimation(.omoOut(0.3)) { screenPermission = .ask }
            return
        }
        // 先开摄像头、开始录，录上了再出提词条：第一句不会漏。
        starting = true
        let begin = { [weak self] (composition: Composition?, screenShot: TakeRecorder.ScreenShot?) in
            guard let self else { return }
            self.recorder.startRecording(title: document.title, composition: composition, shot: screenShot) { [weak self] in
                guard let self, self.starting else { return }
                self.starting = false
                // 录屏幕的话刚才已经倒数过了，提词不再倒数
                // 录屏幕被系统拒绝了：不开始，出权限的卡片
                if self.recorder.problem == .screenDenied {
                    self.preparingShow = false
                    if self.prompter.held { self.prompter.stop() }
                    self.restoreWindowAfterShow()
                    self.bringBackWindow()
                    withAnimation(.omoOut(0.3)) { self.screenPermission = .ask }
                    return
                }
                // 倒数时提词条已经摆出来了：现在开始走
                if self.prompter.held {
                    self.prompter.release()
                } else {
                    self.prompter.start(document, fromRaw: offset)
                }
                self.preparingShow = false
                if !self.prompter.isActive {
                    self.recorder.stopRecording()
                    self.restoreWindowAfterShow()
                }
            }
        }
        guard shot.needsScreen else { return begin(nil, nil) }
        // 录屏幕：有幻灯片就先把窗口变成幻灯片，录的就是这一块；没有就录提词条那块屏幕（Eyeline 自己的窗口不录）。
        // 先摆好、人像先放上去，倒数 3 秒（可以挪人像）再真的开始录
        let stage = { [weak self] (region: CGRect, screen: NSScreen, keeping: [NSWindow]) in
            guard let self else { return }
            let composition = self.composition(shot, region: region, screen: screen)
            let screenShot = self.screenShot(shot, region: region, screen: screen, keeping: keeping)
            self.recorder.prepare(composition, shot: screenShot)
            // 提词条先出来、停在第一句（数字在它左边），倒数完才走
            self.prompter.start(document, fromRaw: offset, held: true)
            self.startCountdown(in: region, on: screen) { begin(composition, screenShot) }
        }
        if showsStoryboard, let window = mainWindow {
            if deck.isLoaded, let page = page(at: offset) { deck.go(to: page) }
            preparingShow = true
            enterPresentation(window)
            // 等窗口摆好（有动画）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.starting else { return }
                let screen = window.screen ?? RibbonGeometry.screen(for: self.prefs.display)
                // 默认录整块屏幕（幻灯片四周是白的）；设了「只录幻灯片」就只录那一块
                stage(self.prefs.recordSlideOnly ? self.presentedSlide(on: screen) : screen.frame, screen, [window])
            }
        } else {
            let screen = RibbonGeometry.screen(for: prefs.display)
            // 录整块屏幕：先把 Eyeline 的窗口最小化到 Dock，让你看见真正在录的东西。
            // 录的时候从 Dock 点回来，窗口照样录得进去（keeping）；不录的只有提词条、它的按钮、倒数这些。
            if let window = mainWindow {
                hiddenWindow = window
                window.miniaturize(nil)
                stage(screen.frame, screen, [window])
            } else {
                stage(screen.frame, screen, [])
            }
        }
    }

    var canPlay: Bool { !currentScript.isEmpty }

    /// 按播放从原文哪里开始：光标所在那一句的开头，不从半句话开始。编辑器左边的 ▶ 标在这里。
    /// 从第一句开始就是「从头开始」：▶ 标在第一行字上（哪怕是不念的 # 标题；开头的空行跳过），
    /// 不会一会儿在标题那行、一会儿在正文第一行。
    var playStart: Int {
        let top = textStart
        guard cursor > top else { return top }
        let script = currentScript
        var token = script.token(atRaw: cursor)
        // 光标在一行字的末尾（或者这一行字后面的空白里）：算这一行，不是下一行。
        // 不然在上面新加一行、光标停在行尾，▶ 就跳到下面那行去了。
        if token > 0, token <= script.count {
            let previous = script.tokens[token - 1].raw
            let end = previous.location + previous.length
            let text = script.text as NSString
            if cursor >= end, cursor <= text.length,
               !text.substring(with: NSRange(location: end, length: cursor - end)).contains(where: \.isNewline) {
                token -= 1
            }
        }
        guard token < script.count, !script.sentences.isEmpty else { return top }
        let first = script.sentences[script.sentence(ofToken: token)].firstToken
        return first == 0 ? top : script.rawOffset(ofToken: first)
    }

    /// 稿子里第一个字（开头的空行不算）：「从头开始」时 ▶ 和光标都在这一行，不停在空行上。
    var textStart: Int {
        let text = (document?.text ?? "") as NSString
        let first = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
        return first.location == NSNotFound ? 0 : first.location
    }

    private var parsed: (text: String, skipCuts: Bool, script: Script)?

    /// 当前这份稿子拆好的样子（文字没变就不重新拆）。
    var currentScript: Script {
        let text = document?.text ?? ""
        if let parsed, parsed.text == text, parsed.skipCuts == prefs.skipCuts { return parsed.script }
        let script = Script(text: text, skipCuts: prefs.skipCuts)
        parsed = (text, prefs.skipCuts, script)
        return script
    }

    // MARK: 稿子

    func newScript(text: String = "") {
        let document = store.add(text: text)
        selection = document.id
        // 新建的：光标直接放进稿子里，马上能打字
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let window = self?.mainWindow, let editor = window.contentView?.firstDescendant(of: PaperTextView.self) else { return }
            window.makeFirstResponder(editor)
        }
    }

    func delete(_ id: UUID, undoManager: UndoManager?) {
        guard let index = store.documents.firstIndex(where: { $0.id == id }) else { return }
        if prompter.documentID == id { prompter.stop() }
        let document = store.documents[index]
        store.remove(id)
        if selection == id { selection = store.documents[safe: index]?.id ?? store.documents.last?.id }
        // 找回来：⌘Z（列表里）和提示上的「撤销」都走这里；已经找回来了就不再加一遍
        let restore: () -> Void = { [weak self] in
            guard let self, self.store[document.id] == nil else { return }
            self.store.restore(document, at: index)
            self.selection = document.id
            self.notice = nil
        }
        undoManager?.registerUndo(withTarget: self) { _ in restore() }
        undoManager?.setActionName(String(localized: "Delete Script"))
        let title = document.title.isEmpty ? String(localized: "Untitled") : document.title
        announce(String(localized: "Deleted “\(title)”"), action: NoticeAction(title: String(localized: "Undo"), run: restore))
    }

    /// 左边列表里选中的那一项删掉（⌘⌫）。
    func deleteSidebarSelection() {
        switch sidebarSelection {
        case .script(let id): delete(id, undoManager: mainWindow?.undoManager)
        case .take(let url): trashTake(url)
        case nil: break
        }
    }

    func duplicate(_ id: UUID) {
        if let copy = store.duplicate(id) { selection = copy.id }
    }

    /// 拖进来的 .txt / .md：当前这份是空的就填进去，否则每个文件一份新稿子。
    /// .pdf / .pptx / .key：一份一页一段的新稿子（有演讲者备注就放进去，见 SlideImport），并配上幻灯片。
    /// 一份幻灯片拖到分了页、还没配幻灯片的稿子上：配给这份稿子。
    func importFiles(_ urls: [URL]) {
        if urls.count == 1, let url = urls.first, SlideImport.handles(url), let document, document.slides == nil,
           document.isPaged || !currentScript.pages.isEmpty {
            attachSlides(url)
            return
        }
        var first = true
        for url in urls {
            defer { first = false }
            let blank = first && (document.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.slides == nil } ?? false)
            if url.pathExtension.lowercased() == "key", !SlideImport.keynoteInstalled {
                keynoteNeeded()
                continue
            }
            if SlideImport.handles(url) {
                let imported: SlideImport.Imported
                do {
                    imported = try SlideImport.script(from: url)
                } catch {
                    importProblem(error)
                    continue
                }
                if blank, let id = selection {
                    store.update(id, text: imported.text)
                    store.modify(id) { $0.name = imported.name; $0.byPage = true }
                    focus(0)
                } else {
                    selection = store.add(text: imported.text, name: imported.name, byPage: true).id
                }
                guard let id = selection else { continue }
                if url.pathExtension.lowercased() == "pdf" {
                    attachPDF(url, to: id, imported: true)
                } else if SlideImport.isPowerPoint(url) || SlideImport.keynoteInstalled {
                    convertSlides(url, for: id, imported: true)
                } else {
                    announce(String(localized: "Imported “\(imported.name)”"))
                }
            } else {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    announce(String(localized: "Can’t open “\(url.lastPathComponent)”"), problem: true)
                    continue
                }
                if blank, let id = selection {
                    store.update(id, text: text)
                    focus(0)
                } else {
                    newScript(text: text)
                }
                announce(String(localized: "Imported “\(document?.title ?? url.deletingPathExtension().lastPathComponent)”"))
            }
        }
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .pdf] + ["md", "pptx", "ppt", "key"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    /// Keynote 里开着的那份：每页的演讲者备注变成一份按页的稿子。
    func importFromKeynote() {
        do {
            let imported = try SlideImport.keynoteFront()
            let id = store.add(text: imported.text, name: imported.name, byPage: true).id
            selection = id
            focus(0)
            convertSlides(nil, for: id, imported: true)
        } catch {
            importProblem(error)
        }
    }

    private func importProblem(_ error: Error) {
        let alert = NSAlert()
        switch error as? SlideImport.Failure {
        case .keynoteNotOpen:
            alert.messageText = String(localized: "Open a presentation in Keynote first")
        case .notAllowed:
            alert.messageText = String(localized: "Allow Eyeline to control Keynote")
            alert.informativeText = String(localized: "System Settings › Privacy & Security › Automation")
        default:
            alert.messageText = String(localized: "Couldn’t read this file")
        }
        alert.runModal()
    }

    // MARK: 拖进来、提示

    func dragEntered(count: Int, slides: Bool) {
        if slides, count == 1, let document, document.slides == nil, document.isPaged || !currentScript.pages.isEmpty {
            dragging = .attach(document.title.isEmpty ? String(localized: "Untitled") : document.title)
        } else if slides, count == 1 {
            dragging = .slides
        } else {
            dragging = .files(max(1, count))
        }
    }

    func dragEnded() {
        dragging = nil
    }

    /// 在窗口上方说一句。不是 busy 的话，过一会儿自己消失。
    func announce(_ text: String, busy: Bool = false, problem: Bool = false, action: NoticeAction? = nil) {
        let notice = Notice(text: text, busy: busy, problem: problem, action: action)
        self.notice = notice
        guard !busy else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (action != nil ? 7 : problem ? 4 : 2.6)) { [weak self] in
            if self?.notice?.id == notice.id { self?.notice = nil }
        }
    }

    // MARK: 幻灯片

    /// 主窗口里显示幻灯片：配了幻灯片，或者是一页一段 / 分了页的稿子（还没配时上面是一块「把 PDF 拖到这里」）。
    var showsStage: Bool { hasSlides }

    /// 这份稿子跟幻灯片有关。
    var hasSlides: Bool { document?.slides != nil || document?.isPaged == true || !currentScript.pages.isEmpty }

    /// 正在放幻灯片：有幻灯片的这份稿子在提词。窗口进全屏，只放当前这一页（见 SlideShow）。
    var presenting: Bool { (prompter.isActive && promptingSelection || preparingShow) && showsStoryboard }

    /// 放幻灯片前窗口的样子（停了还原）。
    private var windowBeforeShow: (window: NSWindow, frame: NSRect, transparent: Bool,
                                   titleVisibility: NSWindow.TitleVisibility, fullSize: Bool,
                                   options: NSApplication.PresentationOptions)?

    /// 放映时窗口顶上让给提词条的那一条有多高（窗口从系统菜单栏下面开始，菜单栏本身不算）。
    var presentationTopInset: CGFloat {
        guard let screen = mainWindow?.screen ?? NSScreen.main else { return 0 }
        return max(0, topInset(on: screen) - menuBarHeight(on: screen))
    }

    /// 系统菜单栏占了屏幕顶上多高。放映时菜单栏照常显示、保持系统的样子，窗口从它下面开始；
    /// 系统设了自动隐藏菜单栏就是 0。
    private func menuBarHeight(on screen: NSScreen) -> CGFloat {
        max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    private func topInset(on screen: NSScreen) -> CGFloat {
        var top = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        let ribbonScreen = RibbonGeometry.screen(for: prefs.display)
        if ribbonScreen == screen {
            let ribbon = RibbonGeometry.make(screen: screen, size: prefs.size, left: prefs.ribbonLeft, right: prefs.ribbonRight)
            top = max(top, (screen.frame.maxY - ribbon.frame.minY).rounded(.up) + (ribbon.cornerRadius > 0 ? 4 : 0))
        }
        return top
    }

    /// 放映时幻灯片在屏幕上的位置（AppKit 全局坐标）：整块屏幕顶上让出菜单栏和提词条那一条，剩下的按幻灯片的比例放到最大、居中。
    /// 录屏幕时录的就是这一块（不带上下的白边）。
    func presentedSlide(on screen: NSScreen) -> CGRect {
        let top = topInset(on: screen)
        let area = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: screen.frame.height - top)
        return Composition.fit(aspect: deck.aspect, in: area)
    }

    /// 主窗口（全屏时系统还会多出一个放标题栏的窗口，不能拿错）。
    private var mainWindow: NSWindow? {
        NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }.max { $0.frame.width < $1.frame.width }
    }

    /// 提词开始 / 停了：有幻灯片的话，窗口变成只有这张幻灯片（幻灯片的比例、没有标题栏和红绿灯），
    /// 放在菜单栏下面、程序坞上面的正中间，顶上留给提词条。录屏选「录制所选窗口」就只录到幻灯片。停了还原。
    private func presentationChanged(active: Bool) {
        if active, presenting {
            NSCursor.setHiddenUntilMouseMoves(true)
            if let window = mainWindow { enterPresentation(window) }
        } else if !active {
            preparingShow = false
            restoreWindowAfterShow()
        }
    }

    /// 窗口变成这张幻灯片（录屏时先摆好）。已经是了就不动。
    /// 放映：系统菜单栏照常留着（保持系统的样子），程序坞先藏起来；窗口铺满菜单栏下面的整块屏幕，
    /// 幻灯片放到最大，顶上那一条留给提词条。
    private func enterPresentation(_ window: NSWindow) {
        guard windowBeforeShow == nil, !window.styleMask.contains(.fullScreen) else { return }
        windowBeforeShow = (window, window.frame, window.titlebarAppearsTransparent, window.titleVisibility,
                            window.styleMask.contains(.fullSizeContentView), NSApp.presentationOptions)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        setWindowButtons(of: window, hidden: true)
        NSApp.presentationOptions = [.autoHideDock]
        if let screen = window.screen ?? NSScreen.main {
            var frame = screen.frame
            frame.size.height -= menuBarHeight(on: screen)
            window.setFrame(frame, display: true, animate: true)
        }
        Log.info("slides: full screen, \(Int(window.frame.width))x\(Int(window.frame.height))")
    }

    /// 右边（稿子、分镜表）最窄多宽：底栏放得下。
    static let detailMinWidth: CGFloat = 600

    /// 正常的窗口：980 × 640，在屏幕正中间。
    private func normalFrame(for window: NSWindow) -> NSRect {
        let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(980, area.width), height: min(640, area.height))
        return NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// 放完了（或者放到一半退出）：窗口变回原来的大小和样子。
    func restoreWindowAfterShow() {
        guard let before = windowBeforeShow else { return }
        windowBeforeShow = nil
        let window = before.window
        NSApp.presentationOptions = before.options
        setWindowButtons(of: window, hidden: false)
        window.titlebarAppearsTransparent = before.transparent
        window.titleVisibility = before.titleVisibility
        if !before.fullSize { window.styleMask.remove(.fullSizeContentView) }
        let frame = before.frame.width >= AppModel.detailMinWidth + 220 && before.frame.height >= 440 ? before.frame : normalFrame(for: window)
        window.setFrame(frame, display: true, animate: true)
        Log.info("slides: window back")
    }

    private func setWindowButtons(of window: NSWindow, hidden: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = hidden
        }
    }


    /// 分镜表（一页一行）：配上了幻灯片的稿子都是这样（配上时就变成一页一段了）。
    var showsStoryboard: Bool { showsStage && deck.isLoaded && document?.isPaged == true }

    private var pagedCache: (text: String, paged: PagedScript)?

    /// 这份稿子一页一段的样子（空一行翻一页）。
    var paged: PagedScript {
        let text = document?.text ?? ""
        if let pagedCache, pagedCache.text == text { return pagedCache.paged }
        let paged = PagedScript(text: text)
        pagedCache = (text, paged)
        return paged
    }

    /// 全文里每一页从哪开始（编辑器左边空白里标上页码）：一页一段的稿子才有，没话说的页不标。
    var pageMarks: [(number: Int, offset: Int)] {
        guard document?.isPaged == true else { return [] }
        return paged.pages.filter { $0.range.length > 0 }.map { ($0.number, $0.range.location) }
    }

    /// 原文 offset 在第几页；没分页是 nil。
    private func page(at offset: Int) -> Int? {
        if document?.isPaged == true { return paged.number(at: offset) }
        let pages = currentScript.pages
        return (pages.last { $0.raw <= offset } ?? pages.first)?.number
    }

    /// 分镜表里亮着的那一行：提词时是正在念的那页，不然是幻灯片翻到的那页。
    var activePage: Int {
        if promptingSelection, let offset = progressOffset, let page = page(at: offset) { return page }
        return deck.page
    }

    /// 分镜表：让第 page 页那一行滚出来、把光标放进去（atEnd：放在最后，不然放在最前）。
    @Published private(set) var pageFocus: (page: Int, serial: Int, atEnd: Bool)?
    private var pageFocusSerial = 0

    private func requestPageFocus(_ page: Int, atEnd: Bool) {
        pageFocusSerial += 1
        pageFocus = (page, pageFocusSerial, atEnd)
    }

    /// 分镜表里改了第 n 页的话。
    func setPageText(_ n: Int, _ text: String) {
        guard let document, !promptingSelection else { return }
        let updated = paged.setting(text, forPage: n)
        if updated != document.text { store.update(document.id, text: updated) }
    }

    /// 分镜表里往第 n 页那一行粘贴：话都进这一页（中间的空行去掉），在哪粘就在哪。
    /// 粘的是带空行的一大段（可能是一整篇稿子）：下面问一句要不要按空行分到后面几页，点了才分，⌘Z 能撤回。
    /// 返回 false：照普通粘贴。
    func pastePages(_ pasted: String, intoPage n: Int, replacing selection: NSRange, undo: UndoManager?) -> Bool {
        guard let document, !promptingSelection,
              let spread = paged.pasting(pasted, intoPage: n, replacing: selection) else { return false }
        let id = document.id
        let count = spread.page - n + 1
        // 先照普通粘贴进这一页；粘完记下那时的原文，点「分页」的时候原文没再改过才分
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let after = self.store.documents.first(where: { $0.id == id })?.text else { return }
            let split = NoticeAction(title: String(localized: "Split into \(count) slides")) { [weak self] in
                guard let self, self.store.documents.first(where: { $0.id == id })?.text == after else { return }
                self.notice = nil
                self.replaceText(id, with: spread.text, undo: undo)
                if self.deck.isLoaded { self.deck.go(to: min(spread.page, self.deck.pageCount)) }
                self.requestPageFocus(spread.page, atEnd: true)
            }
            self.announce(String(localized: "Pasted into this slide"), action: split)
        }
        return false
    }

    private func replaceText(_ id: UUID, with text: String, undo: UndoManager?) {
        guard let old = store.documents.first(where: { $0.id == id })?.text, old != text else { return }
        store.update(id, text: text)
        undo?.registerUndo(withTarget: self) { model in model.replaceText(id, with: old, undo: undo) }
        undo?.setActionName(String(localized: "Paste"))
    }

    /// 分镜表里光标进了第 n 页那一行（local：在这一行里的位置）：幻灯片翻过去，播放从这里开始。
    func focusPage(_ n: Int, at local: Int) {
        guard !promptingSelection else { return }
        if deck.isLoaded { deck.go(to: n) }
        let length = (paged.text(ofPage: n) as NSString).length
        cursor = paged.start(ofPage: n) + min(local, length)
    }

    /// 分镜表里从一行走到上一行 / 下一行（↑ ↓ 走到头、Tab、在空行上回车）。
    func movePage(from n: Int, by delta: Int) {
        let target = n + delta
        guard target >= 1, target <= max(deck.pageCount, paged.pages.count) else { return }
        if deck.isLoaded { deck.go(to: target) }
        requestPageFocus(target, atEnd: delta < 0)
    }

    /// 分镜表：点了第 n 页的缩略图。
    func selectPage(_ n: Int) {
        deck.select(n)
    }

    /// 幻灯片里删掉的那一页的话：不要了。
    func dropRemovedSlide(_ index: Int) {
        guard let id = selection else { return }
        store.modify(id) { document in
            guard var removed = document.removedSlides, removed.indices.contains(index) else { return }
            removed.remove(at: index)
            document.removedSlides = removed.isEmpty ? nil : removed
        }
    }

    /// 换了稿子：换成它配的幻灯片（没配就清掉），翻到上次念到的那一页。同一份幻灯片不动；提词时也不动。
    private func loadDeck() {
        // 正在念的就是这一份：幻灯片跟着提词翻，不动它。念的是别的稿子（比如录屏时把窗口叫回来、点开这份 PPT 讲给人看）：
        // 照常显示这一份的幻灯片。
        guard !promptingSelection, let document else { return }
        let url = document.slidesURL
        // 配过幻灯片，文件却找不到了（挪走了、删了）：说一声，上面是「把幻灯片拖进来」
        if document.slides != nil, url == nil, deck.url != nil || !deck.isLoaded {
            announce(String(localized: "Can’t find the slides file — drop it in again"), problem: true)
        }
        guard url != deck.url || (url != nil && !deck.isLoaded) else { return }
        // 以前配了幻灯片、用「## 第 N 页」分页的稿子：换成一页一段
        if url != nil, !document.isPaged { makePaged(document.id) }
        deck.load(url, at: page(at: cursor) ?? 1)
        followMovedPage(syncSlides(document.id))
    }

    /// 有人翻到了第 number 页：提词时跳到这一页的稿子；没在提词就让稿子跟过去（分镜表：那一行；没配上幻灯片的：那一段滚到最上面）。
    private func deckFlipped(to number: Int) {
        // 只有正在念的这一份才让提词跟着翻；在看别的稿子时翻页，不去动正在念的那份。
        if promptingSelection {
            prompter.goToPage(number)
            return
        }
        if document?.isPaged == true {
            let start = paged.start(ofPage: number)
            if showsStoryboard {
                cursor = start
                requestPageFocus(number, atEnd: true)
            } else {
                focus(start + (paged.text(ofPage: number) as NSString).length, top: true)
            }
            return
        }
        guard let page = currentScript.pages.first(where: { $0.number == number }), let text = document?.text else { return }
        let source = text as NSString
        let line = source.lineRange(for: NSRange(location: page.raw, length: 0))
        var end = NSMaxRange(line)
        while end > line.location, [10, 13].contains(source.character(at: end - 1)) { end -= 1 }
        focus(end, top: true)
    }

    /// 选一份幻灯片配给这份稿子（菜单「配上幻灯片…」、幻灯片那块的「选择 PDF…」）。
    func chooseSlides() {
        guard document != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf] + ["key", "pptx", "ppt"].compactMap { UTType(filenameExtension: $0) }
        panel.message = String(localized: "Choose the slides for this script: a PDF, PowerPoint or Keynote file.")
        if panel.runModal() == .OK, let url = panel.url { attachSlides(url) }
    }

    /// 给这份稿子配上幻灯片：PDF 直接用；.key / .pptx 要让 Keynote 导出成 PDF。
    func attachSlides(_ url: URL) {
        guard let id = selection else { return }
        switch url.pathExtension.lowercased() {
        case "pdf":
            attachPDF(url, to: id)
        case "pptx", "ppt":
            convertSlides(url, for: id)
        case "key":
            guard SlideImport.keynoteInstalled else { return keynoteNeeded() }
            convertSlides(url, for: id)
        default:
            importProblem(SlideImport.Failure.unreadable)
        }
    }

    /// .key 只有 Keynote 读得了：没装就请你在 Keynote 里导出成 PDF。
    private func keynoteNeeded() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Export the slides as a PDF first")
        alert.informativeText = String(localized: "Keynote files can only be read with Keynote installed. Export the slides as a PDF from Keynote and drop it here.")
        alert.runModal()
    }

    /// 配上一份 PDF。稿子变成一页一段（以前「## 第 N 页」分页的，换过来；没分页的，空一行就是一页）。
    private func attachPDF(_ url: URL, to id: UUID, imported: Bool = false) {
        guard let count = try? SlideImport.pageCount(pdf: url) else {
            notice = nil
            importProblem(SlideImport.Failure.unreadable)
            return
        }
        let title = store[id]?.title ?? ""
        announce(imported ? String(localized: "Imported “\(title)” · \(count) slides") : String(localized: "Slides paired · \(count) slides"))
        makePaged(id)
        store.setSlides(id, url)
        guard id == selection, !promptingSelection else { return }
        deck.load(url, at: page(at: cursor) ?? 1)
        followMovedPage(syncSlides(id))
        prefs.showSlides = true
    }

    /// 稿子变成一页一段：「## 第 N 页」分页的，每一页一段；第一行是「# 标题」的，标题拿去当名字。
    private func makePaged(_ id: UUID) {
        guard let document = store[id], !document.isPaged else { return }
        var pages: [String]
        var title: String?
        if let converted = PagedScript.fromHeadings(document.text) {
            pages = converted.pages
            title = converted.title
        } else {
            let paged = PagedScript(text: document.text)
            pages = paged.pages.map { paged.text(ofPage: $0.number) }
            if let first = pages.first, first.hasPrefix("#"), !first.contains("\n") {
                title = first.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                pages.removeFirst()
            }
        }
        store.update(id, text: PagedScript.compose(pages))
        store.modify(id) { document in
            document.byPage = true
            if document.name == nil, let title, !title.isEmpty { document.name = title }
        }
    }

    /// 幻灯片改过、稿子挪过：翻到刚才那一页现在的位置（分镜表里光标也跟过去）。
    private func followMovedPage(_ map: [Int: Int]?) {
        guard let map, let moved = map[deck.page], moved != deck.page else { return }
        deck.go(to: moved)
        if showsStoryboard {
            requestPageFocus(moved, atEnd: true)
        } else {
            cursor = paged.start(ofPage: moved)
        }
    }

    /// 配的 PDF 和上次比变了（插了页、删了页、调了顺序、改了字）：稿子跟着原来那一页走。挪了的话返回旧页 → 新页。
    @discardableResult
    private func syncSlides(_ id: UUID) -> [Int: Int]? {
        guard deck.isLoaded, let document = store[id], document.isPaged else { return nil }
        let fresh = deck.signatures()
        guard let old = document.slideSignatures, old != fresh else {
            if document.slideSignatures == nil { store.modify(id) { $0.slideSignatures = fresh } }
            return nil
        }
        let (map, matched) = SlideMatch.align(old: old, new: fresh)
        let moved = old.count != fresh.count || map.contains { $0.key != $0.value } || map.count < old.count
        // 认出来的太少：多半是换了一份别的幻灯片，稿子不动。
        if moved, matched * 3 >= old.count {
            let result = SlideMatch.remap(document.text, map: map, oldCount: old.count, newCount: fresh.count)
            store.update(id, text: result.text)
            if !result.removed.isEmpty {
                store.modify(id) { $0.removedSlides = ($0.removedSlides ?? []) + result.removed }
            }
            Log.info("slides changed: \(old.count) → \(fresh.count) pages, \(matched) recognized, set aside \(result.removed.count)")
            announce(result.removed.isEmpty ? String(localized: "The slides changed — your lines moved with them")
                     : String(localized: "The slides changed — lines of \(result.removed.count) removed slides are at the end"))
            store.modify(id) { $0.slideSignatures = fresh }
            return map
        }
        store.modify(id) { $0.slideSignatures = fresh }
        return nil
    }

    /// 幻灯片变成一页一页的图（PDF），再配给稿子：.pptx 用系统自带的 Quick Look 画（不用装 PowerPoint）；
    /// .key（nil：Keynote 里开着的那份）让 Keynote 导出。
    private func convertSlides(_ url: URL?, for id: UUID, imported: Bool = false) {
        guard !convertingSlides else { return }
        if let url, SlideImport.isPowerPoint(url) {
            convertingSlides = true
            announce(String(localized: "Turning the slides into pages…"), busy: true)
            MainActor.assumeIsolated {
                SlideRenderer.render(url) { [weak self] result in
                    guard let self else { return }
                    self.convertingSlides = false
                    switch result {
                    case .success(let pdf): self.attachPDF(pdf, to: id, imported: imported)
                    case .failure(let error):
                        self.notice = nil
                        self.importProblem(error)
                    }
                }
            }
            return
        }
        guard SlideImport.keynoteInstalled else { return }
        convertingSlides = true
        announce(String(localized: "Turning the slides into pages…"), busy: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SlideImport.exportPDF(from: url) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.convertingSlides = false
                switch result {
                case .success(let pdf): self.attachPDF(pdf, to: id, imported: imported)
                case .failure(let error):
                    self.notice = nil
                    self.importProblem(error)
                }
            }
        }
    }

    // MARK: 测试

    /// `-autostart steady` 之类：打开就开始提词，方便截图和测试。
    private func autostartForTesting() {
        // `-autostartIndex 1`：从稿子库里第几份开始（默认是第一份）。
        if UserDefaults.standard.object(forKey: "autostartIndex") != nil {
            let index = UserDefaults.standard.integer(forKey: "autostartIndex")
            if let document = store.documents[safe: index] { selection = document.id }
        }
        // `-windowShot /路径/window.png`：3 秒后把主窗口画成图片（看界面用）。
        if let shot = UserDefaults.standard.string(forKey: "windowShot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let window = NSApp.windows.filter(\.isVisible).max(by: { $0.frame.width < $1.frame.width }),
                      let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot))
            }
        }
        // `-ribbonShot /路径/ribbon.png`：开始后把提词条画成图片（2.5 秒一张，按一次「下一个」再一张），看排版。
        if let shot = UserDefaults.standard.string(forKey: "ribbonShot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.7) { [weak self] in
                self?.ribbon.snapshot(to: URL(fileURLWithPath: shot))
                self?.prompter.step(1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) { [weak self] in
                self?.ribbon.snapshot(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-2.png")))
                self?.prompter.step(1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.7) { [weak self] in
                self?.ribbon.snapshot(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-3.png")))
            }
        }
        // `-dumpMenus YES`：打开一秒后把菜单栏每个菜单里有哪些项记到日志里（看系统塞的东西拿掉没有）。
        if UserDefaults.standard.bool(forKey: "dumpMenus") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MenuTrim.trimMainMenu()
                for menu in NSApp.mainMenu?.items ?? [] {
                    Log.info("menu \(menu.title): \((menu.submenu?.items ?? []).map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | "))")
                }
            }
        }
        // `-showTake switch`：回放一条，再换到另一条：换完以后回放上面还得是箭头（旧的那块淡出时不能把新的挡板撤了）。
        if UserDefaults.standard.string(forKey: "showTake") == "switch" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.recorder.takes.count >= 2 else { Log.info("shield test: need two takes"); return }
                self.recorder.show(self.recorder.takes[0].url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.recorder.show(self.recorder.takes[1].url) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    let shield = CursorShields.shared.rects["take"]
                    var texts: [NSTextView] = []
                    func collect(_ view: NSView) {
                        if let text = view as? NSTextView { texts.append(text) }
                        view.subviews.forEach(collect)
                    }
                    if let content = self.mainWindow?.contentView { collect(content) }
                    // 回放盖满了编辑区：文字框里一块 I 形光标的地方都不该剩
                    let beam = texts.flatMap { TextCursor.rects(in: $0) }.reduce(0) { $0 + $1.width * $1.height }
                    Log.info("shield test: take shield \(shield.map { "\(Int($0.width))x\(Int($0.height))" } ?? "missing"), \(texts.count) text views, I-beam area left \(Int(beam)) pt²")
                    NSApp.terminate(nil)
                }
            }
        }
        // `-showTake latest`：打开就回放最新的一条（测回放会不会崩）。
        if UserDefaults.standard.string(forKey: "showTake") == "latest" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if let take = self?.recorder.takes.first { self?.recorder.show(take.url) }
            }
        }
        // `-deckTest /路径/x.pdf -deckShot /路径/deck.png`：试幻灯片（配上 -storeFolder，不碰你的稿子库）。
        if let path = UserDefaults.standard.string(forKey: "deckTest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.deckTest(URL(fileURLWithPath: path)) }
        }
        // `-uiShots /路径/ui.png`：几块界面单独画出来看（设置、底栏、权限卡片），画完退出。玻璃画不出来。
        if let path = UserDefaults.standard.string(forKey: "uiShots") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated {
                guard let self else { return }
                @MainActor func shot<V: View>(_ view: V, _ suffix: String) {
                    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
                    renderer.scale = 2
                    if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-\(suffix).png")))
                    }
                }
                shot(SettingsView(prefs: self.prefs), "settings")
                // 左边列表的几行（录像的封面要异步读，这里是空的）
                shot(VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(self.store.documents.prefix(5).enumerated()), id: \.offset) { index, document in
                        ScriptRow(document: document, prompting: index == 1)
                            .padding(.horizontal, 18)
                            .background(SelectionPill(selected: index == 0))
                    }
                    HStack(spacing: 6) {
                        Text("Takes").font(.system(size: 11, weight: .semibold)).foregroundStyle(Paper.gray)
                        HeaderButton(symbol: "folder", help: "") {}
                    }
                    .padding(.horizontal, 18).padding(.top, 14)
                    ForEach(Array(self.recorder.takes.prefix(4).enumerated()), id: \.offset) { index, take in
                        TakeRow(take: take, playing: false, new: index == 0)
                            .padding(.horizontal, 18)
                            .background(SelectionPill(selected: index == 1))
                    }
                }
                .frame(width: 290).padding(.vertical, 14).background(Color(rgb: 0xF2F2F4)), "list")
                let frameState = RecordingFrame.State()
                frameState.region = CGRect(x: 300, y: 60, width: 640, height: 400)
                frameState.fullScreen = false
                frameState.visible = true
                shot(FrameView(state: frameState).frame(width: 1240, height: 560).background(Color(rgb: 0xDDE3EA)), "frame")
                shot(FloatingSheet(close: {}) { SettingsView(prefs: self.prefs) }.frame(width: 900, height: 760).background(Paper.white), "sheet")
                shot(VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) { Text("Takes").font(.system(size: 11, weight: .semibold)).foregroundStyle(Paper.gray); HeaderButton(symbol: "folder", help: "") {} }
                    HStack(spacing: 18) {
                        ForEach(PromptMode.allCases) { Image(systemName: $0.symbol).font(.system(size: 15, weight: .medium)) }
                        ForEach(RecordLayout.allCases) { Image(systemName: $0.symbol).font(.system(size: 15, weight: .medium)) }
                        Image(systemName: "video.slash").font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Paper.charcoal)
                }.padding(20).background(Paper.white), "icons")
                shot(ControlBar(model: self, prompter: self.prompter, prefs: self.prefs).frame(width: 640).background(Paper.white), "bar")
                shot(ScreenPermissionCard(model: self, step: .ask).frame(width: 420, height: 320), "permission")
                shot(HStack(spacing: 16) {
                    Switch(isOn: .constant(true)); Switch(isOn: .constant(false)); Spinner(size: 18)
                    PrimaryButton(title: "Primary") {}; PillButton(title: "Pill") {}
                }.padding(20).background(Paper.haze), "controls")
                Log.info("ui shots: done")
                NSApp.terminate(nil)
                }
            }
            return
        }
        // `-checkScreen YES`：看一眼屏幕录制权限（新开的进程读到的才准），写进日志就退出。
        if UserDefaults.standard.bool(forKey: "checkScreen") {
            let preflight = CGPreflightScreenCaptureAccess()
            guard preflight else {
                // 没有权限就不去碰 ScreenCaptureKit（会弹系统的对话框）
                Log.info("screen check: preflight false")
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                Log.info("screen check: preflight \(preflight), shareable content \(content != nil ? "ok (\(content!.displays.count) displays)" : "failed: \(error.map { "\($0)" } ?? "?")")")
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        // `-sidebarClickTest YES`：在左边列表里真的点一下（造鼠标事件，不动你的鼠标），看能不能切过去；再双击，看是不是改名。
        if UserDefaults.standard.bool(forKey: "sidebarClickTest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.sidebarClickTest() }
        }
        // `-recordTest /路径/x.pdf -takesFolder /路径 -fakeCamera YES -noAudio YES`：每种画面录几秒（不开镜头和麦克风）。
        if let path = UserDefaults.standard.string(forKey: "recordTest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.recordTest(URL(fileURLWithPath: path)) }
        }
        // `-pptxTest /路径/x.pptx -deckShot /路径/deck.png`：拖进一份 PowerPoint，看页面和备注有没有出来。
        if let path = UserDefaults.standard.string(forKey: "pptxTest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                let shot = UserDefaults.standard.string(forKey: "deckShot") ?? "/tmp/deck.png"
                NSApp.activate(ignoringOtherApps: true)
                self.mainWindow?.orderFrontRegardless()
                // 先装作拖着一份幻灯片进窗口，看提示
                self.dragEntered(count: 1, slides: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.shootWindow(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-drag.png")))
                    self.dragEnded()
                    self.importFiles([URL(fileURLWithPath: path)])
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.shootWindow(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-busy.png")))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (path.hasSuffix(".ppt") ? 11 : 5)) {
                    let texts = (1...max(1, self.paged.pages.count)).map { self.paged.text(ofPage: $0) }
                    Log.info("pptx test: \(self.deck.pageCount) slides, storyboard \(self.showsStoryboard), notes: \(texts.joined(separator: " | "))")
                    if let window = self.mainWindow {
                        Log.info("pptx test window: \(Int(window.frame.width))x\(Int(window.frame.height)), min \(Int(window.minSize.width))x\(Int(window.minSize.height)), content min \(Int(window.contentMinSize.width))x\(Int(window.contentMinSize.height))")
                    }
                    let shot = UserDefaults.standard.string(forKey: "deckShot") ?? "/tmp/deck.png"
                    self.shootWindow(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-pptx.png")))
                    // 在左边列表里换一份稿子：键盘要留在列表（选中不会先蓝后灰）
                    if let window = self.mainWindow, let list = window.contentView?.firstDescendant(of: NSTableView.self),
                       let other = self.store.documents.first(where: { $0.id != self.selection })?.id {
                        let back = self.selection
                        window.makeFirstResponder(list)
                        self.selection = other
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            Log.info("pptx test sidebar: after picking a script, keyboard in \(String(describing: type(of: window.firstResponder!)))")
                            self.selection = back
                        }
                    }
                    // 滚动方式面板：打开拍一张；四个动画各取几帧拼成一张
                    self.showingModes = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        self.shootWindow(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-modes.png")))
                        self.showingModes = false
                    }
                    do {
                        let strip = VStack(spacing: 8) {
                            ForEach(PromptMode.allCases) { mode in
                                HStack(spacing: 8) {
                                    ForEach([0.2, 0.9, 1.6, 2.6], id: \.self) { t in
                                        ModeFrame(mode: mode, t: t).frame(width: 124, height: 80)
                                            .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                            }
                        }.padding(12).background(Paper.haze)
                        let renderer = ImageRenderer(content: strip)
                        renderer.scale = 2
                        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                            try? rep.representation(using: .png, properties: [:])?
                                .write(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-mode-frames.png")))
                        }
                    }
                    // 移除幻灯片 → 撤销；改名 → 撤销；删一份 → 提示（都用窗口的撤销）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                        guard let id = self.store.documents.first(where: { $0.slides != nil })?.id else { return }
                        let undo = UndoManager()
                        self.selection = id
                        self.removeSlides(id, undoManager: undo)
                        Log.info("pptx test remove slides: slides \(self.store[id]?.slides == nil ? "gone" : "still there"), deck \(self.deck.isLoaded ? "loaded" : "empty"), notice “\(self.notice?.text ?? "")”")
                        undo.undo()
                        Log.info("pptx test remove slides → undo: slides \(self.store[id]?.slides == nil ? "gone" : "back"), deck \(self.deck.isLoaded ? "loaded" : "empty")")
                        let before = self.store[id]?.title ?? ""
                        self.rename(id, to: "Talk for Friday", undoManager: undo)
                        let renamed = self.store[id]?.title ?? ""
                        undo.undo()
                        Log.info("pptx test rename: “\(before)” → “\(renamed)” → undo → “\(self.store[id]?.title ?? "")”")
                        if let other = self.store.documents.first(where: { $0.id != id })?.id {
                            self.delete(other, undoManager: undo)
                            Log.info("pptx test delete: notice “\(self.notice?.text ?? "")”, \(self.store.documents.count) left")
                            // 等编辑器换完稿子再撤销（以前换稿子会把撤销清空，⌘Z 找不回来）
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                Log.info("pptx test delete: can undo \(undo.canUndo)")
                                undo.undo()
                                Log.info("pptx test delete → undo: \(self.store.documents.count) scripts")
                            }
                        }
                    }
                    // 左边列表：配了幻灯片的那份有没有第一页的小图
                    if let url = self.store.documents.first(where: { $0.slides != nil })?.slidesURL {
                        Task { @MainActor in
                            let image = await SlideThumbnails.first(of: url)
                            Log.info("pptx test sidebar thumbnail: \(image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none")")
                        }
                    }
                    // 光标：打开滚动方式面板，面板中间那一点在文字框上是不是箭头
                    self.showingModes = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if let window = self.mainWindow, let text = window.contentView?.allDescendants(of: RowTextView.self).first {
                            let shield = CursorShields.shared.rects["modes"]
                            let probe = text.convert(text.visibleRect, to: nil)
                            let point = NSPoint(x: probe.midX, y: probe.midY)
                            let textUnderneath = TextCursor.rects(in: text).contains { $0.contains(text.convert(point, from: nil)) }
                            Log.info("pptx test cursor: panel shield \(shield.map { NSStringFromRect($0) } ?? "none"), over text while panel open → \(textUnderneath ? "I-beam" : "arrow")")
                        }
                        self.showingModes = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if let window = self.mainWindow, let text = window.contentView?.allDescendants(of: RowTextView.self).first {
                                let probe = text.convert(text.visibleRect, to: nil)
                                let point = text.convert(NSPoint(x: probe.midX, y: probe.midY), from: nil)
                                Log.info("pptx test cursor: panel closed → \(TextCursor.rects(in: text).contains { $0.contains(point) } ? "I-beam" : "arrow") over the same text")
                            }
                        }
                    }
                    // 速度收进了滚动方式面板；权限提示；空的讲稿库：各画一张
                    do {
                        let pieces = VStack(alignment: .leading, spacing: 18) {
                            SpeedControl(model: self, prompter: self.prompter, prefs: self.prefs)
                            SettingsNote(symbol: "mic.slash", text: String(localized: "Microphone is off"), pane: "Privacy_Microphone")
                            SettingsNote(symbol: "video.slash", text: String(localized: "No camera found"))
                            EmptyLibrary(model: self).frame(width: 420, height: 260)
                        }.padding(20).background(Paper.haze)
                        let renderer = ImageRenderer(content: pieces)
                        renderer.scale = 2
                        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                            try? rep.representation(using: .png, properties: [:])?
                                .write(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-pieces.png")))
                        }
                    }
                    // 改名：叫出输入框，打字、回车，看标题变没变；窗口是不是浅色
                    if let window = self.mainWindow {
                        Log.info("pptx test appearance: \(window.effectiveAppearance.name.rawValue)")
                    }
                    // 改名框本身：放进一个单独的窗口，看它是不是一出来就拿到键盘、回车后交出新名字
                    do {
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
                        let row = ScriptRow(document: self.document ?? ScriptDocument(text: "Hello"), prompting: false, renaming: true) { name in
                            Log.info("pptx test rename field: done with “\(name ?? "nil")”")
                        }
                        window.contentView = NSHostingView(rootView: row.padding(12))
                        window.orderFrontRegardless()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            let editor = window.firstResponder as? NSTextView
                            Log.info("pptx test rename field: keyboard \(editor != nil ? "in the field" : "elsewhere"), selected \(editor.map { NSStringFromRange($0.selectedRange()) } ?? "-") of “\(editor?.string ?? "")”")
                            editor?.insertText("Renamed deck", replacementRange: editor?.selectedRange() ?? NSRange())
                            editor?.insertNewline(nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { window.orderOut(nil) }
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                        guard let window = self.mainWindow, let id = self.selection else { return }
                        Log.info("pptx test rename: main window visible on screen \(window.occlusionState.contains(.visible))")
                        self.renaming = id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let editor = window.firstResponder as? NSTextView
                            let fields = window.contentView?.allDescendants(of: RenameField.Field.self) ?? []
                            Log.info("pptx test rename: \(fields.count) field(s), keyboard in \(String(describing: window.firstResponder.map { type(of: $0) })), sidebar rows \(window.contentView?.allDescendants(of: NSTableView.self).first?.numberOfRows ?? -1), field editor \(editor != nil ? "has the keyboard" : "missing"), shows “\(editor?.string ?? "")”")
                            editor?.selectAll(nil)
                            editor?.insertText("Renamed deck", replacementRange: editor?.selectedRange() ?? NSRange())
                            editor?.insertNewline(nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                Log.info("pptx test rename: title now “\(self.document?.title ?? "")”, renaming \(self.renaming == nil ? "ended" : "still on")")
                            }
                        }
                    }
                    // 快捷键一览单独画出来看
                    do {
                        let renderer = ImageRenderer(content: ShortcutsView())
                        renderer.scale = 2
                        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                            try? rep.representation(using: .png, properties: [:])?
                                .write(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-shortcuts.png")))
                        }
                    }
                    // 文件扇单独画出来看（合上、摊开）
                    for spread in [false, true] {
                        let renderer = ImageRenderer(content: FileFan(spread: spread).padding(30).background(Paper.haze))
                        renderer.scale = 2
                        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                            try? rep.representation(using: .png, properties: [:])?
                                .write(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: spread ? "-fan-open.png" : "-fan.png")))
                        }
                    }
                    // 按两下 ⌘=（走菜单的快捷键），看幻灯片有没有变大；再 ⌘0 回去
                    let width = { NSApp.windows.compactMap { $0.contentView?.allDescendants(of: RowTextView.self).first?.frame.width }.first ?? -1 }
                    let before = width()
                    Log.info("pptx test keys go to \(String(describing: NSApp.keyWindow.map { type(of: $0) })), responder \(String(describing: NSApp.keyWindow?.firstResponder.map { type(of: $0) }))")
                    self.press(24, .command, "=")
                    self.press(24, .command, "=")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        Log.info("pptx test zoom: ⌘= ⌘= → zoom \(self.prefs.zoom), caption \(Int(before)) → \(Int(width()))")
                        self.shootWindow(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-zoom.png")))
                        self.press(29, .command, "0")
                        Log.info("pptx test zoom: ⌘0 → zoom \(self.prefs.zoom)")
                        // 三步上手：每一步拍一张（按任意键到下一步）
                        self.startQuickStart()
                        for step in 0..<3 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(step) * 0.6) {
                                self.shootWindow(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-coach\(step + 1).png")))
                                self.press(49, [], " ")
                                Log.info("pptx test coach: step \(step + 1) → \(self.coachStep.map(String.init) ?? "done")")
                            }
                        }
                    }
                    // 再看两种一句话提示：成了、打不开
                    self.announce(String(localized: "Imported “\(self.document?.title ?? "")” · \(self.deck.pageCount) slides"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        self.shootWindow(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-done.png")))
                        self.announce(String(localized: "Can’t open “\("notes.numbers")”"), problem: true)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.shootWindow(to: URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: "-problem.png")))
                    }
                }
            }
        }
        guard let value = UserDefaults.standard.string(forKey: "autostart"), let mode = PromptMode(rawValue: value) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.prefs.mode = mode
            if UserDefaults.standard.object(forKey: "autostartToken") != nil, let document = self.document {
                let jump = UserDefaults.standard.integer(forKey: "autostartToken")
                let script = Script(text: document.text)
                self.prompter.start(document, fromRaw: script.rawOffset(ofToken: jump))
            } else {
                self.play(fromBeginning: true)
            }
        }
    }
}

extension AppModel {
    /// 导入这份 PDF，每页写一句，然后：在幻灯片里翻页、光标点进第 3 页、开始提词、按翻页笔前后各一下、停下，
    /// 最后换上插了一页的新 PDF（-deckTest2），看稿子有没有跟着原来那一页走。
    /// 每一步把幻灯片、光标 / 提词各在第几页写进日志，主窗口、提词条画成图片。
    fileprivate func deckTest(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.orderFrontRegardless()
        let shot = UserDefaults.standard.string(forKey: "deckShot") ?? "/tmp/deck.png"
        func file(_ suffix: String) -> URL { URL(fileURLWithPath: shot.replacingOccurrences(of: ".png", with: suffix + ".png")) }
        importFiles([url])
        for page in 1...deck.pageCount { setPageText(page, "Page \(page) words go here.") }
        let report = { [weak self] (label: String) in
            guard let self else { return }
            let at = self.prompter.isActive ? self.prompter.documentOffset(ofToken: self.prompter.spoken) : self.cursor
            let who = self.prompter.isActive ? "prompter" : "cursor"
            let focus = self.pageFocus.map { "row \($0.page)" } ?? "-"
            Log.info("deck test \(label): slide \(self.deck.page)/\(self.deck.pageCount), \(who) on page \(self.page(at: at) ?? 0), focus \(focus), storyboard \(self.showsStoryboard)")
            // 分镜表那几行在窗口里的哪儿（看是不是滚丢了）
            if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }), let root = window.contentView {
                let rows = root.allDescendants(of: RowTextView.self)
                let frames = rows.map { row -> String in
                    let r = row.convert(row.bounds, to: nil)
                    return "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
                }
                let scroll = rows.first?.enclosingScrollView
                Log.info("deck test \(label) layout: window \(Int(window.frame.width))x\(Int(window.frame.height)), rows \(frames), scroll at \(scroll.map { "\($0.contentView.bounds.origin.y) of \($0.documentView?.frame.height ?? -1)" } ?? "none")")
            }
        }
        let pages = { [weak self] (label: String) in
            guard let self else { return }
            let texts = (1...max(1, self.paged.pages.count)).map { self.paged.text(ofPage: $0) }
            Log.info("deck test \(label): \(texts.map { $0.isEmpty ? "-" : $0 }.joined(separator: " | ")); set aside \(self.document?.removedSlides ?? [])")
        }
        let steps: [(TimeInterval, () -> Void)] = [
            (1.0, { report("loaded"); self.shootWindow(to: file("-loaded")); self.deck.step(1) }),
            (2.0, {
                report("flipped")
                self.shootWindow(to: file(""))
                self.focusPage(3, at: 2)
            }),
            (7.4, {
                // 在看得见的那一页的话末尾回车：框要跟着长高（光标不能掉到框外面）
                guard let row = self.mainWindow?.contentView?.allDescendants(of: RowTextView.self)
                        .first(where: { $0.string.hasPrefix("Page") }) else { Log.info("deck test newline: no row"); return }
                self.mainWindow?.makeFirstResponder(row)
                row.setSelectedRange(NSRange(location: (row.string as NSString).length, length: 0))
                let box = { row.enclosingScrollView?.frame.height ?? -1 }
                let before = box()
                row.insertNewline(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    Log.info("deck test newline: box \(Int(before)) → \(Int(box())), needs \(Int(row.height(forWidth: row.frame.width)))")
                    // 再打很多行：框到顶了就不再长，在里面滚，光标那一行看得见
                    for n in 1...24 { row.insertText("Line \(n) of a long page.", replacementRange: row.selectedRange()); row.insertNewline(nil) }
                    row.insertText("Last line.", replacementRange: row.selectedRange())
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    // ↓ 走到下一页：下一页的光标要在窗口里看得见，不能被底栏挡住
                    let from = self.pageFocus?.page ?? 0
                    row.moveDown(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        guard let window = self.mainWindow, let next = window.firstResponder as? RowTextView else {
                            Log.info("deck test ↓: no caret"); return
                        }
                        let caret = next.firstRect(forCharacterRange: next.selectedRange(), actualRange: nil)
                        let inWindow = window.convertFromScreen(caret)
                        let content = window.contentLayoutRect
                        Log.info("deck test ↓: page \(from) → \(self.pageFocus?.page ?? 0), caret y \(Int(inWindow.minY)) in window (bottom bar up to 96, top \(Int(content.maxY))) → \(inWindow.minY > 96 && inWindow.maxY < content.maxY ? "visible" : "hidden")")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    guard let scroll = row.enclosingScrollView as? CaptionScrollView, let layout = row.layoutManager, let container = row.textContainer else { return }
                    let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: max(0, row.selectedRange().location - 1), length: 1), actualCharacterRange: nil)
                    let caret = layout.boundingRect(forGlyphRange: glyphs, in: container)
                    let visible = scroll.contentView.documentVisibleRect
                    Log.info("deck test long page: box \(Int(scroll.frame.height)) (max \(Int(scroll.maxHeight))), text \(Int(row.frame.height)), caret at \(Int(caret.midY)) visible \(Int(visible.minY))–\(Int(visible.maxY)) → \(visible.contains(NSPoint(x: visible.midX, y: caret.midY)) ? "shown" : "hidden")")
                }
            }),
            (3.0, { report("caret in row 3"); self.play() }),
            (4.5, { report("prompting"); self.press(124) }),
            (5.5, {
                report("→ forward")
                self.ribbon.snapshot(to: file("-ribbon"))
                self.ribbon.testShowControls()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let frame = self.ribbon.testControls(to: file("-controls"))
                    Log.info("deck test ribbon controls: \(frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "not showing"), slide counter \(self.prompter.slideCounter.map { "\($0.page) / \($0.count)" } ?? "none")")
                }
                self.shootWindow(to: file("-prompting"))
                self.press(123)
            }),
            (6.5, { report("← back"); self.prompter.stop() }),
            (7.0, { report("stopped") }),
            (8.0, { pages("before") }),
            (8.3, { self.shootWindow(to: file("-later")) }),
            (8.5, {
                if let second = UserDefaults.standard.string(forKey: "deckTest2") { self.attachSlides(URL(fileURLWithPath: second)) }
            }),
            (9.5, { pages("after a slide was inserted"); report("new deck"); self.shootWindow(to: file("-inserted")) }),
            // 匀速模式从第 1 页开始放：念完第 1 页的话就停住等翻页（不自己滚到下一页）；按 → 才接着走
            // 匀速模式从第 3 页开始放。先手动翻页：念完第 3 页停住；再打开自动翻页：自己翻到第 4 页（第 5 页没写话，不往那儿翻）
            (10.5, {
                self.testPrefs = (self.prefs.mode, self.prefs.countdown, self.prefs.recordTakes, self.prefs.autoTurnSlides)
                self.prefs.mode = .steady
                self.prefs.countdown = false
                self.prefs.recordTakes = false
                self.prefs.autoTurnSlides = false
                self.deck.go(to: 3)
                self.focusPage(3, at: 0)
                self.play()
            }),
            (13.5, {
                report("manual, 3 s on slide 3 (should hold on 3)")
                // 提词条：停在这一页末尾时，下一页的话不该露出来
                self.ribbon.snapshot(to: file("-ribbon-held"))
                Log.info("deck test ribbon: page last token \(self.prompter.pageLastToken ?? -1)")
                self.prefs.autoTurnSlides = true
            }),
            (15.0, { report("automatic (should have turned to 4)") }),
            (17.0, { report("automatic (should stay on 4: slide 5 has no lines)") }),
            (17.5, {
                self.prompter.stop()
                if let saved = self.testPrefs {
                    self.prefs.mode = saved.mode
                    self.prefs.countdown = saved.countdown
                    self.prefs.recordTakes = saved.record
                    self.prefs.autoTurnSlides = saved.autoTurn
                }
            }),
            // 往一页里粘一大段带空行的话（和粘贴走同一条路：先问要不要分页，再照普通粘贴插进去）：不能崩
            (18.2, {
                guard let row = self.mainWindow?.contentView?.allDescendants(of: RowTextView.self).first(where: { $0.isEditable }) else {
                    Log.info("deck test paste: no row"); return
                }
                let block = "2026 年，我紧紧围绕「吃好、睡好、让人类爱上我」三大战略目标，开展了大量工作。\n核心业绩：\n\n* 吃饭：准时到岗，从不缺席\n* 睡觉：见缝插针，全年无休\n* 可爱：稳定输出，偶有超常发挥\n* 陪伴人类：保持距离，适当出现\n"
                self.mainWindow?.makeFirstResponder(row)
                row.setSelectedRange(NSRange(location: (row.string as NSString).length, length: 0))
                _ = row.onSpread?(block, row.selectedRange(), row.undoManager)
                row.insertText(block, replacementRange: row.selectedRange())
            }),
            (19.6, { pages("after pasting a block with blank lines (still running)") }),
        ]
        for (delay, action) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) }
    }

    /// 录屏测试（-fakeScreen、-fakeCamera：不真录屏、不开镜头和麦克风）：
    /// 有幻灯片的讲稿「屏幕 + 人像」（中途把圆框拖出去，看它弹回来、记下来）、「屏幕」不要背景；
    /// 没幻灯片的讲稿「屏幕 + 人像」录整块屏幕。各录 5 秒，看文件多长、多大，抽两帧存成图片。设置测完改回去。
    fileprivate func recordTest(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.orderFrontRegardless()
        let shotPath = UserDefaults.standard.string(forKey: "deckShot") ?? "/tmp/deck.png"
        func file(_ suffix: String) -> URL { URL(fileURLWithPath: shotPath.replacingOccurrences(of: ".png", with: suffix + ".png")) }
        importFiles([url])
        for page in 1...deck.pageCount { setPageText(page, "Page \(page) words go here, and a few more words to read aloud.") }
        let slidesDocument = selection
        let saved = (mode: prefs.mode, countdown: prefs.countdown, record: prefs.recordTakes, layout: prefs.recordLayout,
                     x: prefs.bubbleX, y: prefs.bubbleY, size: prefs.bubbleSize)
        // 测完连「没设过」也还原（不然默认值会被写死）
        let keys = ["mode", "countdown", "recordTakes", "recordLayout", "bubbleX", "bubbleY", "bubbleSize"]
        let stored = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        prefs.mode = .steady
        prefs.countdown = false
        let cases: [(layout: RecordLayout, slides: Bool)] = [(.both, true), (.screen, true), (.both, false)]
        var takes: [(String, URL?)] = []
        func name(_ index: Int) -> String {
            let item = cases[index]
            return "\(item.layout.rawValue), \(item.slides ? "slides" : "plain script")"
        }
        func rect(_ r: CGRect?) -> String { r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none" }
        func finish() {
            prefs.mode = saved.mode
            prefs.countdown = saved.countdown
            prefs.recordTakes = saved.record
            prefs.recordLayout = saved.layout
            prefs.bubbleX = saved.x
            prefs.bubbleY = saved.y
            prefs.bubbleSize = saved.size
            for (key, value) in stored {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            Log.info("record test: prefs restored")
            Task { @MainActor in
                for (index, (label, url)) in takes.enumerated() {
                    guard let url else {
                        Log.info("record test \(label): no file")
                        continue
                    }
                    let asset = AVURLAsset(url: url)
                    let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? -1
                    let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                    let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                    let size = try? await video.first?.load(.naturalSize)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = .zero
                    var frames: [String] = []
                    for (suffix, seconds) in [("a", 0.5), ("b", max(0.5, duration - 0.4))] {
                        if let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image {
                            let rep = NSBitmapImageRep(cgImage: image)
                            try? rep.representation(using: .png, properties: [:])?.write(to: file("-take\(index)\(suffix)"))
                            frames.append("\(suffix) \(image.width)x\(image.height)")
                        }
                    }
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    Log.info("record test \(label): \(url.lastPathComponent), \(String(format: "%.1f", duration)) s, video \(size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none"), audio tracks \(audio.count), \(bytes / 1024) KB, frames \(frames.joined(separator: ", "))")
                }
                Log.info("record test: done")
            }
        }
        func run(_ index: Int) {
            guard index < cases.count else { return finish() }
            let item = cases[index]
            if item.slides {
                selection = slidesDocument
            } else if !(document?.slides == nil && document?.isPaged == false) {
                newScript(text: "A plain script without slides. Just some words to read while the screen is recorded.")
            }
            setShot(item.layout)
            if item.slides {
                deck.go(to: 1)
                focusPage(1, at: 0)
            }
            Log.info("record test \(name(index)): shot \(shot?.rawValue ?? "none"), storyboard \(showsStoryboard)")
            let before = recorder.take
            play()
            // 第一种：倒数自己走完，中途把圆框拖出去（松手后弹回来，倒数从 3 重新开始）；另外两种：倒数时按空格马上开始
            let lead: Double = index == 0 ? 5.6 : 1.4
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let frame = self.mainWindow?.frame
                Log.info("record test \(name(index)): counting down \(self.staging), recording \(self.recorder.isRecording), presenting \(self.presenting), window \(rect(frame)), region \(rect(self.recorder.bubble.region)), bubble \(self.recorder.bubble.window?.isVisible == true ? rect(self.recorder.bubble.circle) : "hidden")")
                if index != 0 { self.finishCountdown() }
            }
            if index == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    guard let window = self.recorder.bubble.window else { return }
                    let region = self.recorder.bubble.region
                    window.setFrameOrigin(NSPoint(x: region.minX - window.frame.width / 2, y: region.maxY - window.frame.height / 3))
                    Log.info("record test: bubble dragged to \(rect(self.recorder.bubble.circle)) while counting down")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                    Log.info("record test: bubble settled at \(rect(self.recorder.bubble.circle)), saved \(String(format: "%.3f, %.3f size %.3f", self.prefs.bubbleX, self.prefs.bubbleY, self.prefs.bubbleSize)), counting down \(self.staging), \(self.countdown.state.deadline.map { String(format: "%.1f s left", $0.timeIntervalSinceNow) } ?? "paused"), recording \(self.recorder.isRecording)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + lead + 1.2) {
                Log.info("record test \(name(index)): counting down \(self.staging), recording \(self.recorder.isRecording), prompting \(self.prompter.phase)")
                self.prompter.perform(.clickerForward)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + lead + 3.4) {
                if self.prompter.isActive { self.prompter.stop() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + lead + 5.2) {
                let take = self.recorder.take
                takes.append((name(index), take != before ? take : nil))
                Log.info("record test \(name(index)): finished → \(take != before ? take?.lastPathComponent ?? "-" : "nothing new"), problem \(self.recorder.problem.map { "\($0)" } ?? "none"), bubble \(self.recorder.bubble.window?.isVisible == true ? "still showing" : "hidden")")
                self.recorder.dismiss()
                run(index + 1)
            }
        }
        // 没有屏幕录制权限时按播放：不开始，出卡片；卡片、系统设置旁的小卡片画出来看
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            ScreenCapture.testDenied = true
            self.setShot(.both)
            self.play()
            Log.info("record test permission: card \(self.screenPermission.map { "\($0)" } ?? "none"), prompting \(self.prompter.isActive), recording \(self.recorder.isRecording)")
            for (suffix, step) in [("-perm-ask", ScreenPermissionStep.ask), ("-perm-wait", .waiting(since: Date().addingTimeInterval(-10)))] {
                let renderer = ImageRenderer(content: ScreenPermissionCard(model: self, step: step).frame(width: 520, height: 420))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: file(suffix))
                }
            }
            self.permissionHelper.show()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.frame.width >= 300 && $0.level == .floating }),
               let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: file("-perm-helper"))
                Log.info("record test permission: helper \(Int(panel.frame.width))x\(Int(panel.frame.height)) at \(Int(panel.frame.minX)),\(Int(panel.frame.minY))")
            }
            self.permissionHelper.close()
            ScreenCapture.testDenied = false
            withAnimation { self.screenPermission = nil }
        }
        // 画面面板单独画出来看（玻璃画不出来，背景垫一块灰）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let pieces = ShotPanel(model: self, prefs: self.prefs, close: {})
                .padding(24)
                .background(Color(white: 0.86))
            let renderer = ImageRenderer(content: pieces)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: file("-panel"))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { run(0) }
    }

    fileprivate func sidebarClickTest() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = mainWindow, let table = window.contentView?.superview?.allDescendants(of: NSTableView.self).first
                ?? window.contentView?.allDescendants(of: NSTableView.self).first else {
            Log.info("sidebar click test: no list")
            return
        }
        window.makeKeyAndOrderFront(nil)
        func click(row: Int, count: Int) {
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            for n in 1...count {
                let time = ProcessInfo.processInfo.systemUptime
                guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1),
                      let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.05,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 0) else { return }
                NSApp.postEvent(up, atStart: false)
                window.sendEvent(down)
            }
        }
        func name() -> String { document?.title ?? "-" }
        Log.info("sidebar click test: \(table.numberOfRows) rows, selected “\(name())”")
        var steps: [(Double, () -> Void)] = []
        for row in [2, 1, 3, 1] where row < table.numberOfRows {
            let i = Double(steps.count / 2)
            steps.append((i * 0.6 + 0.2, { click(row: row, count: 1) }))
            steps.append((i * 0.6 + 0.5, { Log.info("sidebar click test: clicked row \(row) (\(Int(table.rect(ofRow: row).height)) tall) → table row \(table.selectedRow), “\(name())”, renaming \(self.renaming != nil), key \(window.isKeyWindow)") }))
        }
        let base = Double(steps.count / 2) * 0.6 + 0.4
        steps.append((base, { click(row: 1, count: 2) }))
        steps.append((base + 0.6, {
            Log.info("sidebar click test: double-clicked row 1 → “\(name())”, renaming \(self.renaming.map { self.store[$0]?.title ?? "?" } ?? "no")")
            self.renaming = nil
        }))
        for (delay, action) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) }
    }

    /// 测试临时改了的设置（测完改回去）。
    fileprivate var testPrefs: (mode: PromptMode, countdown: Bool, record: Bool, autoTurn: Bool)? {
        get { AppModel.testPrefsStore }
        set { AppModel.testPrefsStore = newValue }
    }
    fileprivate static var testPrefsStore: (mode: PromptMode, countdown: Bool, record: Bool, autoTurn: Bool)?

    /// 装作按了一下键（走跟真按键一样的路：键盘监听）。
    fileprivate func press(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") {
        let window = NSApp.keyWindow ?? mainWindow
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }
        NSApp.sendEvent(event)
    }

    /// 把主窗口画成图片。
    fileprivate func shootWindow(to url: URL) {
        guard let window = mainWindow,
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

extension NSView {
    /// 子视图里第一个这种类型的（测试用）。
    func allDescendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + subviews.flatMap { $0.allDescendants(of: type) }
    }

    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for child in subviews {
            if let match = child as? T ?? child.firstDescendant(of: type) { return match }
        }
        return nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
