import AppKit
import PDFKit
import WebKit

// MARK: - PowerPoint 变成一页一页的图（不用装 PowerPoint / Keynote）
//
// 系统自带的 Quick Look（qlmanage）能把 .pptx 变成一个网页，每一页是一个 div.slide，图片放在旁边。
// 在一个看不见的网页视图里打开它，一页一页画成 PDF，存在「应用程序支持/Eyeline/Slides」里，再配给稿子。
// 看起来和在访达里按空格预览一样（动画、特效没有，少数字体会换成相近的）。

@MainActor
final class SlideRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var completion: ((Result<URL, Error>) -> Void)?
    private var folder: URL?
    /// 正在画的那个（画完之前留着它）。
    private static var running: SlideRenderer?

    static func render(_ pptx: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let renderer = SlideRenderer()
        running = renderer
        renderer.completion = completion
        renderer.start(pptx)
    }

    private func start(_ url: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eyeline-slides-" + UUID().uuidString)
        self.folder = folder
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            process.arguments = ["-p", "-o", folder.path, url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            let preview = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                .first { $0.pathExtension == "qlpreview" }?.appendingPathComponent("Preview.html")
            DispatchQueue.main.async { self.load(preview) }
        }
    }

    private func load(_ html: URL?) {
        guard let html, FileManager.default.fileExists(atPath: html.path) else {
            Log.info("slides: quick look made no preview")
            finish(.failure(SlideImport.Failure.unreadable))
            return
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        webView.navigationDelegate = self
        self.webView = webView
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await capture() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    /// 去掉页和页之间的空隙、阴影、灰底，量出每一页在哪，一页一页画成 PDF。
    private func capture() async {
        guard let webView else { return }
        let script = """
        (() => {
          const style = document.createElement('style');
          style.textContent = 'body{margin:0!important;background:#fff!important}' +
            'div.slide{margin:0!important;-webkit-box-shadow:none!important;box-shadow:none!important}' +
            'div.loading-slide{display:none!important}';
          document.head.appendChild(style);
          return Array.from(document.querySelectorAll('div.slide')).map(e => {
            const r = e.getBoundingClientRect();
            return [r.left + window.scrollX, r.top + window.scrollY, r.width, r.height];
          });
        })()
        """
        do {
            let value = try await webView.evaluateJavaScript(script)
            let rects = (value as? [Any] ?? []).compactMap { item -> CGRect? in
                guard let numbers = item as? [Any] else { return nil }
                let values = numbers.compactMap { ($0 as? NSNumber)?.doubleValue }
                guard values.count == 4, values[2] > 0, values[3] > 0 else { return nil }
                return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            }
            guard !rects.isEmpty else { throw SlideImport.Failure.unreadable }
            // 视图要和整个网页一样大，下面几页才画得出来
            webView.frame.size = NSSize(width: max(1000, rects.map(\.maxX).max() ?? 1000), height: rects.map(\.maxY).max() ?? 800)
            try await Task.sleep(nanoseconds: 200_000_000)
            let output = PDFDocument()
            for rect in rects {
                let configuration = WKPDFConfiguration()
                configuration.rect = rect
                let data = try await webView.pdf(configuration: configuration)
                if let page = PDFDocument(data: data)?.page(at: 0) { output.insert(page, at: output.pageCount) }
            }
            guard output.pageCount > 0 else { throw SlideImport.Failure.unreadable }
            let slides = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Eyeline/Slides", isDirectory: true)
            try FileManager.default.createDirectory(at: slides, withIntermediateDirectories: true)
            let url = slides.appendingPathComponent(UUID().uuidString + ".pdf")
            guard output.write(to: url) else { throw SlideImport.Failure.unreadable }
            Log.info("slides: rendered \(output.pageCount) slides with quick look")
            finish(.success(url))
        } catch {
            Log.info("slides: quick look rendering failed \(error)")
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        webView = nil
        completion?(result)
        completion = nil
        SlideRenderer.running = nil
    }
}
