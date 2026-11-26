import AppKit
import PDFKit

// MARK: - 把幻灯片变成一页一段的稿子
//
// 每一页一段，空一行就是下一页（见 PagedScript）。这一页的话：
// - Keynote（.key，或者 Keynote 里开着的那份）：演讲者备注。用 AppleScript 问 Keynote。
// - PowerPoint（.pptx）：演讲者备注，直接从文件里读（它是个 zip 包，里面是 XML）。
// - PDF：没有备注，每一页都是空的，你自己写（不去解析 PDF 里的字）。
// 幻灯片本身（一页一页的图）是 PDF：导入的 PDF 直接配给稿子；.key / .pptx 装了 Keynote 就让它导出一份 PDF
// （exportPDF），没装就请你自己导出成 PDF 再拖进来。主窗口里在稿子上面显示它，翻页带着稿子走（见 SlideDeck）。
// 提词时没配 PDF、Keynote / PowerPoint 开着，就跟着它们翻页（见 SlideWatcher）。

enum SlideImport {
    enum Failure: Error {
        case keynoteNotOpen
        case notAllowed
        case unreadable
    }

    /// .pdf / .pptx / .ppt / .key 才算幻灯片。
    static func handles(_ url: URL) -> Bool {
        ["pdf", "pptx", "ppt", "key"].contains(url.pathExtension.lowercased())
    }

    /// PowerPoint（新的 .pptx 和老的 .ppt）：页面用系统自带的 Quick Look 画（见 SlideRenderer）。
    static func isPowerPoint(_ url: URL) -> Bool {
        ["pptx", "ppt"].contains(url.pathExtension.lowercased())
    }

    /// 导进来的幻灯片：名字（文件名），和每一页的演讲者备注（没有就是空的）。
    struct Imported {
        var name: String
        var pages: [String]
        /// 拼成一页一段的稿子。
        var text: String { PagedScript.compose(pages) }
    }

    static func script(from url: URL) throws -> Imported {
        switch url.pathExtension.lowercased() {
        case "pdf": return try pdf(url)
        case "pptx": return try pptx(url)
        // 老的 .ppt 是二进制格式，读不出备注：每一页先空着，页面照样画出来
        case "ppt": return Imported(name: url.deletingPathExtension().lastPathComponent, pages: [])
        case "key": return try keynote(opening: url)
        default: throw Failure.unreadable
        }
    }

    // MARK: 拼成稿子

    private static func compose(title: String?, pages: [(title: String, notes: String)]) -> Imported {
        Imported(name: title ?? "", pages: pages.map(\.notes))
    }

    // MARK: PDF

    private static func pdf(_ url: URL) throws -> Imported {
        compose(title: url.deletingPathExtension().lastPathComponent, pages: try pdfPages(url))
    }

    /// PDF 有几页（读不了就抛错）。
    static func pageCount(pdf url: URL) throws -> Int {
        try pdfPages(url).count
    }

    private static func pdfPages(_ url: URL) throws -> [(title: String, notes: String)] {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw Failure.unreadable }
        var pages: [(title: String, notes: String)] = []
        for _ in 0..<document.pageCount {
            pages.append(("", ""))
        }
        return pages
    }

    // MARK: 导出成 PDF（要装了 Keynote）

    /// 这台 Mac 装了 Keynote（.key 要靠它读；.pptx 也能靠它变成一页一页的图）。
    static var keynoteInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Keynote") != nil
    }

    /// 让 Keynote 把 .key / .pptx（nil：Keynote 里开着的那份）导出成 PDF，存在「应用程序支持/Eyeline/Slides」里。
    /// 要等 Keynote 打开文件，很慢：别在主线程叫。
    static func exportPDF(from url: URL?) throws -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eyeline/Slides", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(UUID().uuidString + ".pdf")
        func quoted(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let pick: String
        let close: String
        if let url {
            pick = "set d to open (POSIX file \(quoted(url.path)))"
            close = "close d saving no"
        } else {
            pick = "if (count of documents) is 0 then error number -1728\nset d to front document"
            close = ""
        }
        let source = """
        set outFile to POSIX file \(quoted(out.path))
        with timeout of 180 seconds
            tell application id "com.apple.iWork.Keynote"
                \(pick)
                export d to outFile as PDF
                \(close)
            end tell
        end timeout
        """
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int {
            Log.info("keynote export failed \(code) \(error ?? [:])")
            throw code == -1743 ? Failure.notAllowed : code == -1728 ? Failure.keynoteNotOpen : Failure.unreadable
        }
        guard (PDFDocument(url: out)?.pageCount ?? 0) > 0 else { throw Failure.unreadable }
        return out
    }

    // MARK: Keynote

    /// Keynote 里开着的那份（最前面的）。
    static func keynoteFront() throws -> Imported {
        try runKeynote(open: nil)
    }

    private static func keynote(opening url: URL) throws -> Imported {
        try runKeynote(open: url)
    }

    private static func runKeynote(open url: URL?) throws -> Imported {
        let pick: String
        if let url {
            let path = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            pick = "set d to open (POSIX file \"\(path)\")"
        } else {
            pick = "if (count of documents) is 0 then return \"\"\nset d to front document"
        }
        // 每页一段：标题、备注，用不会出现在文字里的分隔符隔开
        let source = """
        tell application id "com.apple.iWork.Keynote"
            \(pick)
            set out to (name of d) & (ASCII character 30)
            repeat with i from 1 to (count of slides of d)
                set s to slide i of d
                set t to ""
                try
                    set t to object text of default title item of s
                end try
                set out to out & t & (ASCII character 31) & (presenter notes of s) & (ASCII character 30)
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int {
            Log.info("keynote import failed \(code) \(error ?? [:])")
            throw code == -1743 ? Failure.notAllowed : Failure.unreadable
        }
        guard let text = result?.stringValue, !text.isEmpty else { throw Failure.keynoteNotOpen }
        var parts = text.components(separatedBy: "\u{1E}")
        let name = parts.removeFirst()
        let pages = parts.filter { !$0.isEmpty }.map { part -> (String, String) in
            let fields = part.components(separatedBy: "\u{1F}")
            return (fields.first ?? "", fields.count > 1 ? fields[1] : "")
        }
        return compose(title: (name as NSString).deletingPathExtension, pages: pages)
    }

    // MARK: PowerPoint

    private static func pptx(_ url: URL) throws -> Imported {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eyeline-pptx-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", url.path, "ppt/*", "-d", folder.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        let ppt = folder.appendingPathComponent("ppt")
        func read(_ path: String) -> String? { try? String(contentsOf: ppt.appendingPathComponent(path), encoding: .utf8) }

        guard let presentation = read("presentation.xml"), let rels = read("_rels/presentation.xml.rels") else { throw Failure.unreadable }
        // 幻灯片的顺序：presentation.xml 里 sldId 的 r:id → rels 里的文件
        let targets = relationships(rels)
        let order = matches(#"<p:sldId\b[^>]*\br:id="([^"]+)""#, in: presentation).compactMap { targets[$0] }

        var pages: [(String, String)] = []
        for target in order {
            let slidePath = target.hasPrefix("/") ? String(target.dropFirst(5)) : target          // "slides/slide1.xml"
            let slide = read(slidePath) ?? ""
            let slideName = (slidePath as NSString).lastPathComponent
            let slideRels = read((slidePath as NSString).deletingLastPathComponent + "/_rels/" + slideName + ".rels") ?? ""
            var notes = ""
            if let notesTarget = relationshipTargets(slideRels).first(where: { $0.contains("notesSlide") }) {
                let notesURL = ppt.appendingPathComponent(slidePath).deletingLastPathComponent()
                    .appendingPathComponent(notesTarget).standardized
                notes = shapeText(in: (try? String(contentsOf: notesURL, encoding: .utf8)) ?? "", placeholder: "body")
            }
            let title = shapeText(in: slide, placeholder: "title").isEmpty ? shapeText(in: slide, placeholder: "ctrTitle")
                                                                           : shapeText(in: slide, placeholder: "title")
            pages.append((title, notes))
        }
        guard !pages.isEmpty else { throw Failure.unreadable }
        return compose(title: url.deletingPathExtension().lastPathComponent, pages: pages)
    }

    /// rels 里 Id → Target。
    private static func relationships(_ xml: String) -> [String: String] {
        var out: [String: String] = [:]
        for element in matches(#"(<Relationship\b[^>]*>)"#, in: xml) {
            if let id = matches(#"\bId="([^"]+)""#, in: element).first, let target = matches(#"\bTarget="([^"]+)""#, in: element).first {
                out[id] = target
            }
        }
        return out
    }

    private static func relationshipTargets(_ xml: String) -> [String] {
        matches(#"<Relationship\b[^>]*\bTarget="([^"]+)""#, in: xml)
    }

    /// 某个占位框（title、body）里的字，一段一行。
    private static func shapeText(in xml: String, placeholder: String) -> String {
        for shape in matches(#"(<p:sp>[\s\S]*?</p:sp>)"#, in: xml) where shape.contains("type=\"\(placeholder)\"") {
            let paragraphs = matches(#"(<a:p>[\s\S]*?</a:p>|<a:p/>)"#, in: shape).map { paragraph in
                matches(#"<a:t>([\s\S]*?)</a:t>"#, in: paragraph).joined()
            }
            return unescape(paragraphs.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
