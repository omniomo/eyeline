import Foundation

// MARK: - 念出来的最小单位
//
// 中文、日文、韩文一个字算一个；拉丁字母和数字连在一起的一串算一个词。
// 标点、空格不算。稿子和语音识别出来的字用同一套规则拆，才能对得上。

struct Unit: Equatable {
    /// 比较用：小写，只留字母和数字。
    var key: String
    /// 汉字的拼音（不带声调），用来认同音字。
    var sound: String?
    /// 更宽的读音：平翘舌、前后鼻音、n/l 不分。
    var looseSound: String?
    /// 拉丁字母的词（不是单个汉字）。
    var isWord: Bool

    /// 两个单位有多像：2 一样，1.6 同音，1 读音接近，1.2 / 1 拼写接近，-1 不一样。
    func similarity(to other: Unit) -> Double {
        if key == other.key { return 2 }
        if let a = sound, let b = other.sound {
            if a == b { return 1.6 }
            if let la = looseSound, let lb = other.looseSound, la == lb { return 1 }
            return -1
        }
        if isWord && other.isWord {
            let shorter = min(key.count, other.key.count)
            if shorter >= 4 {
                if key.hasPrefix(other.key) || other.key.hasPrefix(key) { return 1 }
                if shorter >= 5 && Tokenizer.editDistance(key, other.key, limit: 1) <= 1 { return 1.2 }
            }
        }
        return -1
    }
}

enum Tokenizer {
    /// 一个字符串里所有能念的单位，带着它们在字符串里（UTF-16）的位置。
    static func units(in string: String) -> [(unit: Unit, range: NSRange)] {
        var result: [(Unit, NSRange)] = []
        let ns = string as NSString
        var word = ""
        var wordStart = 0
        var wordEnd = 0

        func flush() {
            guard !word.isEmpty else { return }
            result.append((Unit(key: word, sound: nil, looseSound: nil, isWord: true),
                           NSRange(location: wordStart, length: wordEnd - wordStart)))
            word = ""
        }

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byComposedCharacterSequences) { sub, range, _, _ in
            guard let sub, let scalar = sub.unicodeScalars.first else { return }
            if isSyllabic(scalar) {
                flush()
                let character = Character(sub)
                let sound = isHan(scalar) ? Pinyin.sound(of: character) : nil
                result.append((Unit(key: sub, sound: sound, looseSound: sound.map(Pinyin.loosen), isWord: false), range))
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                if word.isEmpty { wordStart = range.location }
                word += sub.lowercased()
                wordEnd = range.location + range.length
            } else if (sub == "'" || sub == "’") && !word.isEmpty {
                // don't → dont
                wordEnd = range.location + range.length
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    static func keys(in string: String) -> [Unit] { units(in: string).map(\.unit) }

    /// 汉字、假名、谚文：一个字就是一个单位。
    static func isSyllabic(_ scalar: Unicode.Scalar) -> Bool {
        isHan(scalar) || (0x3040...0x30FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
    }

    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2A6DF).contains(v)
            || (0xF900...0xFAFF).contains(v)
    }

    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [Int](repeating: 0, count: b.count + 1)
            current[0] = i
            var rowMin = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}

// MARK: - 拼音

enum Pinyin {
    private static var cache: [Character: String] = [:]
    private static let lock = NSLock()

    /// 一个汉字的拼音，不带声调。多音字取系统给的那一个。
    static func sound(of character: Character) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[character] { return hit }
        let text = NSMutableString(string: String(character))
        CFStringTransform(text, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(text, nil, kCFStringTransformStripDiacritics, false)
        let sound = (text as String).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        cache[character] = sound
        return sound
    }

    /// zh/z、ch/c、sh/s，ing/in、eng/en，n/l 当成一样。
    static func loosen(_ sound: String) -> String {
        var s = sound
        for (from, to) in [("zh", "z"), ("ch", "c"), ("sh", "s")] where s.hasPrefix(from) {
            s = to + s.dropFirst(from.count)
        }
        if s.hasPrefix("l") { s = "n" + s.dropFirst() }
        if s.hasSuffix("ing") { s = String(s.dropLast()) }
        else if s.hasSuffix("eng") { s = String(s.dropLast()) }
        return s
    }
}
