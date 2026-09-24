import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

// MARK: - 更新说明渲染

/// 更新说明（appcast 里的 HTML：h3 小标题 / p 段落 / ul-li 要点 / strong）→ 富文本。
/// 「发现新版本」弹窗（AppDelegate）与设置里的「更新历史」共用，保证两处排版一致。
/// 排版按中文阅读调：行距 1.9（中文比英文更需要行距）、小标题与正文明确拉开层次、
/// 段落与列表项之间留白，避免整段糊成一片。
enum ReleaseNotesRenderer {
    static func attributed(fromHTML html: String,
                           bodyColor: NSColor,
                           headingColor: NSColor,
                           fontSize: CGFloat = 13) -> NSAttributedString? {
        // 颜色写进 CSS 而不是事后整段染色——否则小标题和正文只能是同一个颜色，层次就没了。
        let styled = """
        <style>
        body{font-family:-apple-system;font-size:\(fontSize)px;line-height:1.9;margin:0;color:\(bodyColor.cssHex)}
        h3{font-size:\(fontSize + 1)px;font-weight:600;color:\(headingColor.cssHex);margin:26px 0 10px;line-height:1.5}
        h3:first-child{margin-top:2px}
        p{margin:0 0 14px}
        ul{margin:0 0 14px 0;padding-left:18px}
        li{margin:0 0 8px;padding-left:2px}
        li:last-child{margin-bottom:0}
        strong{font-weight:600;color:\(headingColor.cssHex)}
        </style>
        \(html)
        """
        guard let data = styled.data(using: .utf8) else { return nil }
        return NSMutableAttributedString(
            html: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
    }
}
