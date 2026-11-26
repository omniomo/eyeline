import Foundation

// MARK: - 稿子
//
// 把一份逐字稿变成提词条上的一行字：
// - 每一行稿子之间空一大格，中间一个小点。
// - 【】[]（）() 里的字、# 标题、> 引用、⚠️ 后面的话是写给自己看的：照样显示，但不用念。
// - ⏸ 是停顿：显示成 ‖，匀速时到这里停一下。
// - ✂ 是可以删掉的句子：设置里打开「跳过 ✂」，整行不显示。
// - 列表的 1. - * 、表格、分隔线不显示。
// - 「## 第 3 页」是分页：提词时跟着 Keynote / PowerPoint 翻到第几页，就跳到这一段。

struct Script {
    enum Kind { case speech, note, pause, gap }

    struct Span {
        var kind: Kind
        /// 在 display 里的位置（UTF-16）。
        var range: NSRange
    }

    struct Token {
        var unit: Unit
        /// 在 display 里的位置（UTF-16）。
        var range: NSRange
        /// 在原文里的位置（UTF-16），用来和编辑器对上。
        var raw: NSRange
        var sentence: Int
    }

    struct Sentence {
        var firstToken: Int
        /// 不含。
        var endToken: Int
    }

    /// 分页：「## 第 3 页」这一行在原文里的位置。
    struct Page: Equatable {
        var number: Int
        var raw: Int
    }

    static let gap = "\u{2003}\u{00B7}\u{2003}"
    static let pauseMark = "\u{2009}\u{2016}\u{2009}"

    let text: String
    let display: String
    let spans: [Span]
    let tokens: [Token]
    let sentences: [Sentence]
    /// 第几个词前面有几个 ⏸。
    let pauses: [Int: Int]
    /// 「## 第 N 页」，按出现的顺序。
    let pages: [Page]
    /// 中日韩的字比拉丁字母的词多。
    let isCJK: Bool

    var count: Int { tokens.count }
    var isEmpty: Bool { tokens.isEmpty }

    init(text: String, skipCuts: Bool = false) {
        self.text = text
        let source = text as NSString

        var lines: [[Piece]] = []
        var pages: [Page] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length),
                                   options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            if let number = Script.pageNumber(source.substring(with: lineRange)) {
                pages.append(Page(number: number, raw: lineRange.location))
            }
            let pieces = Script.pieces(of: source, line: lineRange, skipCuts: skipCuts)
            if !pieces.isEmpty { lines.append(pieces) }
        }

        let out = NSMutableString()
        var spans: [Span] = []
        var tokens: [Token] = []
        var sentences: [Sentence] = []
        var pauses: [Int: Int] = [:]
        var newSentence = true
        var han = 0
        var words = 0

        func append(_ string: String, _ kind: Kind) -> NSRange {
            let start = out.length
            out.append(string)
            let range = NSRange(location: start, length: out.length - start)
            if range.length > 0 { spans.append(Span(kind: kind, range: range)) }
            return range
        }

        for (index, line) in lines.enumerated() {
            if index > 0 { _ = append(Script.gap, .gap) }
            newSentence = true
            for piece in line {
                switch piece.kind {
                case .speech:
                    let raw = source.substring(with: piece.raw)
                    let shown = append(raw, .speech)
                    let rawNS = raw as NSString
                    var lastEnd = 0
                    for (unit, range) in Tokenizer.units(in: raw) {
                        if range.location > lastEnd,
                           Script.endsSentence(rawNS.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))) {
                            newSentence = true
                        }
                        if newSentence || sentences.isEmpty {
                            sentences.append(Sentence(firstToken: tokens.count, endToken: tokens.count))
                            newSentence = false
                        }
                        tokens.append(Token(unit: unit,
                                            range: NSRange(location: shown.location + range.location, length: range.length),
                                            raw: NSRange(location: piece.raw.location + range.location, length: range.length),
                                            sentence: sentences.count - 1))
                        sentences[sentences.count - 1].endToken = tokens.count
                        if unit.isWord { words += 1 } else { han += 1 }
                        lastEnd = range.location + range.length
                    }
                    if rawNS.length > lastEnd,
                       Script.endsSentence(rawNS.substring(with: NSRange(location: lastEnd, length: rawNS.length - lastEnd))) {
                        newSentence = true
                    }
                case .note:
                    _ = append(piece.display ?? source.substring(with: piece.raw), .note)
                case .pause:
                    _ = append(Script.pauseMark, .pause)
                    pauses[tokens.count, default: 0] += 1
                case .gap:
                    break
                }
            }
        }

        self.display = out as String
        self.spans = spans
        self.tokens = tokens
        self.sentences = sentences
        self.pauses = pauses
        self.pages = pages
        self.isCJK = han >= words
    }

    // MARK: 位置换算

    /// 光标在原文 offset 处：从这里或者后面第一个要念的词开始。
    func token(atRaw offset: Int) -> Int {
        var low = 0, high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if tokens[mid].raw.location + tokens[mid].raw.length <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// 第 t 个词在原文里的起点；念完了就是原文末尾。
    func rawOffset(ofToken t: Int) -> Int {
        t < tokens.count ? tokens[max(0, t)].raw.location : (text as NSString).length
    }

    /// 第 t 个词所在的句子；念完了算最后一句。
    func sentence(ofToken t: Int) -> Int {
        guard !tokens.isEmpty else { return 0 }
        return tokens[min(max(0, t), tokens.count - 1)].sentence
    }

    /// 匀速念完剩下的要多久。
    func duration(from t: Int = 0, perMinute: Double) -> TimeInterval {
        guard perMinute > 0 else { return 0 }
        let pauseCount = pauses.filter { $0.key >= t }.values.reduce(0, +)
        return Double(max(0, tokens.count - t)) / perMinute * 60 + Double(pauseCount) * Script.pauseSeconds
    }

    static let pauseSeconds: TimeInterval = 0.8

    private static let pageHeading = try! NSRegularExpression(
        pattern: #"^\s*#{1,6}\s*(?:第\s*(\d{1,3})\s*页|(?:slide|page|p)\.?\s*(\d{1,3})(?!\d))"#, options: [.caseInsensitive])

    /// 「## 第 3 页 · 标题」→ 3；不是分页就是 nil。
    static func pageNumber(_ line: String) -> Int? {
        let ns = line as NSString
        guard let match = pageHeading.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for group in 1...2 where match.range(at: group).location != NSNotFound {
            return Int(ns.substring(with: match.range(at: group)))
        }
        return nil
    }

    // MARK: 解析

    private struct Piece {
        var kind: Kind
        var raw: NSRange
        var display: String?
    }

    private static let listMarker = try! NSRegularExpression(
        pattern: #"^(?:[-*+•·]\s+(?:\[[ xX]\]\s*)?|\d{1,3}[.、)）]\s*|[（(]\d{1,3}[)）]\s*)"#)

    private static func pieces(of source: NSString, line: NSRange, skipCuts: Bool) -> [Piece] {
        var start = line.location
        var stop = line.location + line.length
        while start < stop, isSpace(source.character(at: start)) { start += 1 }
        while stop > start, isSpace(source.character(at: stop - 1)) { stop -= 1 }
        guard start < stop else { return [] }

        let content = source.substring(with: NSRange(location: start, length: stop - start))
        if skipCuts && content.contains("\u{2702}") { return [] }
        if content.hasPrefix("|") || content.hasPrefix("```") || content.hasPrefix("<!--") { return [] }
        if content.count >= 3 && content.allSatisfy({ "-*_=— ".contains($0) }) { return [] }

        // # 标题、> 引用：整行是备注。
        if content.hasPrefix("#") || content.hasPrefix(">") {
            var i = start
            while i < stop, source.character(at: i) == 0x23 || source.character(at: i) == 0x3E { i += 1 }
            while i < stop, isSpace(source.character(at: i)) { i += 1 }
            return i < stop ? [Piece(kind: .note, raw: NSRange(location: i, length: stop - i), display: nil)] : []
        }

        var i = start
        if let match = listMarker.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) {
            i += match.range.length
        }

        var pieces: [Piece] = []
        var speechStart = i
        func flushSpeech(_ end: Int) {
            if end > speechStart {
                pieces.append(Piece(kind: .speech, raw: NSRange(location: speechStart, length: end - speechStart), display: nil))
            }
        }
        func variationLength(after j: Int) -> Int {
            j + 1 < stop && (source.character(at: j + 1) == 0xFE0F || source.character(at: j + 1) == 0xFE0E) ? 2 : 1
        }

        var j = i
        while j < stop {
            let c = source.character(at: j)
            switch c {
            case 0x2A where j + 1 < stop && source.character(at: j + 1) == 0x2A,   // **
                 0x5F where j + 1 < stop && source.character(at: j + 1) == 0x5F:   // __
                flushSpeech(j)
                j += 2
                speechStart = j
            case 0x60:                                                             // `
                flushSpeech(j)
                j += 1
                speechStart = j
            case 0x3010, 0x5B, 0xFF08, 0x28:                                       // 【 [ （ (
                let close: unichar = c == 0x3010 ? 0x3011 : c == 0x5B ? 0x5D : c == 0xFF08 ? 0xFF09 : 0x29
                var k = j + 1
                while k < stop, source.character(at: k) != close { k += 1 }
                let end = min(stop, k + 1)
                flushSpeech(j)
                pieces.append(Piece(kind: .note, raw: NSRange(location: j, length: end - j), display: nil))
                j = end
                speechStart = j
            case 0x26A0:                                                           // ⚠️ 后面整句是备注
                flushSpeech(j)
                let restStart = j + variationLength(after: j)
                let rest = source.substring(with: NSRange(location: restStart, length: stop - restStart))
                    .trimmingCharacters(in: .whitespaces)
                pieces.append(Piece(kind: .note, raw: NSRange(location: j, length: stop - j),
                                    display: "\u{26A0}\u{FE0E}" + (rest.isEmpty ? "" : " " + rest)))
                j = stop
                speechStart = j
            case 0x23F8:                                                           // ⏸
                flushSpeech(j)
                let length = variationLength(after: j)
                pieces.append(Piece(kind: .pause, raw: NSRange(location: j, length: length), display: nil))
                j += length
                speechStart = j
            case 0x2702, 0xFE0F, 0xFE0E:                                           // ✂ 和多余的变体符
                flushSpeech(j)
                j += c == 0x2702 ? variationLength(after: j) : 1
                speechStart = j
            default:
                j += 1
            }
        }
        flushSpeech(stop)
        return pieces
    }

    private static func isSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x3000 || c == 0xA0
    }

    private static let sentenceEnders: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "…", "．"]

    private static func endsSentence(_ between: String) -> Bool {
        if between.contains(where: { sentenceEnders.contains($0) }) { return true }
        // 英文句号：后面是空格或者结尾。
        if let dot = between.firstIndex(of: ".") {
            let after = between[between.index(after: dot)...]
            return after.isEmpty || after.first?.isWhitespace == true
        }
        return false
    }
}

// MARK: - 关键词
//
// 关键词模式：提词条一次只给一个关键词，你看着它自己说，按 ⌥→（或者翻页笔、脚踏板）换下一个。
// - 稿子里有加粗（**懒人**）：加粗的就是关键词，按出现的顺序。同一份逐字稿，逐字和关键词两种模式随时切。
// - 没有加粗：每一行就是一个关键词。没有逐字稿、只有提纲的人，一行写一个就行。
// - 关键词后面写 ⏱20（⏱20s、⏱1:30、⏱90秒、⏱2分）：在这里停这么久，到时间自己换下一个；不写就一直等你按。
// - # 标题、> 引用、表格、分隔线不算；设置里打开「跳过 ✂」时，标了 ✂ 的行也不算。

struct Cues {
    struct Cue: Equatable {
        var text: String
        /// 在原文里的位置（UTF-16），用来和编辑器对上。
        var raw: Int
        /// 在这里停多久（秒）；nil 是一直等你按。
        var seconds: Double?
    }

    let items: [Cue]
    /// 关键词来自稿子里的加粗（不是每行一个）。
    let fromBold: Bool

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    /// 写了时长的关键词一共多久。
    var timed: TimeInterval { items.compactMap(\.seconds).reduce(0, +) }

    private static let bold = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*|__(.+?)__"#)
    private static let timer = try! NSRegularExpression(
        pattern: #"\x{23F1}\x{FE0F}?\s*(\d+(?:\.\d+)?)(?:[:：](\d{1,2}))?(秒|分钟|分|min|m|s)?"#, options: [.caseInsensitive])
    private static let listMarker = try! NSRegularExpression(
        pattern: #"^(?:[-*+•·]\s+(?:\[[ xX]\]\s*)?|\d{1,3}[.、)）]\s*|[（(]\d{1,3}[)）]\s*)"#)

    init(text: String, skipCuts: Bool = false) {
        let source = text as NSString
        var lines: [NSRange] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length),
                                   options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            var start = range.location, stop = range.location + range.length
            while start < stop, Cues.isSpace(source.character(at: start)) { start += 1 }
            while stop > start, Cues.isSpace(source.character(at: stop - 1)) { stop -= 1 }
            guard start < stop else { return }
            let content = source.substring(with: NSRange(location: start, length: stop - start))
            if content.hasPrefix("#") || content.hasPrefix(">") || content.hasPrefix("|") || content.hasPrefix("```")
                || content.hasPrefix("<!--") { return }
            if content.count >= 3 && content.allSatisfy({ "-*_=— ".contains($0) }) { return }
            if skipCuts && content.contains("\u{2702}") { return }
            lines.append(NSRange(location: start, length: stop - start))
        }

        var items: [Cue] = []
        let anyBold = lines.contains { Cues.bold.firstMatch(in: text, range: $0) != nil }
        if anyBold {
            for line in lines {
                let matches = Cues.bold.matches(in: text, range: line)
                for (index, match) in matches.enumerated() {
                    let inner = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                    // 时长写在这个关键词后面、下一个关键词前面
                    let after = match.range.location + match.range.length
                    let until = index + 1 < matches.count ? matches[index + 1].range.location : line.location + line.length
                    let seconds = Cues.seconds(in: text, range: NSRange(location: after, length: max(0, until - after)))
                    items.append(Cue(text: Cues.clean(source.substring(with: inner)), raw: inner.location, seconds: seconds))
                }
            }
        } else {
            for line in lines {
                var start = line.location
                let content = source.substring(with: line)
                if let marker = Cues.listMarker.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) {
                    start += marker.range.length
                }
                let rest = NSRange(location: start, length: line.location + line.length - start)
                let seconds = Cues.seconds(in: text, range: rest)
                let shown = Cues.timer.stringByReplacingMatches(in: source.substring(with: rest), range: NSRange(location: 0, length: rest.length), withTemplate: "")
                items.append(Cue(text: Cues.clean(shown), raw: start, seconds: seconds))
            }
        }
        // 没有一个要念的字的（只有括号里的备注之类）不算。
        self.items = items.filter { !$0.text.isEmpty && !Script(text: $0.text).isEmpty }
        self.fromBold = anyBold
    }

    /// 光标在原文 offset 处：光标所在（或者前面最近）的那个关键词；在第一个前面就是第一个。
    func index(atRaw offset: Int) -> Int {
        items.lastIndex(where: { $0.raw <= offset }) ?? 0
    }

    private static func seconds(in text: String, range: NSRange) -> Double? {
        guard range.length > 0, let match = timer.firstMatch(in: text, range: range) else { return nil }
        let source = text as NSString
        guard let value = Double(source.substring(with: match.range(at: 1))) else { return nil }
        if match.range(at: 2).location != NSNotFound, let rest = Double(source.substring(with: match.range(at: 2))) {
            return value * 60 + rest
        }
        let unit = match.range(at: 3).location != NSNotFound ? source.substring(with: match.range(at: 3)).lowercased() : ""
        let seconds = ["分", "分钟", "min", "m"].contains(unit) ? value * 60 : value
        return seconds > 0 ? seconds : nil
    }

    /// 去掉 Markdown 记号、⏸ ✂ 和变体符，留下要显示的字。
    private static func clean(_ string: String) -> String {
        var s = string
        for mark in ["**", "__", "`", "\u{23F8}", "\u{2702}", "\u{FE0F}", "\u{FE0E}"] { s = s.replacingOccurrences(of: mark, with: "") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x3000 || c == 0xA0
    }
}
