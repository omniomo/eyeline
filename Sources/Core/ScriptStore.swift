import Foundation
import Combine

/// 一份稿子。
struct ScriptDocument: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var updated = Date()
    /// 上次念到哪（原文里的位置），下次从这里接着念。
    var resume = 0
    /// 配的幻灯片（PDF 的书签：文件改名、挪了位置也找得到）。主窗口里在稿子上面显示，翻页带着稿子走。
    var slides: Data?
    /// 一页一段（空一行就是翻一页，见 PagedScript）：配了幻灯片、从幻灯片导入的稿子是这样。
    var byPage: Bool?
    /// 名字（从幻灯片导入的用文件名）；没有就用第一行字。
    var name: String?
    /// 上次配上时每一页的「长相」（见 SlideMatch）：PDF 改了，拿来对一遍，稿子跟着原来那一页走。
    var slideSignatures: [String]?
    /// 幻灯片里删掉的那几页的话：不念了，先留着，分镜表最后能看到。
    var removedSlides: [String]?

    var isPaged: Bool { byPage == true }

    /// 配的 PDF 在哪；没配、或者文件没了是 nil。
    var slidesURL: URL? {
        guard let slides else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: slides, options: [.withoutUI], bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 名字，或者第一行不空的字（去掉 Markdown 记号）。
    var title: String {
        if let name, !name.isEmpty { return name }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*• ")).replacingOccurrences(of: "**", with: "")
        return String(cleaned.prefix(40))
    }
}

/// 所有稿子存在「应用程序支持/Eyeline/Scripts.json」里，改完半秒自动存。
final class ScriptStore: ObservableObject {
    @Published private(set) var documents: [ScriptDocument] = []
    private let url: URL
    private var saveWork: DispatchWorkItem?

    init(folder: URL? = nil) {
        let base = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eyeline", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("Scripts.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([ScriptDocument].self, from: data) {
            documents = saved
        }
        if documents.isEmpty {
            documents = [ScriptDocument(text: ScriptStore.sample)]
            save(now: true)
        } else {
            localizeSample()
        }
    }

    /// 示例讲稿还没动过：换成现在界面语言的那一版（换界面语言时 Eyeline 会自己重新打开，打开时换）。
    /// 改过一个字（或者配了幻灯片）就是自己的稿子了，不动。
    private func localizeSample() {
        let current = ScriptStore.sample
        var changed = false
        for index in documents.indices where documents[index].text != current && documents[index].slides == nil
            && ScriptStore.knownSamples.contains(ScriptStore.squeezed(documents[index].text)) {
            documents[index].text = current
            documents[index].resume = 0
            changed = true
        }
        if changed { save(now: true) }
    }

    /// 示例讲稿出过的各版（中英文；早先写的是按 Option 加空格），去掉空白来比，空行多一个少一个都算同一版。
    static let knownSamples: Set<String> = {
        let older = [
            sampleChinese.replacingOccurrences(of: "想停一下，按空格。想退回一句，按左方向键。",
                                               with: "想停一下，按 Option 加空格。想退回一句，按 Option 加左方向键。"),
            sampleEnglish.replacingOccurrences(of: "To pause, press Space. To go back a line, press the left arrow.",
                                               with: "To pause, press Option and Space. To go back a line, press Option and the left arrow."),
        ]
        return Set(([sampleChinese, sampleEnglish] + older).map(squeezed))
    }()

    static func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    subscript(id: UUID?) -> ScriptDocument? {
        documents.first { $0.id == id }
    }

    @discardableResult
    func add(text: String = "", name: String? = nil, byPage: Bool = false) -> ScriptDocument {
        var document = ScriptDocument(text: text)
        document.name = name
        document.byPage = byPage ? true : nil
        documents.insert(document, at: 0)
        save()
        return document
    }

    func update(_ id: UUID, text: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }), documents[index].text != text else { return }
        documents[index].text = text
        documents[index].updated = Date()
        documents[index].resume = min(documents[index].resume, (text as NSString).length)
        save()
    }

    /// 改这份稿子的几项（名字、一页一段、幻灯片的长相……）。
    func modify(_ id: UUID, _ change: (inout ScriptDocument) -> Void) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        change(&documents[index])
        save()
    }

    /// 给这份稿子配幻灯片（nil：去掉）。
    func setSlides(_ id: UUID, _ url: URL?) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].slides = url.flatMap { try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        save()
    }

    func setResume(_ id: UUID, _ offset: Int) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].resume = offset
        save()
    }

    func duplicate(_ id: UUID) -> ScriptDocument? {
        guard let source = self[id] else { return nil }
        var copy = source
        copy.id = UUID()
        copy.updated = Date()
        copy.resume = 0
        if let index = documents.firstIndex(where: { $0.id == id }) {
            documents.insert(copy, at: index)
        }
        save()
        return copy
    }

    func remove(_ id: UUID) {
        documents.removeAll { $0.id == id }
        save()
    }

    func restore(_ document: ScriptDocument, at index: Int) {
        documents.insert(document, at: min(index, documents.count))
        save()
    }

    func save(now: Bool = false) {
        saveWork?.cancel()
        let snapshot = documents
        let url = url
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        saveWork = work
        if now {
            work.perform()
        } else {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    static var sample: String {
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        return chinese ? sampleChinese : sampleEnglish
    }

    static let sampleChinese = """
    # 试一试 Eyeline

    按右下角的播放键，然后把下面这几句念出来。
    字会跟着你的声音往前走，你只要一直看着摄像头下面那一点。
    在镜头里，你就是在看着屏幕前的人。⏸
    念错了也没关系，从这句的开头重新念，它会自己跳回来。
    想停一下，按空格。想退回一句，按左方向键。
    （括号里的字是写给自己看的，不用念。）
    最后一句念完，这条字幕会收回到摄像头里。
    """

    static let sampleEnglish = """
    # Try Eyeline

    Press play in the corner, then read these lines out loud.
    The words move with your voice, so you can keep your eyes right under the camera.
    On camera, you are looking straight at the person watching. ⏸
    If you trip over a line, just start it again from the top, and it jumps back with you.
    To pause, press Space. To go back a line, press the left arrow.
    (Words in brackets are notes for you. You don't read them.)
    When you finish the last line, the ribbon slides back into the camera.
    """
}
