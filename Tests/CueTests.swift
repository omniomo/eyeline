import XCTest

final class CueTests: XCTestCase {
    func testBoldWordsAreTheKeywords() {
        let text = """
        # 开头
        1. 比尔·盖茨说过一句话：**最懒的人** ⏱8
        2. 不过，**没人找得到**他说过这句话。**1947** ⏱1:30
        3. 这一句没有加粗。
        """
        let cues = Cues(text: text)
        XCTAssertTrue(cues.fromBold)
        XCTAssertEqual(cues.items.map(\.text), ["最懒的人", "没人找得到", "1947"])
        XCTAssertEqual(cues.items.map(\.seconds), [8, nil, 90])
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: cues.items[1].raw, length: 5)), "没人找得到")
    }

    func testOneKeywordPerLineWithoutAScript() {
        let text = """
        ## 提纲
        - 名言打假
        - 1947 听证会 ⏱20s
        - 算账：勤快人 vs 懒人 ⏱2分
        （这里自由发挥）
        ---
        Oloop
        """
        let cues = Cues(text: text)
        XCTAssertFalse(cues.fromBold)
        XCTAssertEqual(cues.items.map(\.text), ["名言打假", "1947 听证会", "算账：勤快人 vs 懒人", "Oloop"])
        XCTAssertEqual(cues.items.map(\.seconds), [nil, 20, 120, nil])
        XCTAssertEqual(cues.timed, 140)
    }

    func testCursorPicksTheKeywordItIsIn() {
        let text = "第一个\n第二个\n第三个"
        let cues = Cues(text: text)
        XCTAssertEqual(cues.index(atRaw: 0), 0)
        XCTAssertEqual(cues.index(atRaw: (text as NSString).range(of: "二").location), 1)
        XCTAssertEqual(cues.index(atRaw: (text as NSString).length), 2)
    }

    func testCutsAreSkippedWhenAsked() {
        let text = "要说的\n可以删的 ✂\n最后一个"
        XCTAssertEqual(Cues(text: text).count, 3)
        XCTAssertEqual(Cues(text: text, skipCuts: true).items.map(\.text), ["要说的", "最后一个"])
    }

    func testPagesFollowSlideHeadings() {
        let text = "# 标题\n## 第 1 页 · 开场\n大家好\n## Slide 2\n第二页的话\n## P3\n三\n## Pricing\n四"
        let script = Script(text: text)
        XCTAssertEqual(script.pages.map(\.number), [1, 2, 3])
        XCTAssertEqual(script.tokens[script.token(atRaw: script.pages[1].raw)].unit.key, "第")
        XCTAssertNil(Script.pageNumber("## Pricing"))
    }
}
