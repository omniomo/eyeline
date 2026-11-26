import AppKit
import Combine
import PDFKit

// MARK: - 幻灯片
//
// 稿子配了幻灯片（一份 PDF）：主窗口里按页写（分镜表，见 Storyboard）或者全文上面一张大图（见 SlideStage）。
// 这里只管读 PDF、现在是第几页、缩略图、每一页的长相。翻页就是在稿子里换到这一页（见 AppModel.deckFlipped）：
// - 没在提词：稿子跟到这一页；在稿子里点到哪一页的话，幻灯片翻到哪一页。
// - 提词时：提词条跳到这一页的开头；翻页笔翻的是这里的页。
// PDF 改了（重新导出、覆盖同一个文件），回到 Eyeline 时重新读。

final class SlideDeck: ObservableObject {
    @Published private(set) var document: PDFDocument?
    /// 现在是第几页（从 1 开始；没有幻灯片是 0）。
    @Published private(set) var page = 0
    @Published private(set) var pageCount = 0
    /// 有人翻到了第几页（从 1 开始）。程序里 go(to:) 翻的不算。
    var onPage: ((Int) -> Void)?
    private(set) var url: URL?
    private var modified: Date?
    private var thumbnails: [Int: (image: NSImage, height: CGFloat)] = [:]
    private var cachedSignatures: [String]?

    var isLoaded: Bool { document != nil }

    /// 第一页的宽高比（横着的幻灯片是 16:9 之类）。
    var aspect: CGFloat {
        guard let first = document?.page(at: 0) else { return 16 / 9 }
        let box = first.bounds(for: .cropBox)
        let size = first.rotation % 180 != 0 ? CGSize(width: box.height, height: box.width) : box.size
        return size.width > 0 && size.height > 0 ? size.width / size.height : 16 / 9
    }

    // MARK: 换 PDF

    /// 换成这份 PDF，翻到第 page 页。同一份、文件没改过就不重新读。读不了返回 false（并清空）。
    @discardableResult
    func load(_ url: URL?, at page: Int) -> Bool {
        guard let url else {
            unload()
            return false
        }
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if url != self.url || stamp != modified || document == nil {
            guard let fresh = PDFDocument(url: url), fresh.pageCount > 0 else {
                Log.info("deck: cannot read \(url.lastPathComponent)")
                unload()
                return false
            }
            self.url = url
            modified = stamp
            thumbnails = [:]
            cachedSignatures = nil
            document = fresh
            pageCount = fresh.pageCount
            self.page = 0
            Log.info("deck: loaded \(url.lastPathComponent), \(fresh.pageCount) pages")
        }
        go(to: page)
        return true
    }

    func unload() {
        guard document != nil || url != nil else { return }
        document = nil
        url = nil
        modified = nil
        thumbnails = [:]
        page = 0
        pageCount = 0
    }

    // MARK: 翻页

    /// 翻到第 number 页（不算有人翻页，不告诉 onPage）。
    func go(to number: Int) {
        guard document != nil, pageCount > 0 else { return }
        let target = min(max(1, number), pageCount)
        guard target != page else { return }
        Log.info("deck: page \(page) → \(target)")
        page = target
    }

    /// 有人翻页：往前 / 往后几页。
    func step(_ delta: Int) {
        select(page + delta)
    }

    /// 有人点了第 number 页（缩略图、Home / End）。
    func select(_ number: Int) {
        guard isLoaded else { return }
        let before = page
        go(to: number)
        if page != before { onPage?(page) }
    }

    /// 第 number 页的缩略图（高 height 点，按两倍画）。
    func thumbnail(_ number: Int, height: CGFloat) -> NSImage? {
        // 画过一样大、或者更大的就直接用；窗口拉大了才重画
        if let hit = thumbnails[number], hit.height >= height - 1 { return hit.image }
        guard let pdfPage = document?.page(at: number - 1) else { return nil }
        let image = pdfPage.thumbnail(of: CGSize(width: height * aspect * 2, height: height * 2), for: .cropBox)
        thumbnails[number] = (image, height)
        return image
    }

    /// 放幻灯片时的大图：刚好铺满 size（按屏幕的像素画，清楚）。只留最近这一张。
    private var rendered: (page: Int, size: CGSize, image: NSImage)?

    func render(_ number: Int, fitting size: CGSize) -> NSImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        if let rendered, rendered.page == number, rendered.size == size { return rendered.image }
        guard let pdfPage = document?.page(at: max(0, number - 1)) else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let fit = min(size.width / aspect, size.height)
        let image = pdfPage.thumbnail(of: CGSize(width: fit * aspect * scale, height: fit * scale), for: .cropBox)
        rendered = (number, size, image)
        return image
    }

    /// 每一页的「长相」（见 SlideMatch）：页面上的字（去掉空白，前 300 个）；没字的页用缩略图的指纹。
    func signatures() -> [String] {
        if let cachedSignatures { return cachedSignatures }
        guard let document else { return [] }
        let result = (0..<document.pageCount).map { index -> String in
            guard let page = document.page(at: index) else { return "" }
            let text = String((page.string ?? "").filter { !$0.isWhitespace }.prefix(300))
            return text.count >= 4 ? text : "#" + SlideDeck.fingerprint(page)
        }
        cachedSignatures = result
        return result
    }

    /// 缩小成 8×8 的灰度图，比平均亮度亮的记 1：64 位，十六进制。
    private static func fingerprint(_ page: PDFPage) -> String {
        let image = page.thumbnail(of: CGSize(width: 32, height: 32), for: .cropBox)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                         samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
                                         bytesPerRow: 8, bitsPerPixel: 8), let data = rep.bitmapData else { return "0" }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 8, height: 8))
        NSGraphicsContext.restoreGraphicsState()
        let values = (0..<64).map { Int(data[$0]) }
        let average = values.reduce(0, +) / 64
        let bits = values.enumerated().reduce(UInt64(0)) { $1.element > average ? $0 | (1 << UInt64($1.offset)) : $0 }
        return String(bits, radix: 16)
    }
}
