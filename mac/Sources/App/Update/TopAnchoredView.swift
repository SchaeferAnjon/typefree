import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 翻转坐标的容器：作为 NSScrollView 的 documentView 时内容从顶部开始显示。
final class TopAnchoredView: NSView {
    override var isFlipped: Bool { true }
}
