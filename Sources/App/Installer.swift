import AppKit
import CoreServices
import ServiceManagement

// MARK: - 装好以后找得到它
//
// 很多人下载完直接在 dmg 窗口里双击就用了，没拖进「应用程序」，推出 dmg 以后就找不到了。
// 先查一下：「应用程序」里已经有一份，或者 Spotlight 在 dmg 以外的地方能搜到它（比如还放在「下载」里），就不问。
// 都没有，窗口里出一张卡片问一下：
// 点「移到应用程序」，就拷进 /Applications（从「下载」来的是挪过去），去掉「刚下载的」标记，
// 从那里重新打开；从 dmg 来的，等这边退出后把 dmg 推出。不点就算了，这个位置不再问。

enum Installer {
    /// 这份 App 真正放在哪。从「下载」里打开的、系统为了安全会挪到一个临时位置去跑（App Translocation），这里换回原来的位置。
    static var originalURL: URL {
        let url = Bundle.main.bundleURL
        guard url.path.contains("/AppTranslocation/") else { return url }
        return translocatedOriginal(url) ?? url
    }

    /// 位置上看：不在「应用程序」里，而是在 dmg、「下载」、桌面，或者被系统挪去临时位置跑。
    private static var outsideApplications: Bool {
        let path = originalURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return false }
        if UserDefaults.standard.string(forKey: "moveDeclinedAt") == path { return false }
        return path.hasPrefix("/Volumes/") || path.hasPrefix(home + "/Downloads/") || path.hasPrefix(home + "/Desktop/")
            || Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }

    /// 要不要问：位置不对，而且现在哪里都找不到它。查 Spotlight 要一会儿，放在后台，结果回到主线程。
    static func decideOffer(_ done: @escaping @MainActor (Bool) -> Void) {
        if UserDefaults.standard.bool(forKey: "offerMove") {   // `-offerMove YES`：截图看卡片
            DispatchQueue.main.async { done(true) }
            return
        }
        guard outsideApplications else {
            DispatchQueue.main.async { done(false) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let findable = alreadyFindable
            Log.info("install check: outside Applications, findable elsewhere \(findable)")
            DispatchQueue.main.async { done(!findable) }
        }
    }

    /// 已经找得到了吗：「应用程序」里有一份（系统登记过的），或者 Spotlight 收录了一份不在 dmg 上的。
    private static var alreadyFindable: Bool {
        let id = Bundle.main.bundleIdentifier ?? "com.omniomo.eyeline"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let installed = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).contains { url in
            let path = url.resolvingSymlinksInPath().path
            return (path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/"))
                && FileManager.default.fileExists(atPath: path)
        }
        if installed { return true }
        return spotlightPaths(bundleID: id).contains { path in
            !path.hasPrefix("/Volumes/") && !path.contains("/AppTranslocation/") && FileManager.default.fileExists(atPath: path)
        }
    }

    /// Spotlight 里所有这个 App 的位置。
    private static func spotlightPaths(bundleID: String) -> [String] {
        let text = "kMDItemCFBundleIdentifier == '\(bundleID)' && kMDItemContentType == 'com.apple.application-bundle'"
        guard let query = MDQueryCreate(kCFAllocatorDefault, text as CFString, nil, nil),
              MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        return (0..<MDQueryGetResultCount(query)).compactMap { index in
            guard let raw = MDQueryGetResultAtIndex(query, index) else { return nil }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            return MDItemCopyAttribute(item, kMDItemPath) as? String
        }
    }

    /// 「以后再说」：这个位置不再问。
    static func decline() {
        UserDefaults.standard.set(originalURL.resolvingSymlinksInPath().path, forKey: "moveDeclinedAt")
    }

    /// 拷（或挪）进「应用程序」，再从那里打开；成功返回 true（这边随后退出）。
    static func moveAndRelaunch() -> Bool {
        let source = originalURL
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        let files = FileManager.default
        let fromDiskImage = source.path.hasPrefix("/Volumes/")
        do {
            // 「应用程序」里已经有一份（旧版本）：放进废纸篓，换成这一份
            if files.fileExists(atPath: destination.path) {
                try files.trashItem(at: destination, resultingItemURL: nil)
            }
            if fromDiskImage {
                try files.copyItem(at: source, to: destination)
            } else {
                try files.moveItem(at: source, to: destination)
            }
        } catch {
            Log.info("move to Applications failed: \(error.localizedDescription)")
            return false
        }
        // 不再算「刚下载的」：下次打开不会又被挪去临时位置（App 是公证过的）
        run("/usr/bin/xattr", "-dr", "com.apple.quarantine", destination.path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error { Log.info("relaunch from Applications failed: \(error.localizedDescription)") }
                if fromDiskImage, source.pathComponents.count > 2 {
                    // 等这边退出了再推出 dmg（自己还在 dmg 上跑的时候推不出去）
                    let volume = "/Volumes/" + source.pathComponents[2]
                    let eject = Process()
                    eject.executableURL = URL(fileURLWithPath: "/bin/sh")
                    eject.arguments = ["-c", "sleep 2; /usr/bin/hdiutil detach \"$0\" -quiet", volume]
                    try? eject.run()
                }
                NSApp.terminate(nil)
            }
        }
        return true
    }

    private static func run(_ tool: String, _ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }

    /// 系统没公开的 SecTranslocateCreateOriginalPathForURL（Security 框架里一直有）：被挪去临时位置跑的 App，原来在哪。
    private static func translocatedOriginal(_ url: URL) -> URL? {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let original = unsafeBitCast(symbol, to: Original.self)
        return original(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}

/// 登录时打开（系统设置 › 通用 › 登录项里也看得到）。默认关着，只有在设置里打开才会加进去。
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.info("login item \(on ? "on" : "off") failed: \(error.localizedDescription)")
        }
    }
}
