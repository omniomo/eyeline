import XCTest

final class PagedScriptTests: XCTestCase {
    func testBlankLineTurnsThePage() {
        let paged = PagedScript(text: "大家好\n今天聊提词器\n\n第二页的话\n\n\n第四页")
        XCTAssertEqual(paged.pages.count, 4)
        XCTAssertEqual(paged.text(ofPage: 1), "大家好\n今天聊提词器")
        XCTAssertEqual(paged.text(ofPage: 2), "第二页的话")
        XCTAssertEqual(paged.text(ofPage: 3), "")
        XCTAssertEqual(paged.text(ofPage: 4), "第四页")
        XCTAssertEqual(paged.number(at: 15), 2)
    }

    func testSettingOnePageKeepsTheOthers() {
        let paged = PagedScript(text: "一\n\n二")
        XCTAssertEqual(paged.setting("三三\n\n还是三", forPage: 3), "一\n\n二\n\n三三\n还是三")
        XCTAssertEqual(paged.setting("", forPage: 1), "\n二")
        XCTAssertEqual(PagedScript(text: "\n二").text(ofPage: 2), "二")
        XCTAssertEqual(PagedScript(text: "\n二").text(ofPage: 1), "")
    }

    func testOldHeadingsBecomePages() {
        let converted = PagedScript.fromHeadings("# 发布会\n\n## 第 1 页 · 开场\n大家好\n\n## 第 3 页\n三\n")
        XCTAssertEqual(converted?.title, "发布会")
        XCTAssertEqual(converted?.pages, ["大家好", "", "三"])
    }

    func testPastingAWholeScriptFillsTheEmptyRows() {
        // 4 页幻灯片，第 1 页写了一句，后面还没写；在第 1 行末尾粘贴三段
        let script = PagedScript(text: "开场")
        let pasted = script.pasting("第一段\n\n第二段\n接着第二段\n\n第三段\n", intoPage: 1, replacing: NSRange(location: 2, length: 0))
        XCTAssertEqual(pasted?.text, "开场第一段\n\n第二段\n接着第二段\n\n第三段")
        XCTAssertEqual(pasted?.page, 3)
        // 后面的页有话：先填中间的空页，不够了才往下挤；光标后面的字接在最后一段后面
        let busy = PagedScript(text: "一\n\n\n三\n\n四")
        let spread = busy.pasting("A\n\nB\n\nC", intoPage: 1, replacing: NSRange(location: 0, length: 0))
        XCTAssertEqual(spread?.text, "A\n\nB\n\nC一\n\n三\n\n四")
        XCTAssertEqual(spread?.page, 3)
        // 没有空行：普通粘贴
        XCTAssertNil(busy.pasting("一句话\n第二行", intoPage: 1, replacing: NSRange(location: 0, length: 0)))
    }

    func testInsertedSlideMovesTheLines() {
        let old = ["开场白你好", "为什么做这个", "数据和结论", "谢谢大家"]
        let new = ["开场白你好", "新插的一页内容", "为什么做这个", "数据和结论（改了一点）", "谢谢大家"]
        let (map, matched) = SlideMatch.align(old: old, new: new)
        XCTAssertEqual(map, [1: 1, 2: 3, 3: 4, 4: 5])
        XCTAssertEqual(matched, 4)
        let result = SlideMatch.remap("一\n\n二\n\n三\n\n四", map: map, oldCount: 4, newCount: 5)
        XCTAssertEqual(result.text, "一\n\n\n二\n\n三\n\n四")
        XCTAssertEqual(result.removed, [])
    }

    func testDeletedSlideSetsItsLinesAside() {
        let map = SlideMatch.align(old: ["封面标题", "#00000000ffffffff", "结尾谢谢"], new: ["封面标题", "结尾谢谢"]).map
        XCTAssertEqual(map, [1: 1, 3: 2])
        let result = SlideMatch.remap("一\n\n二\n\n三\n\n多出来的", map: map, oldCount: 3, newCount: 2)
        XCTAssertEqual(result.text, "一\n\n三\n\n多出来的")
        XCTAssertEqual(result.removed, ["二"])
    }

    func testRewrittenSlideKeepsItsLines() {
        let (map, matched) = SlideMatch.align(old: ["开场白你好", "旧的说法完全不一样", "谢谢大家"],
                                              new: ["开场白你好", "全新的一页重写过", "谢谢大家"])
        XCTAssertEqual(map, [1: 1, 2: 2, 3: 3])
        XCTAssertEqual(matched, 2)
    }
}
