import AppKit
import CoreImage
import ScreenCaptureKit

// MARK: - 屏幕的画面
//
// 用 ScreenCaptureKit 录一块屏幕，每一帧交给 CompositeRecorder。
// Eyeline 自己的窗口都不录（提词条、它的按钮、不放幻灯片时的讲稿窗口），只留下 keeping 里的：圆框人像、放映时的幻灯片窗口。
// 鼠标照常录。要「屏幕录制」权限。
// `-fakeScreen YES`：测试用，不录屏，送一块会动的假画面（不用权限）。

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Failure: Error {
        case noDisplay
    }

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.omniomo.eyeline.screen")
    private var onFrame: ((CIImage) -> Void)?
    private var fakeTimer: DispatchSourceTimer?

    /// 有没有「屏幕录制」权限（不弹窗）。
    static var allowed: Bool {
        if testDenied { return false }
        return UserDefaults.standard.bool(forKey: "fakeScreen") || CGPreflightScreenCaptureAccess()
    }

    /// 测试：当作没有权限。
    static var testDenied = false

    /// 开始录 region（AppKit 的全局坐标）这一块，它在 screen 上。
    /// hideOwnWindows：Eyeline 自己的窗口不录，keeping 里的除外。done(nil) 是开始了（主线程）。
    func start(region: CGRect, on screen: NSScreen, hideOwnWindows: Bool, keeping: [NSWindow],
               frame: @escaping (CIImage) -> Void, done: @escaping (Error?) -> Void) {
        onFrame = frame
        if UserDefaults.standard.bool(forKey: "fakeScreen") {
            startFake(size: CGSize(width: region.width * 2, height: region.height * 2))
            done(nil)
            return
        }
        let kept = Set(keeping.map { CGWindowID($0.windowNumber) })
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let scale = screen.backingScaleFactor
        let screenFrame = screen.frame
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            guard let content, let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                DispatchQueue.main.async { done(error ?? Failure.noDisplay) }
                return
            }
            let filter: SCContentFilter
            if hideOwnWindows, let me = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) {
                let keep = content.windows.filter { kept.contains($0.windowID) }
                filter = SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: keep)
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
            let config = SCStreamConfiguration()
            // 显示器自己的坐标：左上角是原点
            config.sourceRect = CGRect(x: region.minX - screenFrame.minX, y: screenFrame.maxY - region.maxY,
                                       width: region.width, height: region.height)
            var width = region.width * scale, height = region.height * scale
            if width > 3840 {
                height *= 3840 / width
                width = 3840
            }
            config.width = Int(width / 2) * 2
            config.height = Int(height / 2) * 2
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true
            config.queueDepth = 6
            config.colorSpaceName = CGColorSpace.sRGB
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                DispatchQueue.main.async { done(error) }
                return
            }
            self.stream = stream
            stream.startCapture { error in
                Log.info("screen: capturing \(Int(region.width))x\(Int(region.height)) at \(Int(region.minX)),\(Int(region.minY)) → \(config.width)x\(config.height), kept \(kept.count) own windows, \(error.map { "\($0)" } ?? "ok")")
                DispatchQueue.main.async { done(error) }
            }
        }
    }

    func stop() {
        fakeTimer?.cancel()
        fakeTimer = nil
        stream?.stopCapture { _ in }
        stream = nil
        onFrame = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(CIImage(cvPixelBuffer: buffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("screen: stopped \(error)")
    }

    // MARK: 测试

    /// 一块假屏幕：浅灰底，一个窗口，一个来回走的小方块。
    private func startFake(size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let start = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            let t = Date().timeIntervalSince(start)
            var image = CIImage(color: CIColor(red: 0.93, green: 0.94, blue: 0.96)).cropped(to: rect)
            let window = CGRect(x: size.width * 0.1, y: size.height * 0.12, width: size.width * 0.8, height: size.height * 0.72)
            image = CIImage(color: .white).cropped(to: window).composited(over: image)
            let bar = CGRect(x: window.minX, y: window.maxY - size.height * 0.06, width: window.width, height: size.height * 0.06)
            image = CIImage(color: CIColor(red: 0.88, green: 0.88, blue: 0.9)).cropped(to: bar).composited(over: image)
            let x = window.minX + (window.width - size.height * 0.12) * CGFloat(0.5 + 0.5 * sin(t * 2))
            let block = CGRect(x: x, y: window.midY - size.height * 0.06, width: size.height * 0.12, height: size.height * 0.12)
            image = CIImage(color: CIColor(red: 0.29, green: 0.66, blue: 1)).cropped(to: block).composited(over: image)
            self?.onFrame?(image)
        }
        timer.resume()
        fakeTimer = timer
    }
}
