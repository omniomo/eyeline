import XCTest

final class ScriptTests: XCTestCase {
    func testNotesPausesAndWarnings() {
        let script = Script(text: "9. 左边是我，右边，⏸ 也是我。⚠️ 确认能不能换成自己的头像")
        XCTAssertEqual(script.tokens.map(\.unit.key).joined(), "左边是我右边也是我")
        XCTAssertEqual(script.pauses[6], 1)
        XCTAssertTrue(script.display.contains("\u{2016}"))
        XCTAssertTrue(script.display.unicodeScalars.contains("\u{26A0}"))
        XCTAssertFalse(script.display.hasPrefix("9"))
    }

    func testBracketsHeadingsTablesAndCuts() {
        let text = """
        ### 开头
        7. 微信、iMessage、WhatsApp。（念快，一个名字切一个皮）
        | 句 | 花字 |
        13. 夸我的、催更的，全是我一个人。✂
        > 开头的备选
        """
        let script = Script(text: text)
        XCTAssertEqual(script.tokens.map(\.unit.key).joined(separator: " "),
                       "微 信 imessage whatsapp 夸 我 的 催 更 的 全 是 我 一 个 人")
        XCTAssertTrue(script.display.contains("开头"))
        XCTAssertFalse(script.display.contains("花字"))
        XCTAssertFalse(script.display.contains("\u{2702}"))

        let skipped = Script(text: text, skipCuts: true)
        XCTAssertFalse(skipped.display.contains("催更"))
    }

    func testSentencesAndRawOffsets() {
        let text = "第一句。第二句！\nThird one. Fourth"
        let script = Script(text: text)
        XCTAssertEqual(script.sentences.count, 4)
        XCTAssertEqual(script.sentences[1].firstToken, 3)
        let fourth = script.sentences[3].firstToken
        XCTAssertEqual((text as NSString).substring(with: script.tokens[fourth].raw), "Fourth")
        XCTAssertEqual(script.token(atRaw: (text as NSString).range(of: "第二").location), 3)
        XCTAssertEqual(script.rawOffset(ofToken: script.count), (text as NSString).length)
    }

    func testPinyin() {
        XCTAssertEqual(Pinyin.sound(of: "朋"), "peng")
        XCTAssertEqual(Unit(key: "在", sound: "zai", looseSound: "zai", isWord: false)
            .similarity(to: Tokenizer.keys(in: "再")[0]), 1.6)
    }
}

final class TrackerTests: XCTestCase {
    let mimic = """
    如果你需要 mock 一张假聊天截图，
    如果你跟我一样，没朋友，⏸
    你可能需要 Mimic。
    有朋友的人，找个朋友聊两句，截下来就行。
    没朋友的人，只能自己跟自己聊。
    Mimic 就是让你自己跟自己聊，还聊得特别像。
    """

    /// 像语音识别那样，一次多几个字地把说过的话交给 tracker。
    @discardableResult
    func read(_ spoken: String, into tracker: inout Tracker, already: String = "", step: Int = 2) -> [Int] {
        var positions: [Int] = []
        let characters = Array(spoken)
        var count = 0
        while count < characters.count {
            count = min(characters.count, count + step)
            if let p = tracker.hear(already + String(characters[0..<count])) { positions.append(p) }
        }
        return positions
    }

    func plain(_ text: String) -> String {
        Script(text: text).tokens.map(\.unit.key).joined()
    }

    func testFollowsCleanReading() {
        let script = Script(text: mimic)
        var tracker = Tracker(script: script)
        let positions = read(plain(mimic), into: &tracker)
        XCTAssertEqual(tracker.position, script.count)
        XCTAssertEqual(positions, positions.sorted(), "never moves backward")
    }

    func testHomophonesAndSmallMistakes() {
        let script = Script(text: mimic)
        var tracker = Tracker(script: script)
        var heard = plain(mimic)
        heard = heard.replacingOccurrences(of: "朋友", with: "鹏有")
            .replacingOccurrences(of: "截图", with: "姐图")
            .replacingOccurrences(of: "只能", with: "只")
            .replacingOccurrences(of: "mimic", with: "米米克")
        read(heard, into: &tracker)
        XCTAssertGreaterThanOrEqual(tracker.position, script.count - 2)
    }

    func testOffScriptDoesNotMove() {
        let script = Script(text: mimic)
        var tracker = Tracker(script: script)
        read("今天天气真不错我们出去走走吧", into: &tracker)
        XCTAssertLessThanOrEqual(tracker.position, 1)
    }

    func testRetakeJumpsBackToSentenceStart() {
        let script = Script(text: mimic)
        var tracker = Tracker(script: script)
        let first = "如果你需要mock一张假聊天截图如果你跟我一样没朋友你可能需要mimic有朋友的人找个朋友"
        read(first, into: &tracker)
        let fourth = script.sentences[3].firstToken
        XCTAssertGreaterThan(tracker.position, fourth + 4)

        // 说错了，从「有朋友的人」重新念。
        read("有朋友的人找个", into: &tracker, already: first)
        XCTAssertLessThanOrEqual(tracker.position, fourth + 8)
        XCTAssertGreaterThanOrEqual(tracker.position, fourth + 4)

        let again = first + "有朋友的人找个"
        read("朋友聊两句截下来就行没朋友的人", into: &tracker, already: again)
        XCTAssertGreaterThan(tracker.position, script.sentences[4].firstToken + 3)
    }

    /// 真实识别里看到的：重念「有朋友的人」时，不能先跳到后面的「没朋友的人」再跳回来。
    func testRetakeDoesNotJumpAheadFirst() {
        let script = Script(text: mimic)
        var tracker = Tracker(script: script)
        let first = "如果你需要一张甲聊天截图如果你跟我一样没朋友你可能需要秘密有朋友的人交个朋友"
        read(first, into: &tracker)
        let before = tracker.position
        let positions = read("有朋友的人找个朋友聊两句", into: &tracker, already: first, step: 1)
        XCTAssertFalse(positions.contains { $0 >= script.sentences[4].firstToken }, "jumped ahead: \(positions)")
        XCTAssertLessThan(positions.first ?? before, before)
    }

    func testSkippingASentence() {
        let script = Script(text: mimic)
        var tracker = Tracker(script: script)
        read("如果你需要mock一张假聊天截图", into: &tracker)
        // 跳过第二、三句。
        read("有朋友的人找个朋友聊两句截下来就行", into: &tracker, already: "如果你需要mock一张假聊天截图")
        XCTAssertEqual(tracker.position, script.sentences[4].firstToken)
    }

    func testRepeatedOpeningsDoNotConfuse() {
        let script = Script(text: mimic)
        var tracker = Tracker(script: script)
        let s1 = "如果你需要mock一张假聊天截图"
        read(s1, into: &tracker)
        read("如果你跟我一样", into: &tracker, already: s1)
        XCTAssertEqual(tracker.position, script.sentences[1].firstToken + 7)
    }

    func testEnglish() {
        let text = "If you need a fake chat screenshot, and you have no friends like me, you might need Mimic."
        let script = Script(text: text)
        var tracker = Tracker(script: script)
        var spoken = ""
        for word in ["if", "you", "need", "a", "fake", "chats", "screen", "shot", "and", "you", "have", "no", "friends",
                     "like", "me", "you", "might", "need", "mimic"] {
            spoken += word + " "
            _ = tracker.hear(spoken)
        }
        XCTAssertEqual(tracker.position, script.count)
    }

    func testStartsFromTheMiddle() {
        let script = Script(text: mimic)
        let start = script.sentences[4].firstToken
        var tracker = Tracker(script: script, position: start)
        read("没朋友的人只能自己", into: &tracker)
        XCTAssertEqual(tracker.position, start + 9)
    }
}
