import Cocoa
import WebKit

/// 3.0 新功能引导：`Resources/WhatsNewGuide.html` 里的动画演示（鼠标长按说话 / 随时问 AI / 语音翻译）。
/// 不单独开窗：盖在设置主窗口的内容上，尺寸随窗口；没看完不能进正式页面（看完记版本号）。
/// 之后可从「设置 → 探索」的「看演示」再打开并跳到对应功能。动画、步骤、文案全在 HTML 里。
enum WhatsNewGuide {
    /// 引导对应的功能版本；升一次大版本、加了新手势再改这个值，老用户会再看到一次
    static let version = "3.0"
    private static let seenKey = "WhatsNewGuideSeenVersion"

    static var hasSeen: Bool { UserDefaults.standard.string(forKey: seenKey) == version }
    static func markSeen() { UserDefaults.standard.set(version, forKey: seenKey) }

    enum Feature: Int { case mouseHold = 0, ask = 1, translation = 2 }
}

final class WhatsNewGuideView: NSView, WKScriptMessageHandler, WKNavigationDelegate {
    /// 走完最后一步后回调（点「开始使用」/「完成」）
    var onFinish: (() -> Void)?

    private var webView: WKWebView!
    private var pendingCommand: String?
    private var loaded = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "guide")
        let web = WKWebView(frame: bounds, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")   // 底色由 HTML 按浅色/深色自己画，跟随窗口外观
        web.navigationDelegate = self
        if let url = Bundle.main.url(forResource: "WhatsNewGuide", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        addSubview(web)
        webView = web
    }

    required init?(coder: NSCoder) { fatalError() }

    /// - Parameters:
    ///   - feature: 直接跳到哪个功能的第一步
    ///   - finishTitle: 末步按钮文案；首次引导「开始使用」，从探索页打开「完成」
    ///   - onlyThisFeature: 只走这一个功能的动作（探索页「看演示」），不串到别的功能
    func present(feature: WhatsNewGuide.Feature, finishTitle: String, onlyThisFeature: Bool = false) {
        let cmd = "window.__guide && window.__guide.go(\(feature.rawValue), \(Self.jsString(finishTitle)), \(onlyThisFeature))"
        if loaded { webView.evaluateJavaScript(cmd) } else { pendingCommand = cmd }
    }

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "guide", let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        if type == "done" { onFinish?() }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let cmd = pendingCommand {
            pendingCommand = nil
            webView.evaluateJavaScript(cmd)
        }
    }
}
