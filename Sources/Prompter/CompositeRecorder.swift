import AVFoundation
import AppKit
import CoreImage

// MARK: - 录屏幕
//
// 录一块屏幕（放幻灯片时是幻灯片那个窗口，不然是整块屏幕），加上麦克风，写成一个横屏视频。
// 屏幕的画面由 ScreenCapture 送进来；圆框人像是屏幕上的一个窗口（CameraBubble），跟着屏幕一起录进去。
// 录到的就是原样的画面：比例跟着录的那块走（整块 MacBook 屏幕是 16:10，幻灯片窗口一般是 16:9），按屏幕的像素录（最宽 3840），字清楚。
// 背景（Excalicord / Screen Studio 那种：画面是一张圆角卡片放在渐变上）的画法还留着，界面上暂时不让选。

/// 录什么。
enum RecordLayout: String, CaseIterable, Identifiable {
    /// 只有人像（直接录摄像头）。
    case camera
    /// 只有屏幕。
    case screen
    /// 屏幕 + 圆框人像。
    case both

    var id: String { rawValue }
    var needsCamera: Bool { self != .screen }
    var needsScreen: Bool { self != .camera }
}

/// 画面下面的背景：几团柔和的颜色晕在一起。none：没有背景，原样的画面。
enum Backdrop: String, CaseIterable, Identifiable {
    case none, blush, mist, peach, sky, night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "No background")
        case .blush: return String(localized: "Blush")
        case .mist: return String(localized: "Mist")
        case .peach: return String(localized: "Peach")
        case .sky: return String(localized: "Sky")
        case .night: return String(localized: "Night")
        }
    }

    /// 底色，和四个角上晕开的颜色（左上、右上、左下、右下）。
    private var colors: (base: UInt32, blobs: [UInt32]) {
        switch self {
        case .none: return (0xFFFFFF, [])
        case .blush: return (0xF1E4EE, [0xF6C6D8, 0xD8CBF4, 0xC9E9D6, 0xF4D8C8])
        case .mist: return (0xECEEF5, [0xD9DBF6, 0xF1E6F5, 0xE0EDF7, 0xD5E1F3])
        case .peach: return (0xFBE6DB, [0xFBD0BE, 0xF8C6D2, 0xFAE3C4, 0xF1B7C6])
        case .sky: return (0xE3EFFA, [0xC7E0F7, 0xD3EFEC, 0xF5F0D2, 0xCCDBF5])
        case .night: return (0x1B1D33, [0x3B2F6B, 0x5A2E5E, 0x1F3F5E, 0x2B2450])
        }
    }

    private static var cache: [String: CGImage] = [:]
    private static let lock = NSLock()
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// 画成 size 那么大的一张图（录像、面板里的小色块都用它，颜色一样）。
    func image(size: CGSize) -> CGImage? {
        guard self != .none, size.width >= 1, size.height >= 1 else { return nil }
        let key = "\(rawValue)@\(Int(size.width))x\(Int(size.height))"
        Backdrop.lock.lock()
        defer { Backdrop.lock.unlock() }
        if let hit = Backdrop.cache[key] { return hit }
        let rect = CGRect(origin: .zero, size: size)
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CIColor {
            CIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        var image = CIImage(color: color(colors.base)).cropped(to: rect)
        // 四个角（Core Image 是左下原点）：左上、右上、左下、右下
        let corners = [CGPoint(x: 0.08, y: 0.92), CGPoint(x: 0.94, y: 0.86), CGPoint(x: 0.12, y: 0.06), CGPoint(x: 0.92, y: 0.1)]
        for (corner, hex) in zip(corners, colors.blobs) {
            let blob = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: corner.x * size.width, y: corner.y * size.height),
                "inputRadius0": 0, "inputRadius1": max(size.width, size.height) * 0.62,
                "inputColor0": color(hex), "inputColor1": color(hex, 0),
            ])?.outputImage?.cropped(to: rect)
            if let blob { image = blob.composited(over: image) }
        }
        guard let result = Backdrop.context.createCGImage(image, from: rect, format: .RGBA8,
                                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        Backdrop.cache[key] = result
        return result
    }
}

/// 一帧画面怎么排：画布多大，录到的那块画面放在哪（画布坐标，左上角是原点）。
struct Composition: Equatable {
    var layout: RecordLayout
    /// 录的那块屏幕的宽高比。
    var contentAspect: CGFloat = 16 / 9
    var backdrop: Backdrop = .none
    /// 录的那块在屏幕上有多少像素宽（视频就录这么宽，1280…3840）。
    var pixelWidth: CGFloat = 1920

    /// 有背景是 1920×1080；没有背景就跟着画面的比例和像素（最窄 4:3，总是横的）。
    var canvas: CGSize {
        if backdrop != .none { return CGSize(width: 1920, height: 1080) }
        let aspect = max(4 / 3, contentAspect)
        let width = (min(3840, max(1280, pixelWidth)) / 2).rounded() * 2
        return CGSize(width: width, height: (width / aspect / 2).rounded() * 2)
    }
    /// 有背景时画面四周留多少、圆角多大。
    var padding: CGFloat { backdrop == .none ? 0 : (canvas.height * 0.075).rounded() }
    var cornerRadius: CGFloat { backdrop == .none ? 0 : (canvas.height * 0.02).rounded() }

    var contentRect: CGRect {
        let space = CGRect(origin: .zero, size: canvas).insetBy(dx: padding, dy: padding)
        return Composition.fit(aspect: contentAspect, in: space)
    }

    static func fit(aspect: CGFloat, in rect: CGRect) -> CGRect {
        guard aspect > 0, rect.width > 0, rect.height > 0 else { return rect }
        if rect.width / rect.height > aspect {
            let width = (rect.height * aspect).rounded()
            return CGRect(x: rect.minX + ((rect.width - width) / 2).rounded(), y: rect.minY, width: width, height: rect.height)
        }
        let height = (rect.width / aspect).rounded()
        return CGRect(x: rect.minX, y: rect.minY + ((rect.height - height) / 2).rounded(), width: rect.width, height: height)
    }
}

final class CompositeRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// 镜头（圆框人像的预览用）和麦克风。
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.omniomo.eyeline.composite")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let audioOutput = AVCaptureAudioDataOutput()

    // 以下只在 queue 上碰
    private var composition = Composition(layout: .both)
    private var backdrop: CIImage?
    /// 屏幕最新的一帧。
    private var content: CIImage?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: DispatchSourceTimer?
    private var started: CMTime?
    private var url: URL?
    /// 第一帧写进去以后调用（只一次）。
    private var ready: (() -> Void)?
    private var startedAt = Date()

    /// 正在录（主线程看）。
    private(set) var isRecording = false
    /// 镜头、麦克风已经开了（准备好了，还没写文件）。只在 queue 上碰。
    private var prepared = false

    /// 先开镜头和麦克风（倒数的时候圆框里就有人了），不写文件。
    func prepare(_ composition: Composition) {
        let defaults = UserDefaults.standard
        let fake = defaults.bool(forKey: "fakeCamera")
        let audio = !defaults.bool(forKey: "noAudio") && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        queue.async {
            self.composition = composition
            self.configureSession(camera: composition.layout.needsCamera && !fake, audio: audio)
            if !self.session.inputs.isEmpty, !self.session.isRunning { self.session.startRunning() }
            self.prepared = true
        }
    }

    /// 不录了：关镜头和麦克风。
    func cancelPreparation() {
        queue.async {
            guard self.prepared, self.writer == nil else { return }
            self.prepared = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// 开始：开镜头（要人像的话，给圆框预览）和麦克风，开始写文件。屏幕的画面用 update(content:) 送进来。
    /// ready 在第一帧写进去以后调用（主线程）：等屏幕送来第一帧再开始（最多等 3 秒）。
    func start(_ composition: Composition, to url: URL, ready: @escaping () -> Void) {
        let defaults = UserDefaults.standard
        let fake = defaults.bool(forKey: "fakeCamera")
        let audio = !defaults.bool(forKey: "noAudio") && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        isRecording = true
        queue.async {
            self.composition = composition
            self.backdrop = composition.backdrop.image(size: composition.canvas).map { CIImage(cgImage: $0) }
            self.content = nil
            self.url = url
            self.ready = ready
            self.startedAt = Date()
            if !self.prepared {
                self.configureSession(camera: composition.layout.needsCamera && !fake, audio: audio)
            }
            self.prepared = false
            if !self.session.inputs.isEmpty, !self.session.isRunning { self.session.startRunning() }
            let hasMicrophone = self.session.inputs.contains { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }
            guard self.makeWriter(url, audio: audio && hasMicrophone) else {
                Log.info("composite: can't write \(url.lastPathComponent)")
                self.ready = nil
                DispatchQueue.main.async { self.isRecording = false; ready() }
                return
            }
            Log.info("composite: recording \(composition.layout) on \(composition.backdrop), \(Int(composition.canvas.width))x\(Int(composition.canvas.height)), to \(url.lastPathComponent), camera \(composition.layout.needsCamera ? (fake ? "fake" : "on") : "off"), sound \(self.audioInput != nil)")
            self.startTimer()
        }
    }

    /// 停：写完文件，done(文件，nil 是没录成)。discard：不要了（删掉）。
    func stop(discard: Bool = false, _ done: @escaping (URL?) -> Void) {
        guard isRecording else { return done(nil) }
        isRecording = false
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            if self.session.isRunning { self.session.stopRunning() }
            guard let writer = self.writer, writer.status == .writing, self.started != nil, !discard else {
                self.writer?.cancelWriting()
                if let url = self.url { try? FileManager.default.removeItem(at: url) }
                self.reset()
                DispatchQueue.main.async { done(nil) }
                return
            }
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            let url = self.url
            writer.finishWriting {
                let ok = writer.status == .completed
                Log.info("composite: finished \(ok) \(writer.error.map { "\($0)" } ?? "")")
                self.queue.async { self.reset() }
                DispatchQueue.main.async { done(ok ? url : nil) }
            }
        }
    }

    /// 屏幕的一帧（哪个线程都行）。
    func update(content image: CIImage) {
        queue.async { self.content = image }
    }

    // MARK: 镜头和麦克风

    private func configureSession(camera: Bool, audio: Bool) {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        if camera, let device = CompositeRecorder.camera(), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        }
        if audio, let microphone = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(input) {
            session.addInput(input)
            audioOutput.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        }
        session.commitConfiguration()
    }

    /// MacBook 自己的摄像头优先（提词条在它下面），没有再用别的。
    private static func camera() -> AVCaptureDevice? {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types.append(.external) } else { types.append(.externalUnknown) }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        return discovery.devices.first { $0.deviceType == .builtInWideAngleCamera } ?? discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === audioOutput, let input = audioInput, let started, input.isReadyForMoreMediaData,
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), started) >= 0 else { return }
        input.append(sampleBuffer)
    }

    // MARK: 写文件

    private func makeWriter(_ url: URL, audio: Bool) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let size = composition.canvas
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            // 屏幕上多是字：每个像素给够码率（1080p 大约 12 Mbps，Retina 整屏大约 24 Mbps）
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(min(40_000_000, max(10_000_000, size.width * size.height * 30 * 0.2))),
                                              AVVideoExpectedSourceFrameRateKey: 30],
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { return false }
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        var audioInput: AVAssetWriterInput?
        if audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }
        guard writer.startWriting() else { return false }
        self.writer = writer
        self.videoInput = video
        self.audioInput = audioInput
        self.adaptor = adaptor
        self.started = nil
        return true
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.frame() }
        timer.resume()
        self.timer = timer
    }

    /// 画一帧、写进去。时间用麦克风那边的钟，声音才对得上。
    private func frame() {
        guard let writer, writer.status == .writing, let input = videoInput, let adaptor, input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return }
        // 屏幕还没送来画面：先不开始（开头不要一块白），等太久就算了
        if content == nil, Date().timeIntervalSince(startedAt) < 3 { return }
        let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        let now = CMClockGetTime(clock)
        if started == nil {
            writer.startSession(atSourceTime: now)
            started = now
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        context.render(render(), to: buffer, bounds: CGRect(origin: .zero, size: composition.canvas),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        adaptor.append(buffer, withPresentationTime: now)
        if let ready {
            self.ready = nil
            DispatchQueue.main.async { ready() }
        }
    }

    private func reset() {
        ready = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        started = nil
        content = nil
    }

    // MARK: 画

    /// 一帧：背景 → 录到的画面（有背景时是带阴影的圆角卡片）。
    func render() -> CIImage {
        let composition = self.composition
        let canvas = composition.canvas
        let full = CGRect(origin: .zero, size: canvas)
        var image = (backdrop ?? CIImage(color: .white)).cropped(to: full)
        // 画布坐标（左上原点）→ Core Image（左下原点）
        let rect = composition.contentRect
        let target = CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
        let radius = composition.cornerRadius
        if radius > 0 {
            // 卡片的影子：往下一点、很软
            let shade = CompositeRecorder.roundedRect(target.offsetBy(dx: 0, dy: -canvas.height * 0.012), radius: radius,
                                                     color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.2))
                .applyingGaussianBlur(sigma: canvas.height * 0.022).cropped(to: full)
            image = shade.composited(over: image)
        }
        if let content {
            let scaled = content.transformed(by: CGAffineTransform(scaleX: target.width / content.extent.width,
                                                                    y: target.height / content.extent.height))
            let placed = scaled.transformed(by: CGAffineTransform(translationX: target.minX - scaled.extent.minX,
                                                                   y: target.minY - scaled.extent.minY))
                .cropped(to: target)
            if radius > 0 {
                let mask = CompositeRecorder.roundedRect(target, radius: radius, color: .white)
                image = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
            } else {
                image = placed.composited(over: image)
            }
        }
        return image.cropped(to: full)
    }

    /// 一块圆角矩形。
    private static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect), "inputRadius": radius, "inputColor": color,
        ])?.outputImage?.cropped(to: rect) ?? CIImage.empty()
    }
}
