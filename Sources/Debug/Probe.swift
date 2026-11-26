import AppKit
import Speech

// MARK: - 试听
//
// 开发用：拿一段录音（比如 `say` 合成的）走一遍「识别 → 跟读」，把每一步的位置写进文件。
//
//   Eyeline --probe 录音.aiff 稿子.txt 结果.txt [zh-CN]

enum Probe {
    private final class Run {
        var tracker: Tracker
        var log = ""
        let out: URL
        var task: SFSpeechRecognitionTask?
        init(tracker: Tracker, out: URL) {
            self.tracker = tracker
            self.out = out
        }
        func finish() {
            try? log.write(to: out, atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        }
    }

    private static var current: Run?
    /// 试听模式：不显示窗口，也不碰稿子库。
    static var isRunning: Bool { current != nil }

    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--probe"), index + 3 < arguments.count else { return false }
        let audio = URL(fileURLWithPath: arguments[index + 1])
        let scriptURL = URL(fileURLWithPath: arguments[index + 2])
        let out = URL(fileURLWithPath: arguments[index + 3])
        let locale = index + 4 < arguments.count ? arguments[index + 4] : "zh-CN"
        NSApp.windows.forEach { $0.orderOut(nil) }

        let text = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
        let script = Script(text: text)
        let run = Run(tracker: Tracker(script: script), out: out)
        current = run
        run.log += "tokens \(script.count) sentences \(script.sentences.map(\.firstToken))\n"

        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                run.log += "auth \(status.rawValue)\n"
                guard status == .authorized, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
                    run.finish()
                    return
                }
                let request = SFSpeechURLRecognitionRequest(url: audio)
                request.shouldReportPartialResults = true
                request.addsPunctuation = false
                request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
                request.contextualStrings = script.tokens.filter(\.unit.isWord).map { (script.display as NSString).substring(with: $0.range) }
                run.log += "onDevice \(recognizer.supportsOnDeviceRecognition)\n"
                run.task = recognizer.recognitionTask(with: request) { result, error in
                    DispatchQueue.main.async {
                        if let result {
                            let heard = result.bestTranscription.formattedString
                            let moved = run.tracker.hear(heard)
                            run.log += "\(moved.map(String.init) ?? "·")\t\(run.tracker.position)\t\(heard.suffix(28))\n"
                            if result.isFinal {
                                run.log += "final \(run.tracker.position)/\(script.count)\n"
                                run.finish()
                            }
                        } else if let error {
                            run.log += "error \(error.localizedDescription)\n"
                            run.finish()
                        }
                    }
                }
            }
        }
        return true
    }
}
