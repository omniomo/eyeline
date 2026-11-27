import AppKit
import AVFoundation
import Combine

// MARK: - 录一条
//
// 打开摄像头开关以后按播放：这时才开摄像头，真的开始录了提词条才出来，所以第一句不会漏；
// 结束（⌥Esc 或者念完），录像停、摄像头关，窗口里马上回放这一条，看看眼神是不是对着镜头。
// 不录的时候摄像头一直关着，不亮灯，窗口里也没有预览。
// 录好一条，窗口会自己到前面来回放它。视频存在「影片/Eyeline」里，左边稿子下面列着录过的每一条，
// 新的在最上面；还没看过的有个小蓝点。
// 用的是 MacBook 自己的摄像头：提词条就在它下面。
// 录屏幕（「屏幕」「屏幕 + 人像」）的时候换成 ScreenCapture + CompositeRecorder：录一块屏幕和麦克风，
// 人像是屏幕上的一个圆（CameraBubble），跟着屏幕录进去；提词条不录。

final class TakeRecorder: NSObject, ObservableObject {
    enum Problem: Equatable {
        case cameraDenied
        case screenDenied
        case noCamera
        case failed
    }

    /// 录过的一条。
    struct Take: Identifiable, Equatable {
        let url: URL
        let date: Date
        var id: URL { url }

        /// 文件名去掉最后的日期时间，就是那份稿子的标题。
        var title: String {
            let name = url.deletingPathExtension().lastPathComponent
            let title = name.replacingOccurrences(of: #"\s*\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}$"#, with: "",
                                                  options: .regularExpression)
            return title.isEmpty ? name : title
        }
    }

    /// 摄像头开着。
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    /// 正在窗口里回放的一条。
    @Published private(set) var take: URL?
    /// 「影片/Eyeline」里的每一条，新的在前。
    @Published private(set) var takes: [Take] = []
    /// 还没看过的（录完窗口不在前面、或者还没点开过）。
    @Published private(set) var unseen: Set<URL> = []
    @Published private(set) var problem: Problem?
    /// 录好了一条（已经在 take 里）。
    var onFinished: ((URL) -> Void)?
    private static let seenKey = "seenTakes"

    /// 录屏幕：屏幕的画面、麦克风，写成一个视频。
    let composite = CompositeRecorder()
    private let screen = ScreenCapture()
    /// 屏幕上的圆框人像。
    let bubble = CameraBubble()

    /// 录屏幕：录哪块（AppKit 全局坐标）、在哪块屏幕上；圆框人像放哪、多大（nil 是不要人像）；
    /// Eyeline 自己的窗口藏不藏（留下 keeping 里的）。
    struct ScreenShot {
        var region: CGRect
        var screen: NSScreen
        var bubble: (center: CGPoint, size: CGFloat)?
        var hideOwnWindows: Bool
        var keeping: [NSWindow]
    }
    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "com.omniomo.eyeline.camera")
    private var configured = false
    /// 正在录的文件：列表里先不放它。
    private var recordingURL: URL?
    /// 真的开始录了（或者录不了）以后要做的事：出提词条。
    private var onStarted: (() -> Void)?
    private var startSerial = 0

    override init() {
        super.init()
        refreshTakes()
    }

    /// 「影片/Eyeline」。`-takesFolder /路径` 换一个文件夹（测试用，不碰你录的）。
    static var folder: URL {
        if let path = UserDefaults.standard.string(forKey: "takesFolder") { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eyeline", isDirectory: true)
    }

    /// 打开摄像头开关时：先把摄像头和麦克风的权限问好，不开摄像头。
    func prepare() {
        problem = nil
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.problem = .cameraDenied
                    return
                }
                // 麦克风没给也照样录画面。
                Listener.requestMicrophone { _ in }
            }
        }
    }

    /// 关摄像头（正在录就先停）。
    func close() {
        queue.async {
            if self.output.isRecording { self.output.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    /// 录屏幕之前：先开镜头、把圆框放上屏幕（倒数的时候可以挪），还不录。
    func prepare(_ composition: Composition, shot: ScreenShot) {
        dismiss()
        problem = nil
        composite.prepare(composition)
        isRunning = composition.layout.needsCamera
        if let place = shot.bubble {
            bubble.show(session: composite.session, in: shot.region, center: place.center, size: place.size)
        }
    }

    /// 准备了又不录了。
    func cancelPreparation() {
        bubble.hide()
        composite.cancelPreparation()
        isRunning = false
    }

    /// 开摄像头、开始录。真的录上了再调用 started（这时候才出提词条）；录不了也会调用，提词照常。
    /// composition + shot：录屏幕；nil 是直接录摄像头。
    func startRecording(title: String, composition: Composition? = nil, shot: ScreenShot? = nil, started: @escaping () -> Void) {
        if composition != nil, !ScreenCapture.allowed {
            // 还没给「屏幕录制」权限（按播放时已经先看过一次，这里是保险）
            problem = .screenDenied
            started()
            return
        }
        let needsCamera = (composition?.layout.needsCamera ?? true) && !UserDefaults.standard.bool(forKey: "fakeCamera")
        switch needsCamera ? AVCaptureDevice.authorizationStatus(for: .video) : .authorized {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.startRecording(title: title, composition: composition, shot: shot, started: started)
                    } else {
                        self.problem = .cameraDenied
                        started()
                    }
                }
            }
            return
        default:
            problem = .cameraDenied
            started()
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = name.isEmpty ? "Eyeline" : String(name.prefix(40))
        let url = TakeRecorder.folder.appendingPathComponent("\(base) \(formatter.string(from: Date())).mov")
        try? FileManager.default.createDirectory(at: TakeRecorder.folder, withIntermediateDirectories: true)
        dismiss()
        problem = nil
        recordingURL = url
        onStarted = started
        startSerial += 1
        let serial = startSerial
        // 摄像头 4 秒还没开始录：不等了，先出提词条。
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if self.startSerial == serial { self.fireStarted() }
        }
        if let composition, let shot {
            isRecording = true
            isRunning = composition.layout.needsCamera
            composite.start(composition, to: url) { [weak self] in
                guard let self else { return }
                if !self.composite.isRecording {
                    // 写不了文件
                    self.screen.stop()
                    self.bubble.hide()
                    self.isRecording = false
                    self.isRunning = false
                    self.recordingURL = nil
                    self.problem = .failed
                }
                self.fireStarted()
            }
            // 先把圆框放到屏幕上（录屏时要留下它），再开始录屏幕；倒数时已经放好了就不动它
            if let place = shot.bubble, bubble.window?.isVisible != true {
                bubble.show(session: composite.session, in: shot.region, center: place.center, size: place.size)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard self.startSerial == serial, self.composite.isRecording else { return }
                var keeping = shot.keeping
                if shot.bubble != nil, let window = self.bubble.window { keeping.append(window) }
                let composite = self.composite
                self.screen.start(region: shot.region, on: shot.screen, hideOwnWindows: shot.hideOwnWindows, keeping: keeping,
                                  frame: { composite.update(content: $0) }) { error in
                    guard let error else { return }
                    Log.info("screen: can't capture \(error)")
                    self.screen.stop()
                    self.bubble.hide()
                    self.composite.stop(discard: true) { _ in }
                    self.isRecording = false
                    self.isRunning = false
                    self.recordingURL = nil
                    self.problem = ScreenCapture.allowed ? .failed : .screenDenied
                    self.fireStarted()
                }
            }
            return
        }
        queue.async {
            if !self.session.isRunning { self.run() }
            guard self.session.isRunning, !self.output.isRecording else {
                Log.info("can't record: running \(self.session.isRunning) recording \(self.output.isRecording)")
                DispatchQueue.main.async {
                    self.recordingURL = nil
                    self.fireStarted()
                }
                return
            }
            Log.info("recording to \(url.path)")
            self.output.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async { self.isRecording = true }
        }
    }

    func stopRecording() {
        if composite.isRecording {
            screen.stop()
            bubble.hide()
            composite.stop { [weak self] url in
                guard let self else { return }
                self.isRunning = false
                self.finished(url ?? self.recordingURL ?? URL(fileURLWithPath: "/"), ok: url != nil)
            }
            return
        }
        queue.async {
            if self.output.isRecording { self.output.stopRecording() }
        }
    }

    /// 录完了（直接录的、合成的都走这里）：列表里加上这一条，窗口里回放。
    private func finished(_ url: URL, ok: Bool) {
        isRecording = false
        recordingURL = nil
        refreshTakes()
        if ok {
            take = url
            onFinished?(url)
        } else {
            problem = .failed
        }
        fireStarted()
    }

    private func fireStarted() {
        let done = onStarted
        onStarted = nil
        done?()
    }

    // MARK: 录好的

    /// 重新看一遍「影片/Eyeline」里有哪些。
    func refreshTakes() {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: TakeRecorder.folder, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        takes = urls
            .filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) && $0 != recordingURL }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Take(url: url, date: values?.creationDate ?? values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.date > $1.date }

        // 看过的记文件名。第一次打开这一版：以前录的都算看过。
        let names = Set(takes.map { $0.url.lastPathComponent })
        let defaults = UserDefaults.standard
        var seen = Set(defaults.stringArray(forKey: TakeRecorder.seenKey) ?? [])
        if defaults.object(forKey: TakeRecorder.seenKey) == nil {
            seen = names
        } else if !names.isEmpty {
            seen.formIntersection(names)
        }
        defaults.set(Array(seen), forKey: TakeRecorder.seenKey)
        unseen = Set(takes.filter { !seen.contains($0.url.lastPathComponent) }.map(\.url))
    }

    func markSeen(_ url: URL) {
        guard unseen.contains(url) else { return }
        unseen.remove(url)
        let defaults = UserDefaults.standard
        var seen = Set(defaults.stringArray(forKey: TakeRecorder.seenKey) ?? [])
        seen.insert(url.lastPathComponent)
        defaults.set(Array(seen), forKey: TakeRecorder.seenKey)
    }

    /// 在窗口里回放这一条。
    func show(_ url: URL) {
        if let take, take != url { markSeen(take) }
        take = url
        markSeen(url)
    }

    func reveal(_ url: URL? = nil) {
        if let url = url ?? take { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: TakeRecorder.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(TakeRecorder.folder)
    }

    func trash(_ url: URL? = nil) {
        guard let url = url ?? take else { return }
        if take == url { take = nil }
        takes.removeAll { $0.url == url }
        NSWorkspace.shared.recycle([url]) { _, _ in
            DispatchQueue.main.async { self.refreshTakes() }
        }
    }

    /// 关掉回放：这一条算看过了。
    func dismiss() {
        if let take { markSeen(take) }
        take = nil
    }

    // MARK: 摄像头

    private func run() {
        if !configured {
            session.beginConfiguration()
            guard let camera = TakeRecorder.camera() else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.problem = .noCamera }
                return
            }
            // 按摄像头自己支持的最高画质录：有的 MacBook 是 1080p，有的只有 720p。
            let preset = [AVCaptureSession.Preset.hd1920x1080, .hd1280x720, .high]
                .first { camera.supportsSessionPreset($0) && session.canSetSessionPreset($0) } ?? .high
            session.sessionPreset = preset
            Log.info("camera \(camera.localizedName) preset \(preset.rawValue)")
            guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.problem = .failed }
                return
            }
            session.addInput(input)
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
               let microphone = AVCaptureDevice.default(for: .audio),
               let audio = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(audio) {
                session.addInput(audio)
            }
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            configured = true
        }
        if !session.isRunning { session.startRunning() }
        let running = session.isRunning
        Log.info("camera running \(running), inputs \(session.inputs.count), outputs \(session.outputs.count)")
        DispatchQueue.main.async { self.isRunning = running }
    }

    /// MacBook 自己的摄像头优先（提词条在它下面），没有再用别的。
    private static func camera() -> AVCaptureDevice? {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types.append(.external) } else { types.append(.externalUnknown) }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        return discovery.devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }
}

extension TakeRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        Log.info("recording started")
        DispatchQueue.main.async { self.fireStarted() }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        var finished = error == nil
        if let error = error as NSError?, let flag = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool {
            finished = flag
        }
        Log.info("recording finished \(finished) \(error.map { "\($0)" } ?? "")")
        // 录完就关摄像头：不录的时候不亮灯。
        queue.async {
            if !self.output.isRecording, self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
        DispatchQueue.main.async { self.finished(url, ok: finished) }
    }
}
