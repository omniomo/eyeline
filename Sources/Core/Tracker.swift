import Foundation

// MARK: - 跟读
//
// 语音识别每次给的是这一段说过的全部文字。我们只看最后十来个字，
// 在稿子当前位置附近找最像的一段（允许漏字、多字、同音字），
// 找到就把位置推到那一段的末尾。
//
// - 往前走一小步：直接走。
// - 往前跳很远（跳过了一句）：要连着两次都这么认为才跳。
// - 往回跳：只在你从某一句的开头重新念的时候（说错了重来）。

struct Tracker {
    let script: Script
    /// 下一个要念的词。
    private(set) var position: Int
    /// 这一段识别结果里，前面这么多个字已经不算数了（跳转之后、重来之后）。
    private var baseline = 0
    private var lastForward: Candidate?
    private var lastRetake: Candidate?
    private var lastSpokenCount = 0

    private struct Candidate {
        var end: Int
        var spokenCount: Int
    }

    init(script: Script, position: Int = 0) {
        self.script = script
        self.position = min(max(0, position), script.count)
    }

    /// 手动换了位置。调用的人同时会重新开始识别，所以识别结果从头算。
    mutating func reset(to position: Int) {
        self.position = min(max(0, position), script.count)
        baseline = 0
        lastForward = nil
        lastRetake = nil
        lastSpokenCount = 0
    }

    /// 识别重新开始了一段（新的识别任务），识别结果从头算。
    mutating func newSegment() {
        baseline = 0
        lastForward = nil
        lastRetake = nil
        lastSpokenCount = 0
    }

    /// 听到一段新的识别结果。位置变了就返回新位置。
    mutating func hear(_ transcript: String) -> Int? {
        hear(units: Tokenizer.keys(in: transcript))
    }

    mutating func hear(units spoken: [Unit]) -> Int? {
        guard !script.isEmpty else { return nil }
        if spoken.count < baseline { baseline = spoken.count }
        let fresh = spoken.count > lastSpokenCount
        lastSpokenCount = spoken.count
        let usable = spoken[baseline...]
        guard usable.count >= 2 else { return nil }

        let currentSentence = script.sentence(ofToken: position)
        let earliest = script.sentences[max(0, currentSentence - 2)].firstToken
        let low = max(0, min(earliest, position - 4), position - 90)
        let high = min(script.count, position + 70)
        guard high > low else { return nil }

        // 1. 说错重来：最后几个字很像前面某一句的开头，而且比往后找更像。
        let short = Array(usable.suffix(5))
        if short.count >= 4, position > 0 {
            let result = align(short, low: low, high: high)
            if let behind = result.best(where: { $0.end <= position - 3 }),
               behind.matches >= 4,
               isSentenceStart(behind.start),
               // 「往后接着念」的解释：只算从当前位置附近开始的匹配，
               // 不算从前面那句开头一路延伸过来的（那其实就是重来的同一段）。
               behind.score >= (result.best(where: { $0.end > position - 3 && $0.start >= position - 6 })?.score
                                ?? -.infinity) + 1.5 {
                let agreed = lastRetake.map { abs($0.end - behind.end) <= 3 && $0.spokenCount < spoken.count } ?? false
                lastRetake = Candidate(end: behind.end, spokenCount: spoken.count)
                if agreed || behind.matches >= 5 && short.count >= 5 && behind.score >= 9 {
                    position = behind.end
                    // 重来之前说的那些不再参与比较，免得又把位置拉回去。
                    baseline = max(baseline, spoken.count - short.count)
                    lastForward = nil
                    lastRetake = nil
                    return position
                }
                // 看着像是在重来，但还要再听一次确认：这一次先别往前跳。
                // （「有朋友的人」重念时，很容易被当成后面的「没朋友的人」。）
                return nil
            } else {
                lastRetake = nil
            }
        }

        // 2. 正常往前。
        let tail = Array(usable.suffix(10))
        let result = align(tail, low: max(low, position - 12), high: high)
        guard let best = result.best(where: { _ in true }) else { return nil }
        let m = tail.count
        let needed = m <= 3 ? m : max(3, (m + 1) / 2)
        guard best.matches >= needed, best.score >= Double(m) * 0.8 else { return nil }
        guard best.end > position else {
            lastForward = nil
            return nil
        }

        let step = best.end - position
        let agreed = lastForward.map { abs($0.end - best.end) <= 3 && $0.spokenCount < spoken.count } ?? false
        lastForward = Candidate(end: best.end, spokenCount: spoken.count)
        let small = m <= 3 ? step <= 3 : step <= 8
        guard small || (fresh && agreed) || best.matches >= 8 else { return nil }
        position = best.end
        return position
    }

    private func isSentenceStart(_ token: Int) -> Bool {
        script.sentences.contains { abs($0.firstToken - token) <= 1 }
    }

    // MARK: 对齐

    struct Match {
        /// 在稿子里匹配到的这一段：[start, end)。
        var start: Int
        var end: Int
        var score: Double
        var matches: Int
    }

    struct Alignment {
        var candidates: [Match]
        let position: Int

        /// 分数最高的；一样高就选离当前位置近的、靠后的。
        func best(where accept: (Match) -> Bool) -> Match? {
            candidates.filter(accept).max { a, b in
                if abs(a.score - b.score) > 0.001 { return a.score < b.score }
                let da = abs(a.end - position), db = abs(b.end - position)
                if da != db { return da > db }
                return a.end < b.end
            }
        }
    }

    /// 把 spoken 整段对到稿子 [low, high) 里的某一段上（稿子这边从哪开始、到哪结束都行）。
    func align(_ spoken: [Unit], low: Int, high: Int) -> Alignment {
        let m = spoken.count
        let n = high - low
        let gapSpoken = 0.8   // 多说了（或者识别多出来）一个字
        let gapScript = 0.7   // 漏念了（或者识别漏了）一个字
        var score = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: m + 1)
        var matches = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        var start = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for j in 0...n { start[0][j] = j }
        for i in 1...max(m, 1) where m > 0 {
            score[i][0] = score[i - 1][0] - gapSpoken
            start[i][0] = 0
            for j in 1...max(n, 1) where n > 0 {
                let s = spoken[i - 1].similarity(to: script.tokens[low + j - 1].unit)
                let diagonal = score[i - 1][j - 1] + s
                let up = score[i - 1][j] - gapSpoken
                let left = score[i][j - 1] - gapScript
                if diagonal >= up && diagonal >= left {
                    score[i][j] = diagonal
                    matches[i][j] = matches[i - 1][j - 1] + (s > 0 ? 1 : 0)
                    start[i][j] = start[i - 1][j - 1]
                } else if up >= left {
                    score[i][j] = up
                    matches[i][j] = matches[i - 1][j]
                    start[i][j] = start[i - 1][j]
                } else {
                    score[i][j] = left
                    matches[i][j] = matches[i][j - 1]
                    start[i][j] = start[i][j - 1]
                }
            }
        }
        var candidates: [Match] = []
        if m > 0 && n > 0 {
            for j in 1...n where matches[m][j] > 0 {
                candidates.append(Match(start: low + start[m][j], end: low + j, score: score[m][j], matches: matches[m][j]))
            }
        }
        return Alignment(candidates: candidates, position: position)
    }
}
