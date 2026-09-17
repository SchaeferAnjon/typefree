import Foundation

/// 长按问 AI 的「开口」判定（纯逻辑，从 AppDelegate 抽出来便于测试）。
///
/// 不用固定音量线：麦克风、环境不同，安静时的电平差很多——2026-09-11 MacBook 自带麦人坐得远，静音 0.03～0.05、
/// 说话峰值才 0.05～0.22；2026-09-14 外置麦在家没说话，开麦 0.3s 就有 0.11～0.13，固定线 0.08 次次误判开口。
/// 所以每次录音现定：拿这次录音到目前为止最安静的一帧当基准，响到基准的 `ratio` 倍才算过线（且不低于保底线），
/// 过线的帧累计到 `framesNeeded`（不过线的帧扣 1）才算开口，单帧的键盘、鼠标咔哒声攒不够。
/// 开麦头几帧自己就是基准，底噪、开麦杂音不会被当成开口。判不出来也不丢问题：松手照常识别。
public struct AskSpeechDetector {
    /// 响到基准的多少倍才算过线。2026-09-14 真机：2.5 在屋里较吵时（安静 0.15 左右、说话 0.3～0.4）判不出说话；
    /// 用当天 13 次长按的真实电平复算，1.8 判出全部 6 次说话、7 次没说话 0 误判（2.0、2.2 与 2.5 结果相同）
    static let ratio: Float = 1.8
    /// 保底线：极安静的麦基准接近 0，乘出来的线太低，鼠标、键盘声也会过线
    static let floorLevel: Float = 0.08
    /// 低于它算「没声音」。开麦头几帧可能全是 0（设备还在预热），这时不定基准，否则基准塌成 0、线退回保底线；
    /// 听到过声音之后的「没声音」是真安静（比如降噪麦把门关了），照常算进基准
    static let silenceLevel: Float = 0.01
    static let framesNeeded = 3
    /// 日志最多带前多少帧电平，用来校准 ratio
    static let traceLimit = 40

    private(set) var quietest: Float?
    private var peak: Float = 0
    private var passedFrames = 0
    private var frameCount = 0
    private var trace: [Float] = []

    public init() {}

    /// 当前的过线值
    var line: Float { max(Self.floorLevel, (quietest ?? 0) * Self.ratio) }

    /// 到目前为止有没有哪一帧响到过线值（没攒够帧数、判不出「开口」，但至少响过一下）。
    /// 松手时用来区分「说了话只是没判出来」和「从头到尾没出声的误触」
    public var peakReachedLine: Bool { frameCount > 0 && peak >= line }

    /// 喂一帧电平（0～1）；返回 true 表示判出开口
    public mutating func feed(_ level: Float) -> Bool {
        frameCount += 1
        peak = max(peak, level)
        if trace.count < Self.traceLimit { trace.append(level) }
        // 先更新基准再比：这一帧自己也算进「最安静」，开麦第一帧不可能比自己响 ratio 倍
        if quietest != nil || level >= Self.silenceLevel {
            quietest = min(quietest ?? .infinity, max(level, Self.silenceLevel))
        }
        passedFrames = level >= line ? passedFrames + 1 : max(0, passedFrames - 1)
        return passedFrames >= Self.framesNeeded
    }

    /// 写日志用：峰值、基准、过线值、帧数和前若干帧电平
    public var summary: String {
        let format = { (value: Float) in String(format: "%.2f", value) }
        let levels = trace.map(format).joined(separator: " ")
        return "peak \(format(peak)) quietest \(quietest.map(format) ?? "-") line \(format(line)) frames \(frameCount): \(levels)"
    }
}
