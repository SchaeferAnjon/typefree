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

/// WKUserContentController 会强引用消息处理者；用这个弱转发壳避免 WKWebView ↔ 视图互相持有而泄漏
private final class WeakScriptMessageForwarder: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

final class WhatsNewGuideView: NSView, WKScriptMessageHandler, WKNavigationDelegate {
    /// 走完最后一步后回调（点「开始使用」/「完成」）；页面加载失败、Web 进程被杀、按「跳过」/Esc 也走这里，
    /// 引导绝不能把设置窗盖死
    var onFinish: (() -> Void)?

    private static let messageName = "guide"
    private var webView: WKWebView!
    private var skipButton: NSButton!
    private var pendingCommand: String?
    private var loaded = false
    private var finished = false
    private var keyMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptMessageForwarder(target: self), name: Self.messageName)
        let web = WKWebView(frame: bounds, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")   // 底色由 HTML 按浅色/深色自己画，跟随窗口外观
        web.navigationDelegate = self
        addSubview(web)
        webView = web

        // 逃生口：右上角低调的「跳过」；Esc 同样能关
        let skip = NSButton(title: "跳过", target: self, action: #selector(skipTapped))
        skip.isBordered = false
        skip.bezelStyle = .inline
        skip.font = NSFont.systemFont(ofSize: 12)
        skip.contentTintColor = .tertiaryLabelColor
        skip.toolTip = "跳过引导（Esc）"
        skip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(skip, positioned: .above, relativeTo: web)
        NSLayoutConstraint.activate([
            skip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            skip.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])
        skipButton = skip

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.window, self.window != nil else { return event }
            self.finish(reason: "esc")
            return nil
        }

        if let url = Bundle.main.url(forResource: "WhatsNewGuide", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // 资源缺失：不能留一块空白遮罩
            DispatchQueue.main.async { [weak self] in self?.finish(reason: "resource missing") }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// - Parameters:
    ///   - feature: 直接跳到哪个功能的第一步
    ///   - finishTitle: 末步按钮文案；首次引导「开始使用」，从探索页打开「完成」
    ///   - onlyThisFeature: 只走这一个功能的动作（探索页「看演示」），不串到别的功能
    func present(feature: WhatsNewGuide.Feature, finishTitle: String, onlyThisFeature: Bool = false) {
        finished = false
        let cmd = "window.__guide && window.__guide.go(\(feature.rawValue), \(Self.jsString(finishTitle)), \(onlyThisFeature))"
        if loaded { webView.evaluateJavaScript(cmd) } else { pendingCommand = cmd }
    }

    /// 从窗口上摘下来前调用：停掉页面动画、解开消息处理者的引用、卸掉键盘监听
    func tearDown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if loaded { webView.evaluateJavaScript("window.__guide && window.__guide.stop && window.__guide.stop()") }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
        webView.navigationDelegate = nil
    }

    @objc private func skipTapped() { finish(reason: "skip button") }

    /// 统一出口：只回调一次
    private func finish(reason: String) {
        guard !finished else { return }
        finished = true
        NSLog("[WhatsNewGuide] finished: %@", reason)
        onFinish?()
    }

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName, let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        if type == "done" { finish(reason: "done") }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let cmd = pendingCommand {
            pendingCommand = nil
            webView.evaluateJavaScript(cmd)
        }
    }

    // 页面加载不出来 / Web 进程没了：视为看完，别让空白遮罩盖住设置窗
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(reason: "provisional load failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(reason: "load failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(reason: "web content process terminated")
    }
}
