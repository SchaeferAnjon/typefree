import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension SettingsWindowController {
    /// 反馈页不走通用的「内容多长页面多长」滚动：列表/对话区自己滚、输入区钉在底部，整页正好填满窗口。
    /// 页头由 SupportChatView 自己画（列表页带「提交工单」按钮，详情页是工单标题）。
    func buildSupportScroll() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        let chat = SupportChatView(theme: theme, context: SupportChatView.Context(
            latestTranscript: { [weak self] in
                guard let self, let e = self.historyStore.load(limit: 1).first else { return nil }
                let audio = e.audioFile.flatMap { self.audioStore.loadData(fileName: $0) }
                return (asr: e.asr, output: e.output, audio: audio)
            },
            recentApp: { [weak self] in self?.settingsDelegate?.recentTargetAppName() },
            logTail: { [weak self] in self?.settingsDelegate?.debugLogTail() ?? "" }
        ))
        supportChatView = chat
        SupportChatView.log = { [weak self] in self?.settingsDelegate?.debugLog($0) }
        doc.addSubview(chat)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            chat.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 56),
            // 右边多给一条滚动条空隙：内容仍与其它页面一样离右边 56，浮着的滚动条落在空隙里
            chat.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -56 + SupportChatView.scrollerGutter),
            chat.topAnchor.constraint(equalTo: doc.topAnchor, constant: 36),
            chat.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -32),
            chat.widthAnchor.constraint(lessThanOrEqualToConstant: 880 + SupportChatView.scrollerGutter),
        ])
        if supportObserver == nil {
            supportObserver = NotificationCenter.default.addObserver(forName: SupportChatService.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.rebuildSidebar()   // 角标跟着未读数变
            }
        }
        return scroll
    }
}
