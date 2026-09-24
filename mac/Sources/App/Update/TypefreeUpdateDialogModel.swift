import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

struct TypefreeUpdateDialogModel {
    let badge: String
    let title: String
    let subtitle: String
    let versionText: String
    let notesTitle: String
    let notes: String
    let notesIsHTML: Bool          // 更新说明是 appcast 的 HTML → 富文本渲染；错误信息是纯文本
    let primaryTitle: String
    let secondaryTitle: String?
    let primaryEnabled: Bool
    let isError: Bool
}
