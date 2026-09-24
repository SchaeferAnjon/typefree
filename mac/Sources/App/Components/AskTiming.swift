import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 一次提问的分段耗时。只记数字和模型名，绝不记问题、回答或截图内容。
struct AskTiming {
    /// cursor-toggle / cursor-hold / hold-blank / follow-up
    var trigger = "-"
    var mode = "-"
    var startedAt = Date()
    var transcribeMs = 0
    var captureMs = 0
    var encodeMs = 0
    var screenKB = 0
    var modelStats = ""
    /// 退回纯文本的原因（空 = 带图了）
    var fallback = ""

    mutating func reset(trigger: String, mode: String) {
        self = AskTiming()
        self.trigger = trigger
        self.mode = mode
    }

    func summary(totalMs: Int) -> String {
        var parts = ["trigger=\(trigger)", "mode=\(mode)", "asr=\(transcribeMs)ms"]
        if screenKB > 0 { parts.append("shot=\(captureMs)+\(encodeMs)ms/\(screenKB)KB") }
        if !modelStats.isEmpty { parts.append(modelStats) }
        if !fallback.isEmpty { parts.append("textOnly=\(fallback)") }
        parts.append("total=\(totalMs)ms")
        return parts.joined(separator: " ")
    }
}
