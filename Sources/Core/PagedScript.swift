import Foundation

// MARK: - 一页一段
//
// 配了幻灯片的稿子：空一行就是翻一页。第 1 段是第 1 页的话，空一行，第 2 段是第 2 页的话……
// 一页没话说就多空一行；一页里面可以换行，但不能空行。分镜表里的每一行就是这里的一段。

struct PagedScript {
    struct Page: Equatable {
        var number: Int
        /// 这一页的话在原文里的位置（UTF-16）。没话说的页长度是 0。
        var range: NSRange
    }

    let text: String
    /// 第 1、2、3……页，按顺序。最后面没话说的页不算。
    let pages: [Page]

    init(text: String) {
        self.text = text
        let ns = text as NSString
        var pages: [Page] = []
        var start: Int?
        var end = 0
        var next = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
            if ns.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty {
                // 空行：这一页到这里为止
                let range = start.map { NSRange(location: $0, length: end - $0) } ?? NSRange(location: next, length: 0)
                pages.append(Page(number: pages.count + 1, range: range))
                start = nil
                next = NSMaxRange(enclosing)
            } else {
                if start == nil { start = line.location }
                end = NSMaxRange(line)
            }
        }
        if let start { pages.append(Page(number: pages.count + 1, range: NSRange(location: start, length: end - start))) }
        while let last = pages.last, last.range.length == 0 { pages.removeLast() }
        self.pages = pages
    }

    /// 第 n 页的话（没有就是空的）。
    func text(ofPage n: Int) -> String {
        guard pages.indices.contains(n - 1), pages[n - 1].range.length > 0 else { return "" }
        return (text as NSString).substring(with: pages[n - 1].range)
    }

    /// 原文 offset 在第几页（空行算上一页的尾巴）；稿子是空的就是 1。
    func number(at offset: Int) -> Int {
        pages.last { $0.range.location <= offset }?.number ?? 1
    }

    /// 第 n 页的话在原文里从哪开始；还没写到这一页，就是文末。
    func start(ofPage n: Int) -> Int {
        pages.indices.contains(n - 1) ? pages[n - 1].range.location : (text as NSString).length
    }

    /// 原文 offset 念到第 page 页那一段里的哪里（这一页还没念到是 nil，念完了是整段长度）。
    func local(of offset: Int, page: Int) -> Int? {
        guard pages.indices.contains(page - 1) else { return nil }
        let range = pages[page - 1].range
        if offset >= NSMaxRange(range) { return range.length }
        return offset >= range.location ? offset - range.location : nil
    }

    /// 把第 n 页的话换成 body，其余的页不动。
    func setting(_ body: String, forPage n: Int) -> String {
        var all = (0..<max(n, pages.count)).map { text(ofPage: $0 + 1) }
        all[n - 1] = body
        return PagedScript.compose(all)
    }

    /// 往第 n 页那一行粘贴一段带空行的话（整篇稿子）：空一行就到下一页。第一段接在光标前面，最后一段后面接上这一行光标后面的字；
    /// 中间的段落先填进后面紧跟着的空页（幻灯片还没写话的那几页），不够了才把后面的页往下挤。
    /// 没有空行（就是一页里的话）返回 nil，照普通粘贴。返回新的原文，和光标该去哪一页、那一页里的哪里。
    func pasting(_ pasted: String, intoPage n: Int, replacing selection: NSRange) -> (text: String, page: Int, local: Int)? {
        let trimmed = pasted.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = PagedScript(text: trimmed)
        guard n >= 1, source.pages.count > 1 else { return nil }
        let chunks = (1...source.pages.count).map { source.text(ofPage: $0) }
        let current = text(ofPage: n) as NSString
        let start = min(max(0, selection.location), current.length)
        let end = min(current.length, start + max(0, selection.length))
        var inserted = chunks
        inserted[0] = current.substring(to: start) + inserted[0]
        inserted[inserted.count - 1] += current.substring(from: end)
        let all = (0..<max(n, pages.count)).map { text(ofPage: $0 + 1) }
        var following = Array(all[n...])
        var spare = chunks.count - 1
        while spare > 0, let first = following.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            following.removeFirst()
            spare -= 1
        }
        let result = PagedScript.compose(Array(all[..<(n - 1)]) + inserted + following)
        return (result, n + chunks.count - 1, (chunks[chunks.count - 1] as NSString).length)
    }

    /// 一页一段拼回原文：页和页之间空一行，没话说的页多空一行，一页里面的空行去掉。
    static func compose(_ pages: [String]) -> String {
        var pages = pages.map(lines)
        while let last = pages.last, last.isEmpty { pages.removeLast() }
        var out: [String] = []
        for (index, page) in pages.enumerated() {
            if index > 0 { out.append("") }
            out.append(contentsOf: page)
        }
        return out.joined(separator: "\n")
    }

    /// 一页里不空的行。
    static func lines(_ body: String) -> [String] {
        body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 以前那种「## 第 N 页」分页的稿子，换成一页一段。返回第一行的「# 标题」（有的话）和每一页的话。
    static func fromHeadings(_ text: String) -> (title: String?, pages: [String])? {
        let script = Script(text: text)
        guard !script.pages.isEmpty else { return nil }
        let ns = text as NSString
        var bodies: [Int: [String]] = [:]
        for (index, page) in script.pages.enumerated() {
            let heading = ns.lineRange(for: NSRange(location: page.raw, length: 0))
            let end = index + 1 < script.pages.count ? script.pages[index + 1].raw : ns.length
            let body = ns.substring(with: NSRange(location: NSMaxRange(heading), length: max(0, end - NSMaxRange(heading))))
            bodies[page.number, default: []].append(contentsOf: lines(body))
        }
        let preamble = ns.substring(to: script.pages[0].raw)
        let title = lines(preamble).first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
        let count = bodies.keys.max() ?? 0
        let pages = (0..<count).map { (bodies[$0 + 1] ?? []).joined(separator: "\n") }
        return (title, pages)
    }
}

// MARK: - 幻灯片改了，稿子跟着走

/// 每一页记下「长相」：页面上的字；没字的页用缩略图的指纹（# 开头）。PDF 换了（插了一页、删了一页、调了顺序），
/// 拿新旧两份的长相对一遍（和对比两份文件的差异一样，按顺序找最像的），稿子跟着原来那一页走。
enum SlideMatch {
    /// 旧的第几页 → 新的第几页（从 1 开始），和真正认出来的有几页（matched）。
    /// 先按顺序找最像的；夹在两个认出来的页中间、新旧都有的页，算是同一页改了字，按顺序配上。剩下的旧页就是删掉了。
    static func align(old: [String], new: [String]) -> (map: [Int: Int], matched: Int) {
        let n = old.count, m = new.count
        guard n > 0, m > 0 else { return ([:], 0) }
        var score = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        var similar = Array(repeating: Array(repeating: 0.0, count: m), count: n)
        for i in 0..<n { for j in 0..<m { similar[i][j] = similarity(old[i], new[j]) } }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                var best = max(score[i + 1][j], score[i][j + 1])
                if similar[i][j] >= threshold { best = max(best, score[i + 1][j + 1] + similar[i][j]) }
                score[i][j] = best
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if similar[i][j] >= threshold, score[i][j] == score[i + 1][j + 1] + similar[i][j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if score[i + 1][j] >= score[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        var map: [Int: Int] = [:]
        for (a, b) in pairs { map[a + 1] = b + 1 }
        // 两个认出来的页之间：新旧都有的，按顺序配上（改了字的页）
        let fences = [(-1, -1)] + pairs + [(n, m)]
        for k in 0..<fences.count - 1 {
            let (oldFrom, newFrom) = fences[k], (oldTo, newTo) = fences[k + 1]
            for step in 0..<max(0, min(oldTo - oldFrom - 1, newTo - newFrom - 1)) {
                map[oldFrom + 1 + step + 1] = newFrom + 1 + step + 1
            }
        }
        return (map, pairs.count)
    }

    static let threshold = 0.5

    /// 两页有多像（0…1）。字：两个字一组，看重合了多少（改了几个字还认得出）；没字的页：缩略图指纹有几位一样。
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let imageA = a.hasPrefix("#"), imageB = b.hasPrefix("#")
        if imageA != imageB { return 0 }
        if imageA {
            guard let x = UInt64(a.dropFirst(), radix: 16), let y = UInt64(b.dropFirst(), radix: 16) else { return 0 }
            return 1 - Double((x ^ y).nonzeroBitCount) / 64
        }
        let x = pairs(a), y = pairs(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        return 2 * Double(x.intersection(y).count) / Double(x.count + y.count)
    }

    private static func pairs(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count > 1 else { return Set(chars.map(String.init)) }
        return Set((0..<chars.count - 1).map { String(chars[$0...$0 + 1]) })
    }

    /// 按对齐结果把一页一段的稿子重排成新的页数。对不上的那些页的话拿出来（removed），多出来的段落（比旧的页数还多）留在最后。
    static func remap(_ text: String, map: [Int: Int], oldCount: Int, newCount: Int) -> (text: String, removed: [String]) {
        let paged = PagedScript(text: text)
        var pages = Array(repeating: "", count: newCount)
        var extra: [String] = []
        var removed: [String] = []
        for page in paged.pages {
            let body = paged.text(ofPage: page.number)
            guard !body.isEmpty else { continue }
            if page.number > oldCount {
                extra.append(body)
            } else if let to = map[page.number], to <= newCount {
                pages[to - 1] = pages[to - 1].isEmpty ? body : pages[to - 1] + "\n" + body
            } else {
                removed.append(body)
            }
        }
        return (PagedScript.compose(pages + extra), removed)
    }
}
