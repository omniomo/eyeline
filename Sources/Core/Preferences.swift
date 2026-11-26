import Foundation
import Combine

/// 跟着走的方式。
enum PromptMode: String, CaseIterable, Identifiable {
    /// 不听，按速度匀速走。
    case steady
    /// 听你念到哪个字，就走到哪个字（默认）。
    case follow
    /// 你说话的时候匀速走，停下来它也停。
    case pace
    /// 一次只给一个关键词，你自己说；按键换下一个。
    case keywords

    var id: String { rawValue }
    var listens: Bool { self == .follow || self == .pace }
}

/// 识别用的语言。
enum SpeechLanguage: String, CaseIterable, Identifiable {
    case automatic, mandarin, taiwanese, cantonese, english, japanese
    var id: String { rawValue }

    func locale(for script: Script?) -> Locale {
        switch self {
        case .automatic: return Locale(identifier: (script?.isCJK ?? true) ? "zh-CN" : "en-US")
        case .mandarin: return Locale(identifier: "zh-CN")
        case .taiwanese: return Locale(identifier: "zh-TW")
        case .cantonese: return Locale(identifier: "zh-HK")
        case .english: return Locale(identifier: "en-US")
        case .japanese: return Locale(identifier: "ja-JP")
        }
    }
}

/// 提词条显示在哪块屏幕上。
enum RibbonDisplay: String, CaseIterable, Identifiable {
    /// 有摄像头的那块（MacBook 自己的屏幕）。
    case builtIn
    /// 菜单栏所在的主屏幕。
    case main
    var id: String { rawValue }
}

final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var mode: PromptMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var language: SpeechLanguage { didSet { defaults.set(language.rawValue, forKey: "language") } }
    @Published var display: RibbonDisplay { didSet { defaults.set(display.rawValue, forKey: "display") } }
    /// 0…4，越大字越大。
    @Published var size: Int { didSet { defaults.set(size, forKey: "size") } }
    /// 每分钟几个字（中日韩）。
    @Published var speedCJK: Double { didSet { defaults.set(speedCJK, forKey: "speedCJK") } }
    /// 每分钟几个词（拉丁字母）。
    @Published var speedWords: Double { didSet { defaults.set(speedWords, forKey: "speedWords") } }
    @Published var hideFromCapture: Bool { didSet { defaults.set(hideFromCapture, forKey: "hideFromCapture") } }
    @Published var skipCuts: Bool { didSet { defaults.set(skipCuts, forKey: "skipCuts") } }
    @Published var holdAtPauses: Bool { didSet { defaults.set(holdAtPauses, forKey: "holdAtPauses") } }
    @Published var countdown: Bool { didSet { defaults.set(countdown, forKey: "countdown") } }
    /// 配了幻灯片：念完一页的话自动翻到下一页（关掉就停在这一页末尾，等你翻）。
    @Published var autoTurnSlides: Bool { didSet { defaults.set(autoTurnSlides, forKey: "autoTurnSlides") } }
    /// 跟声音：按你实际说话的速度走（听出来的），不用自己设速度。
    @Published var adaptivePace: Bool { didSet { defaults.set(adaptivePace, forKey: "adaptivePace") } }
    /// 提词时同时录一条（关着就是「不录制」）。
    @Published var recordTakes: Bool { didSet { defaults.set(recordTakes, forKey: "recordTakes") } }
    /// 录什么：默认屏幕 + 圆框人像。底栏「画面」里改，会记住。
    @Published var recordLayout: RecordLayout { didSet { defaults.set(recordLayout.rawValue, forKey: "recordLayout") } }
    /// 放幻灯片时只录幻灯片那一块（默认录整块屏幕，幻灯片四周是白的）。
    @Published var recordSlideOnly: Bool { didSet { defaults.set(recordSlideOnly, forKey: "recordSlideOnly") } }
    /// 圆框人像的中心（在录的那块里，0…1，左上是原点）和直径（占那块短边的比例）：拖、捏合可以改。
    @Published var bubbleX: Double { didSet { defaults.set(bubbleX, forKey: "bubbleX") } }
    @Published var bubbleY: Double { didSet { defaults.set(bubbleY, forKey: "bubbleY") } }
    @Published var bubbleSize: Double { didSet { defaults.set(bubbleSize, forKey: "bubbleSize") } }
    /// 胶囊从摄像头往左、往右各伸出多远（以字号为单位）。拖胶囊的两头可以改。
    @Published var ribbonLeft: Double { didSet { defaults.set(ribbonLeft, forKey: "ribbonLeft") } }
    @Published var ribbonRight: Double { didSet { defaults.set(ribbonRight, forKey: "ribbonRight") } }
    /// 稿子配了幻灯片时，主窗口里在稿子上面显示幻灯片。
    @Published var showSlides: Bool { didSet { defaults.set(showSlides, forKey: "showSlides") } }
    /// 主窗口里的缩放（稿子的字、分镜表里的幻灯片）：⌘= ⌘- ⌘0，触控板捏合。
    @Published var zoom: Double { didSet { defaults.set(zoom, forKey: "zoom") } }
    /// 幻灯片占主窗口多高（0.2…0.7）。拖中间的分隔线可以改。
    @Published var slideStage: Double { didSet { defaults.set(slideStage, forKey: "slideStage") } }

    static let sizeSteps = 5

    private init() {
        // 默认跟着念的字走：念到哪走到哪，自由发挥时停着等，说回稿子再接着走。（以前默认匀速，这里换一次。）
        if !defaults.bool(forKey: "modeDefaultFollow") {
            defaults.set(true, forKey: "modeDefaultFollow")
            defaults.set(PromptMode.follow.rawValue, forKey: "mode")
        }
        mode = PromptMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .follow
        language = SpeechLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .automatic
        display = RibbonDisplay(rawValue: defaults.string(forKey: "display") ?? "") ?? .builtIn
        // 用 integer/double/bool(forKey:)：启动参数（-size 3）读进来是字符串，它们也认。
        func has(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) != nil }
        size = has("size") ? min(Preferences.sizeSteps - 1, max(0, defaults.integer(forKey: "size"))) : 2
        speedCJK = has("speedCJK") ? defaults.double(forKey: "speedCJK") : 260
        speedWords = has("speedWords") ? defaults.double(forKey: "speedWords") : 150
        hideFromCapture = has("hideFromCapture") ? defaults.bool(forKey: "hideFromCapture") : true
        skipCuts = has("skipCuts") ? defaults.bool(forKey: "skipCuts") : false
        holdAtPauses = has("holdAtPauses") ? defaults.bool(forKey: "holdAtPauses") : true
        countdown = has("countdown") ? defaults.bool(forKey: "countdown") : true
        adaptivePace = has("adaptivePace") ? defaults.bool(forKey: "adaptivePace") : true
        recordTakes = has("recordTakes") ? defaults.bool(forKey: "recordTakes") : true
        recordLayout = RecordLayout(rawValue: defaults.string(forKey: "recordLayout") ?? "") ?? .both
        recordSlideOnly = has("recordSlideOnly") ? defaults.bool(forKey: "recordSlideOnly") : false
        bubbleX = has("bubbleX") ? min(1, max(0, defaults.double(forKey: "bubbleX"))) : 0.9
        bubbleY = has("bubbleY") ? min(1, max(0, defaults.double(forKey: "bubbleY"))) : 0.85
        bubbleSize = has("bubbleSize") ? min(0.45, max(0.1, defaults.double(forKey: "bubbleSize"))) : 0.18
        ribbonLeft = has("ribbonLeft") ? defaults.double(forKey: "ribbonLeft") : 10
        ribbonRight = has("ribbonRight") ? defaults.double(forKey: "ribbonRight") : 21
        showSlides = has("showSlides") ? defaults.bool(forKey: "showSlides") : true
        zoom = has("zoom") ? min(2, max(0.6, defaults.double(forKey: "zoom"))) : 1
        autoTurnSlides = has("autoTurnSlides") ? defaults.bool(forKey: "autoTurnSlides") : true
        slideStage = has("slideStage") ? min(0.7, max(0.2, defaults.double(forKey: "slideStage"))) : 0.45
    }

    func speed(for script: Script?) -> Double {
        (script?.isCJK ?? true) ? speedCJK : speedWords
    }

    func setSpeed(_ value: Double, for script: Script?) {
        if script?.isCJK ?? true {
            speedCJK = min(600, max(60, value))
        } else {
            speedWords = min(320, max(40, value))
        }
    }

    // MARK: 缩放

    /// 设成多大（0.6 到 2 倍之间）。
    func setZoom(_ value: Double) {
        var value = min(2, max(0.6, value))
        if abs(value - 1) < 0.03 { value = 1 }
        if abs(value - zoom) > 0.001 { zoom = value }
    }

    /// 大一档（1）、小一档（-1）、回到原大（0）。
    func zoom(by step: Int) {
        setZoom(step == 0 ? 1 : zoom * (step > 0 ? 1.12 : 1 / 1.12))
    }
}
