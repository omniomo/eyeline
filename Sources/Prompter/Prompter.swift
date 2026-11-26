import AppKit
import Combine

// MARK: - 提词
//
// 一次提词从按下播放开始，到按 ⌥Esc、或者念完自动收起为止。
// 位置用「第几个词」表示，可以带小数：提词条把它换成横向的位置，再平滑地滑过去。
//
// - 跟读：位置 = 识别对上的位置 + 一点点预测（你在说话时，按你的语速往前多走最多两三个字，
//   抵掉识别的延迟，字就是连续地流，而不是一顿一顿地跳）。
// - 跟声音：你说话时走，停下来它也停。打开「跟着我的语速」（默认）时，速度是你实际的语速：
//   识别出来的字每秒多几个（不管念的是不是稿子），就按这个速度走；还没量出来之前用设好的速度。
// - 匀速：按速度一直走，碰到 ⏸ 停一下。
// - 关键词：一次只给一个关键词（稿子里加粗的，或者每行一个），你看着它自己说；按 ⌥→ / 翻页笔换下一个，
//   写了 ⏱ 时长的到时间自己换。提词条用的是由关键词拼成的一份小稿子，位置还是「第几个词」，
//   和编辑器对位置时换回原文（documentOffset）。

final class Prompter: ObservableObject {
    enum Phase: Equatable { case idle, countdown, running, paused, finished }

    @Published private(set) var phase: Phase = .idle
    /// 念到第几个词了（给编辑器标进度；变了才发）。
    @Published private(set) var spoken = 0
    @Published private(set) var listenState: Listener.State = .off
    @Published private(set) var documentID: UUID?
    /// 这一次实际用的模式：麦克风或识别用不了时会退一步。
    @Published private(set) var activeMode: PromptMode = .follow
    /// 麦克风或语音识别没有授权：主窗口里提示去系统设置打开。下次开始前一直留着。
    @Published private(set) var permissionIssue: Listener.State?

    private(set) var script = Script(text: "")
    /// 这一次提词的稿子（关键词模式和别的模式之间切换时要重新拆）。
    private var document: ScriptDocument?
    /// 关键词模式：这份稿子的关键词，和每个关键词在 script 里从第几个词开始。
    private(set) var cues = Cues(text: "")
    private var cueStarts: [Int] = []
    /// 现在在第几个关键词、在它这里停了多久。
    private(set) var cueIndex = 0
    private(set) var cueElapsed: TimeInterval = 0
    /// 跟声音：量出来的语速（每秒几个字 / 词），0 是还没量出来。
    private(set) var paceRate: Double = 0
    private var heardCount = 0
    private var heardAt: CFTimeInterval = 0
    /// 稿子里的「## 第 N 页」（原文位置）。有的话提词时跟着 Keynote / PowerPoint 翻页。
    private(set) var pages: [Script.Page] = []
    private let slides = SlideWatcher()
    /// 系统设置里没让 Eyeline 控制 Keynote / PowerPoint：主窗口里提示。
    @Published private(set) var slidesDenied = false
    /// 稿子配的幻灯片（主窗口里稿子上面那个）。有的话翻页笔翻它，提词跟着它翻到的页走。
    weak var deck: SlideDeck?
    /// 这一次提词由 Eyeline 自己的幻灯片带着翻页（见 pageLimit）。
    private var ownSlides = false
    /// 停在哪一页的末尾等翻页（只记一次日志）。
    private var heldAtPage: Int?
    /// 自动翻页：念到这一页末尾的时刻（停一下再翻，最后几个字有时间念完）。
    private var reachedPageEndAt: CFTimeInterval = 0

    /// 念完这一页的话、停了一小会：自动翻到下一页（设置里能关）。这一页没写话就不自动翻。
    private func turnPageIfFinished(now: CFTimeInterval) {
        guard ownSlides, prefs.autoTurnSlides, phase == .running, !scrubbing, let deck, deck.isLoaded,
              pages.contains(where: { $0.number == deck.page }), let limit = pageLimit, base >= limit - 0.02 else {
            reachedPageEndAt = 0
            return
        }
        if reachedPageEndAt == 0 {
            reachedPageEndAt = now
        } else if now - reachedPageEndAt > 0.8 {
            reachedPageEndAt = 0
            Log.info("slides: finished slide \(deck.page), turning the page")
            deck.step(1)
        }
    }

    /// 提词条上的页码：这一次是 Eyeline 自己的幻灯片带着翻页时才有。
    var slideCounter: (page: Int, count: Int)? {
        guard ownSlides, let deck, deck.isLoaded else { return nil }
        return (deck.page, deck.pageCount)
    }

    /// 有幻灯片时，提词最多走到当前这一页的话的末尾：没翻页就停在那儿等，不自己滚到下一页。
    /// 翻页（← →、翻页笔、点幻灯片）才接着往下。这一页没话说：原地不动。nil：不限。
    private var pageLimit: Double? {
        guard ownSlides, let deck, deck.isLoaded else { return nil }
        let current = deck.page
        guard pages.contains(where: { $0.number == current }) else { return base }
        guard let next = pages.first(where: { $0.number > current }) else { return nil }
        // 停在这一页最后一个字上（不是下一页的第一个字），提词条不会滚到下一页
        return max(0, Double(script.token(atRaw: next.raw)) - 0.01)
    }

    /// 提词条上只显示这一页的话：这一页最后一个词是第几个（有幻灯片带着翻页时）。nil：都显示。
    /// 停在这一页末尾等翻页的时候，下一页的话不会先挤到摄像头旁边来，像是还在往下走。
    var pageLastToken: Int? {
        guard let limit = pageLimit else { return nil }
        return Int((limit + 0.011).rounded(.down)) - 1
    }

    /// 走到 limit 就停住；第一次停住时记一笔。
    private func clamp(_ value: Double) -> Double {
        guard let limit = pageLimit, value > limit else { return value }
        if heldAtPage != deck?.page {
            heldAtPage = deck?.page
            Log.info("slides: holding at the end of slide \(deck?.page ?? 0) until the page is turned")
        }
        return max(base, limit)
    }
    private var tracker = Tracker(script: Script(text: ""))
    private let listener = Listener()
    let prefs = Preferences.shared
    var ribbon: RibbonController?
    /// 结束时告诉外面：哪份稿子、下次从原文哪里接着念。
    var onStop: ((UUID, Int) -> Void)?

    /// 提词条告诉我每个词占多宽：匀速模式按像素匀速走，字流过去的速度才是均匀的。
    struct Metrics {
        var average: CGFloat
        var advance: (Int) -> CGFloat
    }
    var metrics: Metrics?

    /// 提词条要显示的位置。
    private(set) var target: Double = 0
    private var base: Double = 0
    private var lead: Double = 0
    private var rate: Double = 4
    private var lastConfirm: CFTimeInterval = 0
    private var hold: TimeInterval = 0
    private var countdownEnd: CFTimeInterval = 0
    private var finishedAt: CFTimeInterval = 0
    private var lastLoud: CFTimeInterval = -10
    private var noiseFloor: Float = 0.15
    private(set) var level: Float = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var scrubbing = false

    private struct Notice {
        var text: String
        var until: CFTimeInterval
    }
    private var notice: Notice?
    /// 跟读开始后还没听到、对上第一个字：提示「开始念吧」，不然看着像卡住了。
    private(set) var waitingForVoice = false

    var isActive: Bool { phase != .idle }
    var progress: Double { script.isEmpty ? 0 : min(1, base / Double(script.count)) }

    // MARK: 开始、结束

    /// 下一次开始不倒数（录屏前已经倒数过了）。
    var skipCountdownOnce = false

    /// 录屏前的倒数：提词条先出来、停在第一句，倒数的数字在提词条左边；等 release() 才开始走（真的开始录了）。
    private(set) var held = false

    /// 倒数到什么时候（nil：停着，正在挪人像）。只是给提词条显示数字。
    func hold(until end: CFTimeInterval?) {
        guard held else { return }
        countdownEnd = end ?? .infinity
    }

    /// 倒数完、开始录了：开始走（要听的现在才开麦克风）。
    func release() {
        guard held, isActive else { return }
        held = false
        begin(initial: false)
    }

    /// held：录屏前先把提词条摆出来，不走（见 hold / release）。
    func start(_ document: ScriptDocument, fromRaw offset: Int, held: Bool = false) {
        guard !Script(text: document.text, skipCuts: prefs.skipCuts).isEmpty else { return }
        if isActive { stop() }

        documentID = document.id
        activeMode = prefs.mode
        guard load(document, fromRaw: offset) else { return }
        elapsed = 0
        notice = nil
        permissionIssue = nil

        Log.info("start \(activeMode) at token \(Int(base)) of \(script.count)")
        defer { skipCountdownOnce = false }
        Hotkeys.shared.handler = { [weak self] action in self?.perform(action) }
        // 稿子配了幻灯片：翻页笔翻它（见 perform），提词跟着它翻到的页走，从念的那一页开始。
        // 没配：跟着 Keynote / PowerPoint 翻页，翻页笔留给它们，Eyeline 只跟着页码走。
        ownSlides = deck?.isLoaded == true && !pages.isEmpty
        heldAtPage = nil
        let followSlides = !pages.isEmpty && !ownSlides && SlideWatcher.presentationAppRunning
        Hotkeys.shared.enable(clicker: !followSlides)
        if ownSlides, let page = pages.last(where: { $0.raw <= offset }) {
            deck?.go(to: page.number)
        } else if !pages.isEmpty && !ownSlides {
            slidesDenied = false
            slides.onSlide = { [weak self] number in self?.goToPage(number) }
            slides.onDenied = { [weak self] in self?.slidesDenied = true }
            slides.start()
        }
        self.held = held
        begin(initial: true)
        ribbon?.show(self)
    }

    /// 按 activeMode 把稿子拆好（关键词模式拆成关键词），放到原文 offset 处。没有可念的就返回 false。
    @discardableResult
    private func load(_ document: ScriptDocument, fromRaw offset: Int) -> Bool {
        self.document = document
        var first: Int
        if activeMode == .keywords {
            let cues = Cues(text: document.text, skipCuts: prefs.skipCuts)
            guard !cues.isEmpty else { return false }
            self.cues = cues
            script = Script(text: cues.items.map(\.text).joined(separator: "\n"))
            var starts: [Int] = []
            var at = 0
            for cue in cues.items {
                starts.append(at)
                at += Script(text: cue.text).count
            }
            cueStarts = starts
            cueIndex = cues.index(atRaw: offset)
            cueElapsed = 0
            first = cueStarts[cueIndex]
        } else {
            let script = Script(text: document.text, skipCuts: prefs.skipCuts)
            guard !script.isEmpty else { return false }
            self.script = script
            cues = Cues(text: "")
            cueStarts = []
            first = script.token(atRaw: offset)
            if first >= script.count { first = 0 }
        }
        tracker = Tracker(script: script, position: first)
        base = Double(first)
        target = base
        lead = 0
        hold = 0
        finishedAt = 0
        rate = script.isCJK ? 4.2 : 2.4
        spoken = first
        waitingForVoice = activeMode.listens
        paceRate = 0
        heardCount = 0
        heardAt = 0
        // 一页一段的稿子：空一行翻一页（没话说的页不算）；以前那种：「## 第 N 页」。
        pages = document.isPaged
            ? PagedScript(text: document.text).pages.filter { $0.range.length > 0 }.map { Script.Page(number: $0.number, raw: $0.range.location) }
            : Script(text: document.text, skipCuts: prefs.skipCuts).pages
        return true
    }

    /// 第 t 个词在编辑器原文里的位置。关键词模式下是那个关键词在原文里的位置。
    func documentOffset(ofToken t: Int) -> Int {
        guard activeMode == .keywords, !cueStarts.isEmpty else { return script.rawOffset(ofToken: t) }
        if t >= script.count { return (document?.text as NSString?)?.length ?? 0 }
        return cues.items[cue(containing: t)].raw
    }

    /// 第 t 个词在第几个关键词里。
    private func cue(containing t: Int) -> Int {
        var index = 0
        for (i, start) in cueStarts.enumerated() where start <= t { index = i }
        return index
    }

    /// 关键词模式：现在这个关键词在 script 里的范围（给提词条把它整个点亮）。
    var cueSpan: Range<Int>? {
        guard activeMode == .keywords, cueIndex < cueStarts.count, phase != .finished, base < Double(script.count) else { return nil }
        let end = cueIndex + 1 < cueStarts.count ? cueStarts[cueIndex + 1] : script.count
        return cueStarts[cueIndex]..<end
    }

    func stop() {
        guard isActive else { return }
        listener.stop()
        slides.stop()
        Hotkeys.shared.disable()
        let token = Int(base.rounded(.down))
        let resume = token >= script.count ? 0 : documentOffset(ofToken: token)
        if let documentID { onStop?(documentID, resume) }
        ownSlides = false
        held = false
        phase = .idle
        listenState = .off
        ribbon?.hide()
    }

    /// 按当前模式开始走。
    private func begin(initial: Bool) {
        listener.stop()
        lead = 0
        if held {
            phase = .countdown
            countdownEnd = .infinity
            return
        }
        switch activeMode {
        case .follow, .pace:
            phase = .running
            listen(recognize: activeMode == .follow || (activeMode == .pace && prefs.adaptivePace))
        case .steady:
            if initial && prefs.countdown && !skipCountdownOnce {
                phase = .countdown
                countdownEnd = CACurrentMediaTime() + 3
            } else {
                phase = .running
            }
        case .keywords:
            // 不听、不倒数：关键词一出来就是你开口的时候
            phase = .running
        }
    }

    private func listen(recognize: Bool) {
        listener.onText = { [weak self] text in self?.heard(text) }
        listener.onLevel = { [weak self] level in self?.heardLevel(level) }
        listener.onState = { [weak self] state in self?.listenerChanged(state) }
        listener.onSegment = { [weak self] in self?.tracker.newSegment() }
        // 跟声音只拿识别来量语速，用不着告诉它稿子里的词；
        // 跟读才要（产品名之类认得更准）。
        let words = activeMode == .follow ? contextualWords() : []
        listener.start(locale: prefs.language.locale(for: script), recognize: recognize, contextual: words)
    }

    /// 稿子里的英文词（产品名之类）告诉识别器，认得更准。
    private func contextualWords() -> [String] {
        var seen = Set<String>()
        var words: [String] = []
        let display = script.display as NSString
        for token in script.tokens where token.unit.isWord && token.unit.key.count >= 3 {
            if seen.insert(token.unit.key).inserted { words.append(display.substring(with: token.range)) }
            if words.count >= 60 { break }
        }
        return words
    }

    private func listenerChanged(_ state: Listener.State) {
        listenState = state
        guard isActive else { return }
        if state == .micDenied || state == .speechDenied { permissionIssue = state }
        switch state {
        case .micDenied, .noInput:
            show(state == .micDenied ? String(localized: "Microphone is off — scrolling steadily")
                                     : String(localized: "No microphone — scrolling steadily"), for: 4)
            activeMode = .steady
            listener.stop()
        case .speechDenied, .speechUnavailable:
            if activeMode == .follow {
                show(String(localized: "Can’t follow words — moving while you talk"), for: 4)
                activeMode = .pace
            }
        default:
            break
        }
    }

    // MARK: 听到的

    private func heard(_ text: String) {
        if activeMode == .pace {
            measurePace(text)
            return
        }
        // 暂停时也接着听：你接着往下念稿子，就自动继续（暂停只是为了让你说稿子以外的话）。
        guard activeMode == .follow, phase == .running || phase == .paused, !scrubbing else {
            Log.info("ignored text: mode \(activeMode) phase \(phase) scrubbing \(scrubbing)")
            return
        }
        guard let position = tracker.hear(text) else { return }
        Log.info("matched → \(position)\(phase == .paused ? " (resumes)" : "")")
        if phase == .paused {
            phase = .running
            notice = nil
        }
        let now = CACurrentMediaTime()
        let new = clamp(Double(position))
        if new > base {
            let step = new - base
            let interval = now - lastConfirm
            if interval > 0.12 && interval < 2.5 && step < 14 {
                rate = min(9, max(1.2, rate * 0.7 + step / interval * 0.3))
            }
            lead = max(0, lead - step)
        } else {
            lead = 0
        }
        base = new
        lastConfirm = now
        finishedAt = 0
        waitingForVoice = false
        updateSpoken()
    }

    /// 跟声音：识别出来的字每秒多几个，就是你现在说话的速度（念的是不是稿子都算）。
    private func measurePace(_ text: String) {
        let count = Script(text: text).count
        let now = CACurrentMediaTime()
        defer {
            heardCount = count
            heardAt = now
        }
        // 识别开了新的一段（停顿之后），字数从头数：这一次只记下来，不算
        guard heardAt > 0, count > heardCount else { return }
        // 隔得太久的不算：中间停过，停顿不该把语速拉慢
        let dt = now - heardAt
        guard dt > 0.08, dt < 1.5 else { return }
        let measured = Double(count - heardCount) / dt
        paceRate = min(9, max(1.5, paceRate == 0 ? measured : paceRate * 0.8 + measured * 0.2))
    }

    private var levelLog: CFTimeInterval = 0

    private func heardLevel(_ level: Float) {
        self.level = level
        let now = CACurrentMediaTime()
        if now - levelLog > 3 {
            levelLog = now
            Log.info(String(format: "level %.2f floor %.2f talking %@", level, noiseFloor, isTalking ? "yes" : "no"))
        }
        if level < noiseFloor {
            noiseFloor = noiseFloor * 0.8 + level * 0.2
        } else {
            noiseFloor = min(0.6, noiseFloor + (level - noiseFloor) * 0.002)
        }
        if level > max(0.25, noiseFloor + 0.12) { lastLoud = CACurrentMediaTime() }
    }

    var isTalking: Bool { CACurrentMediaTime() - lastLoud < 0.4 }

    // MARK: 每一帧

    /// 提词条每一帧调一次。
    func tick(now: CFTimeInterval, dt: Double) {
        guard isActive else { return }
        if let notice, now > notice.until { self.notice = nil }
        let end = Double(script.count)
        switch phase {
        case .countdown:
            if !held, now >= countdownEnd { phase = .running }
        case .running where !scrubbing:
            elapsed += dt
            switch activeMode {
            case .follow:
                if isTalking { lead = min(lead + rate * dt, min(2.5, rate * 0.45)) }
            case .pace:
                if isTalking {
                    waitingForVoice = false
                    advance(dt)
                }
            case .steady:
                advance(dt)
            case .keywords:
                cueElapsed += dt
                if let limit = cues.items[safe: cueIndex]?.seconds, cueElapsed >= limit {
                    let next = cueStarts[safe: cueIndex + 1].map(Double.init) ?? Double(script.count)
                    if next <= (pageLimit ?? .infinity) {
                        goToCue(cueIndex + 1)
                    } else if ownSlides, prefs.autoTurnSlides, let deck, deck.page < deck.pageCount {
                        // 这一页的最后一个关键词到时间了：翻页
                        deck.step(1)
                    }
                }
            }
            if base >= end - 0.001 {
                if finishedAt == 0 { finishedAt = now }
                if now - finishedAt > 0.9 {
                    phase = .finished
                    finishedAt = now
                }
            }
        case .finished:
            if now - finishedAt > 1.6 { stop() }
        default:
            break
        }
        if activeMode != .keywords { turnPageIfFinished(now: now) }
        target = min(end, pageLimit.map { max(base, $0) } ?? end, base + (activeMode == .follow && phase == .running ? lead : 0))
    }

    private func advance(_ dt: Double) {
        if hold > 0 {
            hold -= dt
            return
        }
        let end = min(Double(script.count), pageLimit.map { max(base, $0) } ?? .infinity)
        guard base < end else {
            _ = clamp(base + 1)
            return
        }
        let perSecond = activeMode == .pace && prefs.adaptivePace && paceRate > 0 ? paceRate : prefs.speed(for: script) / 60
        guard let metrics, metrics.average > 0 else {
            base = min(end, base + perSecond * dt)
            updateSpoken()
            return
        }
        // 这一帧要走的像素；按像素平均分配，长的备注（不用念的）走得快一点。
        let average = Double(metrics.average)
        var budget = average * perSecond * dt
        while budget > 0 && base < end {
            let before = base
            let index = Int(base.rounded(.down))
            let cost = min(max(1, Double(metrics.advance(index))), average * 2.5)
            let need = (Double(index + 1) - base) * cost
            if budget < need {
                base = min(end, base + budget / cost)
                budget = 0
            } else {
                budget -= need
                base = min(end, Double(index + 1))
                if base <= before { break }
                if prefs.holdAtPauses, let pauses = script.pauses[index + 1], pauses > 0 {
                    hold = Script.pauseSeconds * Double(pauses)
                    break
                }
            }
        }
        updateSpoken()
    }

    private func updateSpoken() {
        let value = Int(base.rounded(.down))
        if value != spoken { spoken = value }
    }

    // MARK: 控制

    /// 录屏前倒数的时候按了暂停（空格、⌥空格）：意思是「马上开始」。
    var onStartNow: (() -> Void)?

    func perform(_ action: HotkeyAction) {
        switch action {
        case .pause where held: onStartNow?()
        case .pause: togglePause()
        case .back: step(-1)
        case .forward: step(1)
        case .clickerBack, .clickerForward:
            let delta = action == .clickerBack ? -1 : 1
            if let deck, deck.isLoaded, !pages.isEmpty { deck.step(delta) } else { step(delta) }
        case .faster: changeSpeed(1)
        case .slower: changeSpeed(-1)
        case .bigger: changeSize(1)
        case .smaller: changeSize(-1)
        case .stop: stop()
        }
    }

    /// 还在等你开口：提词条上显示一个跟着声音跳的小声波。
    var isWaitingForVoice: Bool { waitingForVoice && phase == .running && activeMode.listens && notice == nil }
    /// 等你开口时被点了一下：声波跳一下，告诉你直接念就行。
    private(set) var nudgedAt: CFTimeInterval = 0

    /// 在提词条上点了一下。还在等你开口的时候，点它不是想暂停，是不知道该干嘛。
    func clicked() {
        if isWaitingForVoice {
            nudgedAt = CACurrentMediaTime()
            return
        }
        togglePause()
    }

    func togglePause() {
        switch phase {
        case .running, .countdown:
            phase = .paused
        case .paused:
            phase = .running
            notice = nil
            resync()
        case .finished:
            jump(to: 0)
            phase = .running
            resync()
        case .idle:
            break
        }
    }

    /// 往前、往后一句。往回按：这句已经念了一点就回到这句开头，否则回到上一句。
    func step(_ direction: Int) {
        guard !script.isEmpty else { return }
        if activeMode == .keywords {
            // 关键词：上一个、下一个。最后一个之后就是念完了。
            if phase == .finished && direction < 0 { phase = .paused }
            goToCue(phase == .finished ? cues.count - 1 : cueIndex + direction)
            return
        }
        let current = Int(base.rounded(.down))
        let sentence = script.sentence(ofToken: current)
        if direction < 0 {
            let first = script.sentences[sentence].firstToken
            jump(to: base - Double(first) > 1.5 || sentence == 0 ? first : script.sentences[sentence - 1].firstToken)
        } else {
            jump(to: sentence + 1 < script.sentences.count ? script.sentences[sentence + 1].firstToken : script.count)
        }
    }

    func jump(to token: Int) {
        if activeMode == .keywords && !cueStarts.isEmpty {
            // 双击、拖完：落到那个词所在的关键词上
            if phase == .finished { phase = .paused }
            goToCue(token >= script.count ? cues.count : cue(containing: token))
            return
        }
        base = Double(min(max(0, token), script.count))
        lead = 0
        hold = 0
        finishedAt = 0
        if phase == .finished { phase = .paused }
        resync()
        updateSpoken()
    }

    /// 关键词模式：换到第 index 个关键词，它的计时从零开始。超出最后一个就是念完了。
    private func goToCue(_ index: Int) {
        guard !cueStarts.isEmpty else { return }
        lead = 0
        hold = 0
        cueElapsed = 0
        if index >= cueStarts.count {
            cueIndex = cueStarts.count - 1
            base = Double(script.count)
        } else {
            cueIndex = max(0, index)
            base = Double(cueStarts[cueIndex])
            finishedAt = 0
        }
        updateSpoken()
    }

    /// 翻到第 number 页：跳到稿子里这一页的开头（关键词模式下是这一页的第一个关键词）。
    func goToPage(_ number: Int) {
        guard isActive, let page = pages.first(where: { $0.number == number }) else { return }
        if activeMode == .keywords {
            goToCue(cues.items.firstIndex(where: { $0.raw >= page.raw }) ?? cueIndex)
        } else {
            jump(to: script.token(atRaw: page.raw))
        }
        if phase == .finished { phase = .paused }
        show(String(localized: "Slide \(number)"), for: 1.2)
    }

    /// 拖动、滚动提词条：位置跟着手走。
    func scrub(to position: Double) {
        scrubbing = true
        base = min(max(0, position), Double(script.count))
        target = base
        lead = 0
        hold = 0
        if phase == .finished { phase = .paused }
        updateSpoken()
    }

    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        jump(to: Int(base.rounded()))
    }

    /// 位置被手动改了：识别从这里重新对。
    private func resync() {
        tracker.reset(to: Int(base.rounded(.down)))
        if activeMode == .follow, phase == .running { listener.restartTask() }
    }

    func changeSpeed(_ direction: Int) {
        guard activeMode == .steady || (activeMode == .pace && !prefs.adaptivePace) else {
            switch activeMode {
            case .keywords: show(String(localized: "Next keyword  ⌥→"), for: 1.4)
            case .pace: show(String(localized: "Matching your speaking speed"), for: 1.4)
            default: show(String(localized: "Following your voice"), for: 1.4)
            }
            return
        }
        let unit = script.isCJK ? 20.0 : 10.0
        let current = (prefs.speed(for: script) / unit).rounded() * unit
        prefs.setSpeed(current + Double(direction) * unit, for: script)
        show(speedText, for: 1.4)
    }

    var speedText: String {
        let value = Int(prefs.speed(for: script))
        return script.isCJK ? String(localized: "\(value) chars/min") : String(localized: "\(value) wpm")
    }

    func changeSize(_ direction: Int) {
        prefs.size = min(Preferences.sizeSteps - 1, max(0, prefs.size + direction))
        ribbon?.relayout()
    }

    /// 说话时滚动：跟随语速（听出来的快慢）/ 固定速度。正在这么走的话马上换。
    func setAdaptivePace(_ on: Bool) {
        guard prefs.adaptivePace != on else { return }
        prefs.adaptivePace = on
        guard isActive, activeMode == .pace else { return }
        let wasPaused = phase == .paused
        begin(initial: false)
        tracker.reset(to: Int(base.rounded(.down)))
        if wasPaused { phase = .paused }
    }

    func setMode(_ mode: PromptMode) {
        prefs.mode = mode
        guard isActive, mode != activeMode else { return }
        let wasPaused = phase == .paused
        if (mode == .keywords) != (activeMode == .keywords), let document {
            // 逐字和关键词之间切：重新拆稿子，停在同一个地方
            let offset = documentOffset(ofToken: Int(base.rounded(.down)))
            activeMode = mode
            load(document, fromRaw: offset)
            ribbon?.reload()
        } else {
            activeMode = mode
        }
        begin(initial: false)
        tracker.reset(to: Int(base.rounded(.down)))
        if wasPaused { phase = .paused }
        show(mode.title, for: 1.4)
    }

    private func show(_ text: String, for seconds: Double) {
        notice = Notice(text: text, until: CACurrentMediaTime() + seconds)
    }

    // MARK: 给提词条看的

    /// 提词条左边（摄像头左侧）显示的一小句状态。没有就是 nil。
    var status: String? {
        let now = CACurrentMediaTime()
        if phase == .countdown {
            // 录屏前的倒数停着（正在挪人像）：不显示数字
            guard countdownEnd.isFinite else { return nil }
            return "\(max(1, Int(ceil(countdownEnd - now))))"
        }
        if let notice { return notice.text }
        // 等你开口时不写字：提词条上画一个跟着声音跳的小声波（见 RibbonView）。
        if isWaitingForVoice { return nil }
        // 关键词：左边一直是在这个关键词上停了多久（写了时长就是「已经 / 一共」）。
        if activeMode == .keywords && phase == .running {
            let now = Prompter.clock(cueElapsed)
            if let limit = cues.items[safe: cueIndex]?.seconds { return now + " / " + Prompter.clock(limit) }
            return now
        }
        switch phase {
        case .paused: return "\u{2016}  " + Prompter.clock(elapsed) + "  ·  " + "\(Int(progress * 100))%"
        case .finished: return "\u{2713}  " + Prompter.clock(elapsed)
        default: return nil
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension PromptMode {
    var title: String {
        switch self {
        case .follow: return String(localized: "Follow my voice")
        case .pace: return String(localized: "Move while I talk")
        case .steady: return String(localized: "Steady scroll")
        case .keywords: return String(localized: "Keyword outline")
        }
    }

    var symbol: String {
        switch self {
        case .follow: return "mic"
        case .pace: return "waveform"
        case .steady: return "speedometer"
        case .keywords: return "list.bullet"
        }
    }
}
