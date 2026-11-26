import AppKit

// MARK: - 跟着 Keynote / PowerPoint 翻页
//
// 稿子里有「## 第 N 页」的时候，提词时每 0.4 秒问一次开着的 Keynote（没有就问 PowerPoint）现在是第几页，
// 页数变了就把提词条跳到那一页。用 AppleScript：第一次会弹「允许 Eyeline 控制 Keynote」。
// 只问已经开着的 App，不会去把它们打开。这时候翻页笔留给 Keynote 翻页，Eyeline 只跟着页码走。

final class SlideWatcher {
    /// 翻到了第几页。
    var onSlide: ((Int) -> Void)?
    /// 系统设置里没让 Eyeline 控制 Keynote / PowerPoint。
    var onDenied: (() -> Void)?

    static let keynote = "com.apple.iWork.Keynote"
    static let powerpoint = "com.microsoft.Powerpoint"

    private var timer: Timer?
    private var last: Int?
    private var busy = false
    private var deniedReported = false
    private let queue = DispatchQueue(label: "com.omniomo.eyeline.slides")

    /// Keynote 或者 PowerPoint 开着。
    static var presentationAppRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { [keynote, powerpoint].contains($0.bundleIdentifier ?? "") }
    }

    func start() {
        stop()
        last = nil
        deniedReported = false
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !busy else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let source: String
        if running.contains(SlideWatcher.keynote) {
            source = SlideWatcher.keynoteSlide
        } else if running.contains(SlideWatcher.powerpoint) {
            source = SlideWatcher.powerpointSlide
        } else {
            return
        }
        busy = true
        queue.async { [weak self] in
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let number = Int(result?.int32Value ?? 0)
            let code = error?[NSAppleScript.errorNumber] as? Int
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if code == -1743, !self.deniedReported {
                    // errAEEventNotPermitted：没给「自动化」权限
                    self.deniedReported = true
                    Log.info("slides: not allowed to control the presentation app")
                    self.onDenied?()
                }
                guard number > 0, number != self.last else { return }
                self.last = number
                Log.info("slides: page \(number)")
                self.onSlide?(number)
            }
        }
    }

    private static let keynoteSlide = """
    tell application id "com.apple.iWork.Keynote"
        if (count of documents) is 0 then return 0
        return slide number of current slide of front document
    end tell
    """

    private static let powerpointSlide = """
    tell application id "com.microsoft.Powerpoint"
        if (count of slide show windows) is 0 then return 0
        return slide index of slide of slide show view of slide show window 1
    end tell
    """
}
