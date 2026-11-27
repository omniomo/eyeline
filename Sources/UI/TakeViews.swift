import SwiftUI
import AVFoundation

/// 左边列表里的一条：封面、稿子名、什么时候录的、多长。没看过的封面右上角有个小蓝点。
struct TakeRow: View {
    let take: TakeRecorder.Take
    let playing: Bool
    let new: Bool
    @State private var thumbnail: NSImage?
    @State private var duration: Double?

    /// 封面和时长只算一次。
    private static var cache: [URL: (NSImage?, Double?)] = [:]

    /// 这个文件换了内容（剪过）：封面、时长重新算。
    static func forget(_ url: URL) { cache[url] = nil }

    var body: some View {
        SidebarRowLayout(dot: new) {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else {
                Paper.haze
            }
        } title: {
            Text(take.title)
                .foregroundStyle(Paper.listTitle)
                .truncationMode(.middle)
        } detail: {
            Text(subtitle)
        }
        .background(SystemSelectionOff())
        .task(id: take.url) { await load() }
    }

    /// 什么时候录的、多长：今天的只写钟点，昨天写「昨天」，再早写几月几日。
    private var subtitle: String {
        let calendar = Calendar.current
        let date: String
        if calendar.isDateInToday(take.date) {
            date = take.date.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInYesterday(take.date) {
            date = String(localized: "Yesterday")
        } else {
            date = take.date.formatted(.dateTime.month(.abbreviated).day())
        }
        guard let duration, duration > 0 else { return date }
        return "\(date) · \(Prompter.clock(duration))"
    }

    private func load() async {
        if let hit = TakeRow.cache[take.url] {
            thumbnail = hit.0
            duration = hit.1
            return
        }
        let asset = AVURLAsset(url: take.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 192, height: 108)
        var image: NSImage?
        if let frame = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
            image = NSImage(cgImage: frame.image, size: .zero)
        }
        var seconds: Double?
        if let time = try? await asset.load(.duration), time.seconds.isFinite {
            seconds = time.seconds
        }
        TakeRow.cache[take.url] = (image, seconds)
        thumbnail = image
        duration = seconds
    }
}

/// 回放一条录好的视频（刚录好的那条，或者在左边列表里点的那条），铺满编辑器。
/// 点画面或者按空格：播放 / 暂停；← →：退后、前进 5 秒；↑ ↓：上一条、下一条；Esc：关掉。
/// 下面一条可以拖的进度条，两头是现在的时间和总长。进度条两端各有一个把手，往里拖就是剪头去尾：
/// 放的时候只放留下的这一段，右边的时长变成剪完的长度，旁边出来「保存剪辑」（Esc 或 ↩︎ 图标：不剪了）。
struct TakeOverlay: View {
    @ObservedObject var recorder: TakeRecorder
    let url: URL
    @StateObject private var playback: Playback

    init(recorder: TakeRecorder, url: URL) {
        self.recorder = recorder
        self.url = url
        _playback = StateObject(wrappedValue: Playback(url: url))
    }

    private var index: Int? { recorder.takes.firstIndex { $0.url == url } }

    private func show(_ offset: Int) {
        guard let index, let take = recorder.takes[safe: index + offset] else { return }
        recorder.show(take.url)
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                PlayerSurface(player: playback.player)
                // 停着的时候中间一个大播放键
                if !playback.playing {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: 2)
                        .frame(width: 68, height: 68)
                        .background(Circle().fill(.black.opacity(0.42)))
                        .transition(.opacity)
                }
            }
            // 按视频自己的比例摆：不留黑边
            .aspectRatio(playback.aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { playback.toggle() }
            .animation(.omoOut(0.25), value: playback.playing)

            HStack(spacing: 12) {
                Button { playback.toggle() } label: {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Paper.accentFill))
                        .symbolReplaceTransition()
                }
                .buttonStyle(PressStyle())
                .help(playback.playing ? String(localized: "Pause  Space") : String(localized: "Play  Space"))
                Text(Prompter.clock(playback.time))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Paper.charcoal)
                    .frame(minWidth: 34, alignment: .trailing)
                Scrubber(playback: playback)
                Text(Prompter.clock(playback.isTrimmed ? playback.trimEnd - playback.trimStart : playback.duration))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Paper.gray)
                    .frame(minWidth: 34, alignment: .leading)
            }

            HStack(spacing: 2) {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(Paper.gray)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                if playback.isTrimmed {
                    IconToggle(symbol: "arrow.uturn.backward", selected: false, help: String(localized: "Don’t trim  Esc")) { playback.resetTrim() }
                    PillButton(title: String(localized: "Save Trim")) {
                        playback.player.pause()
                        AppModel.shared.trimTake(url, from: playback.trimStart, to: playback.trimEnd)
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 10)
                }
                IconToggle(symbol: "chevron.up", selected: false, help: String(localized: "Newer take  ↑")) { show(-1) }
                    .disabled((index ?? 0) == 0)
                IconToggle(symbol: "chevron.down", selected: false, help: String(localized: "Older take  ↓")) { show(1) }
                    .disabled(index.map { $0 + 1 >= recorder.takes.count } ?? true)
                IconToggle(symbol: "folder", selected: false, help: String(localized: "Show in Finder")) { recorder.reveal(url) }
                IconToggle(symbol: "trash", selected: false, help: String(localized: "Move to Trash  ⌘⌫")) { AppModel.shared.trashTake(url) }
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 40)
        .padding(.bottom, 96)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.white)
        .background(WindowReader { playback.window = $0 })
        .onAppear {
            playback.onKey = { key in
                switch key {
                case .toggle: playback.toggle()
                case .back: playback.skip(-5)
                case .forward: playback.skip(5)
                case .newer: show(-1)
                case .older: show(1)
                case .close: if playback.isTrimmed { playback.resetTrim() } else { recorder.dismiss() }
                case .trash: AppModel.shared.trashTake(url)
                }
            }
            playback.start()
        }
        .onDisappear { playback.stop() }
    }

    private var caption: String {
        guard let take = recorder.takes.first(where: { $0.url == url }) else { return url.deletingPathExtension().lastPathComponent }
        return take.title + "  ·  " + take.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// 一条视频的播放状态：现在几秒、一共多长、在不在放，加上回放时的键盘。
final class Playback: ObservableObject {
    enum Key { case toggle, back, forward, newer, older, close, trash }

    let player: AVPlayer
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playing = false
    /// 视频的宽高比（读出来之前当 16:9）：播放器按它的比例摆，不留黑边。
    @Published private(set) var aspect: CGFloat = 16 / 9
    /// 正在拖进度条：这时不让播放器的时间盖掉手指的位置。
    var scrubbing = false
    /// 剪头去尾：留下的这一段（秒）。没剪是 0…duration。
    @Published private(set) var trimStart: Double = 0
    @Published private(set) var trimEnd: Double = 0
    /// 剪完至少留这么长。
    static let shortestTrim: Double = 0.5
    var isTrimmed: Bool { duration > 0 && (trimStart > 0.05 || trimEnd < duration - 0.05) }
    weak var window: NSWindow?
    var onKey: ((Key) -> Void)?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.isMuted = UserDefaults.standard.bool(forKey: "muteTakes")   // 测试时（-muteTakes YES）不出声
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] now in
            guard let self else { return }
            if !self.scrubbing, now.seconds.isFinite { self.time = now.seconds }
            if let total = self.player.currentItem?.duration.seconds, total.isFinite, total > 0, total != self.duration {
                self.duration = total
                if self.trimEnd <= 0 || self.trimEnd > total { self.trimEnd = total }
            }
            let moving = self.player.timeControlStatus != .paused
            if moving != self.playing { self.playing = moving }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem,
                                                             queue: .main) { [weak self] _ in self?.playing = false }
        Task { @MainActor [weak self] in
            guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize), size.width > 0, size.height > 0 else { return }
            self?.aspect = size.width / size.height
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// 出现：开始放，接住键盘（不然空格会打进后面藏着的编辑器里）。
    func start() {
        player.play()
        playing = true
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window || self.window == nil else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let key: Key?
            switch (Int(event.keyCode), modifiers) {
            case (49, []): key = .toggle            // 空格
            case (123, []): key = .back             // ←
            case (124, []): key = .forward          // →
            case (126, []): key = .newer            // ↑
            case (125, []): key = .older            // ↓
            case (53, []): key = .close             // Esc
            case (51, [.command]): key = .trash     // ⌘⌫
            default: key = nil
            }
            guard let key else { return event }
            self.onKey?(key)
            return nil
        }
    }

    func stop() {
        player.pause()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func toggle() {
        if player.timeControlStatus == .paused {
            // 放完了再按：从头放（剪过的：从留下的那段开头放）
            let end = isTrimmed ? trimEnd : duration
            if duration > 0 && (time >= end - 0.1 || time < trimStart - 0.05) { seek(to: trimStart) }
            player.play()
            playing = true
        } else {
            player.pause()
            playing = false
        }
    }

    func skip(_ seconds: Double) {
        seek(to: time + seconds)
    }

    /// 拖把手：开头、结尾（中间至少留 shortestTrim 秒）。画面跟着停在那一帧。
    func setTrimStart(_ seconds: Double) {
        guard duration > 0 else { return }
        trimStart = min(max(0, seconds), trimEnd - Playback.shortestTrim)
        applyTrim()
        seek(to: trimStart)
    }

    func setTrimEnd(_ seconds: Double) {
        guard duration > 0 else { return }
        trimEnd = max(min(duration, seconds), trimStart + Playback.shortestTrim)
        applyTrim()
        seek(to: trimEnd)
    }

    /// 不剪了：两头回到最开始和最后。
    func resetTrim() {
        trimStart = 0
        trimEnd = duration
        applyTrim()
    }

    /// 放到留下的那段末尾就停（系统帮着停，停了会发「放完了」）。
    private func applyTrim() {
        player.currentItem?.forwardPlaybackEndTime = isTrimmed && trimEnd < duration - 0.05
            ? CMTime(seconds: trimEnd, preferredTimescale: 600) : .invalid
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(duration, seconds) : seconds)
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// 可以拖的进度条：细线，放过的部分是主色，手指按住的地方有个小圆点。
/// 两端各一个竖着的小把手：往里拖，剪掉开头、结尾；剪掉的那两截颜色更淡。
struct Scrubber: View {
    @ObservedObject var playback: Playback
    @State private var hovering = false
    @State private var handle: Handle?

    private enum Handle { case start, end }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let total = playback.duration
            let x = { (seconds: Double) -> CGFloat in total > 0 ? width * CGFloat(min(1, max(0, seconds / total))) : 0 }
            let start = x(playback.trimStart)
            let end = total > 0 ? x(playback.trimEnd) : width
            let now = min(max(x(playback.time), start), end)
            let big = hovering || playback.scrubbing
            ZStack(alignment: .leading) {
                Capsule().fill(Paper.line.opacity(0.45)).frame(height: 4)
                Capsule().fill(Paper.line).frame(width: max(4, end - start), height: 4).offset(x: start)
                Capsule().fill(Paper.accent).frame(width: max(0, now - start), height: 4).offset(x: start)
                Circle()
                    .fill(Paper.accent)
                    .frame(width: big ? 12 : 8, height: big ? 12 : 8)
                    .offset(x: now - (big ? 6 : 4))
                trimHandle(.start, at: start, width: width)
                trimHandle(.end, at: end, width: width)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        playback.scrubbing = true
                        playback.seek(to: Double(min(1, max(0, value.location.x / width))) * playback.duration)
                    }
                    .onEnded { _ in playback.scrubbing = false }
            )
            .coordinateSpace(name: "scrubber")
        }
        .frame(height: 22)
        .onHover { hovering = $0 }
        .animation(.omoOut(0.2), value: hovering)
    }

    /// 一个把手：看着是细细一竖，能按的地方大得多（28×34，不占位置），好抓；鼠标放上来变成左右箭头。
    /// 在拖、或者已经剪过时是主色。
    private func trimHandle(_ which: Handle, at position: CGFloat, width: CGFloat) -> some View {
        let active = handle == which || playback.isTrimmed
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(active ? Paper.accent : Paper.gray.opacity(hovering ? 0.75 : 0.4))
            .frame(width: 4, height: 16)
            // 占的位置和进度条一样高（不然整条进度条会被撑得往下掉）；能按的地方往外多出 6 点
            .frame(width: 16, height: 22)
            .contentShape(Rectangle().inset(by: -6))
            .offset(x: position - 8)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("scrubber"))
                    .onChanged { value in
                        handle = which
                        playback.scrubbing = true
                        let seconds = Double(min(1, max(0, value.location.x / width))) * playback.duration
                        if which == .start { playback.setTrimStart(seconds) } else { playback.setTrimEnd(seconds) }
                    }
                    .onEnded { _ in
                        handle = nil
                        playback.scrubbing = false
                    }
            )
    }
}

/// 只画画面：一层 AVPlayerLayer，圆角（底色是很浅的灰，不用黑）。不用 AVKit 的播放器（SwiftUI 的 VideoPlayer 在 macOS 26 上会闪退，
/// AVPlayerView 自带的控制条又小又难点），控制都在 TakeOverlay 里自己做。
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    static func dismantleNSView(_ view: PlayerLayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    /// 盖在画面边上的一圈底色（见 init）。
    private let edge = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.96, alpha: 1).cgColor
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        // 画面比框大一圈（见 layout），铺满再被圆角裁掉：框的尺寸对不上整像素、或者系统把视频直接交给显示硬件画的时候，
        // 视频边上会时有时无地露出一道暗色细缝；多出来的这一圈正好把它盖在框外面。
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = .clear
        // 播放时 macOS 会把画面直接交给显示硬件去画（不走普通的合成，所以截图、录屏都看不到），
        // 这时画面四周时有时无地闪一道黑细线。不完全不透明、上面又压着一层的画面不会被这样交出去：
        // 透明度留一点点（看不出来），四周再盖一圈和背景同色的细边（顺带盖住边上的接缝）。
        playerLayer.opacity = 0.995
        layer?.addSublayer(playerLayer)
        edge.borderWidth = 1.5
        edge.borderColor = NSColor(Paper.white).cgColor
        edge.cornerRadius = 12
        edge.cornerCurve = .continuous
        layer?.addSublayer(edge)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 点击穿过去，交给 SwiftUI（点画面是播放 / 暂停）。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds.insetBy(dx: -1, dy: -1)
        edge.frame = bounds
        CATransaction.commit()
    }
}

/// 找到这个视图所在的窗口（键盘只管这个窗口里的按键）。
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}

/// 摄像头没给权限、找不到摄像头、或者这一条没存下来。
struct CameraNote: View {
    let problem: TakeRecorder.Problem

    var body: some View {
        switch problem {
        case .cameraDenied: SettingsNote(symbol: "video.slash", text: String(localized: "Camera is off"), pane: "Privacy_Camera")
        case .screenDenied: SettingsNote(symbol: "rectangle.dashed", text: String(localized: "Screen recording is off"), pane: "Privacy_ScreenCapture")
        case .noCamera: SettingsNote(symbol: "video.slash", text: String(localized: "No camera found"))
        case .failed: SettingsNote(symbol: "exclamationmark.circle", text: String(localized: "The take couldn’t be saved"))
        }
    }
}
