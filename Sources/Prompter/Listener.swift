import AVFoundation
import Speech

// MARK: - 听
//
// 麦克风一直开着量音量（判断你是不是在说话）；跟读模式下同时做语音识别。
// 识别任务隔一阵子、或者识别出错、或者位置被手动改了，就重新开一个：
// 新任务的文字从头算，旧任务迟到的结果按 generation 丢掉。

final class Listener {
    enum State: Equatable {
        case off, starting, listening
        /// 只量音量，不识别（匀速跟声音的模式，或者识别用不了）。
        case metering
        case micDenied, speechDenied, speechUnavailable, noInput
    }

    var onText: ((String) -> Void)?
    /// 0…1，大约每秒 30 次。
    var onLevel: ((Float) -> Void)?
    var onState: ((State) -> Void)?
    /// 新的识别任务开始了，之前的文字不再算数。
    var onSegment: (() -> Void)?

    private(set) var state: State = .off {
        didSet {
            if state != oldValue {
                Log.info("listener state \(state)")
                onState?(state)
            }
        }
    }

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let requestLock = NSLock()
    private var generation = 0
    private var running = false
    private var recognize = false
    private var preferOnDevice = true
    private var contextual: [String] = []
    private var restartTimer: Timer?
    private var failures: [Date] = []
    private var taskStarted = Date()
    private var lastLevelAt: CFTimeInterval = 0
    private var configObserver: NSObjectProtocol?
    private var tapInstalled = false
    private var resultCount = 0

    deinit { stop() }

    func start(locale: Locale, recognize: Bool, contextual: [String]) {
        stop()
        running = true
        self.recognize = recognize
        self.contextual = contextual
        preferOnDevice = true
        failures = []
        state = .starting

        Listener.requestMicrophone { [weak self] granted in
            guard let self, self.running else { return }
            guard granted else {
                self.state = .micDenied
                return
            }
            guard recognize else {
                self.startEngine()
                return
            }
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    guard self.running else { return }
                    Log.info("speech auth \(status.rawValue) locale \(locale.identifier)")
                    if status == .authorized, let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable {
                        self.recognizer = recognizer
                        self.startEngine()
                        self.beginTask()
                    } else {
                        self.recognize = false
                        self.startEngine()
                        if self.state == .metering {
                            self.state = status == .authorized ? .speechUnavailable : .speechDenied
                        }
                    }
                }
            }
        }
    }

    /// 重新开一个识别任务：之前说过的话不再参与比较。
    func restartTask() {
        guard running, recognize else { return }
        endTask()
        beginTask()
    }

    func stop() {
        running = false
        generation += 1
        restartTimer?.invalidate()
        restartTimer = nil
        endTask()
        // 没开过麦克风就别碰 inputNode：一碰系统就会去开输入设备。
        if tapInstalled {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        recognizer = nil
        state = .off
    }

    // MARK: 麦克风

    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { done(granted) } }
        default: done(false)
        }
    }

    private func startEngine() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        Log.info("input format \(format.sampleRate) Hz, \(format.channelCount) ch")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            state = .noInput
            return
        }
        input.removeTap(onBus: 0)
        tapInstalled = true
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.requestLock.lock()
            let request = self.request
            self.requestLock.unlock()
            request?.append(buffer)
            self.meter(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            state = recognize ? .listening : .metering
        } catch {
            Log.info("engine start failed: \(error)")
            state = .noInput
        }
        if configObserver == nil {
            // 换了麦克风（插上耳机之类）：整个重来。
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                    object: engine, queue: .main) { [weak self] _ in
                guard let self, self.running else { return }
                self.engine.stop()
                self.startEngine()
                self.restartTask()
            }
        }
    }

    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 0.000_001))
        let level = min(1, max(0, (db + 60) / 50))
        let now = CACurrentMediaTime()
        guard now - lastLevelAt > 1.0 / 30 else { return }
        lastLevelAt = now
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    // MARK: 识别

    private func beginTask() {
        guard running, recognize, let recognizer else { return }
        generation += 1
        let current = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = contextual
        request.addsPunctuation = false
        let onDevice = preferOnDevice && recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = onDevice
        Log.info("recognition task, on device \(onDevice)")
        requestLock.lock()
        self.request = request
        requestLock.unlock()
        taskStarted = Date()
        onSegment?()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.running, current == self.generation else { return }
                if let result {
                    self.resultCount += 1
                    if self.resultCount <= 6 || self.resultCount % 10 == 0 {
                        Log.info("heard …\(result.bestTranscription.formattedString.suffix(16))")
                    }
                    self.failures.removeAll()
                    self.onText?(result.bestTranscription.formattedString)
                    if result.isFinal {
                        self.restartTask()
                        return
                    }
                }
                if let error {
                    let ns = error as NSError
                    Log.info("recognition error \(ns.domain) \(ns.code) \(ns.localizedDescription)")
                    self.recover(onDevice: onDevice)
                }
            }
        }

        // 联网识别一次最多一分钟左右，提前换。
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: onDevice ? 240 : 50, repeats: false) { [weak self] _ in
            self?.restartTask()
        }
        if state == .metering || state == .starting { state = .listening }
    }

    private func endTask() {
        // 旧任务被取消时还会回调一次，换个 generation 让它被丢掉。
        generation += 1
        task?.cancel()
        task = nil
        requestLock.lock()
        request?.endAudio()
        request = nil
        requestLock.unlock()
    }

    private func recover(onDevice: Bool) {
        let now = Date()
        // 一开始就失败：本机识别可能用不了，换成联网的试试。
        if onDevice && now.timeIntervalSince(taskStarted) < 1.5 { preferOnDevice = false }
        failures = failures.filter { now.timeIntervalSince($0) < 15 } + [now]
        endTask()
        if failures.count > 8 {
            recognize = false
            state = .speechUnavailable
            return
        }
        let delay = min(0.2 * Double(failures.count), 1.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.recognize, self.task == nil else { return }
            self.beginTask()
        }
    }
}
