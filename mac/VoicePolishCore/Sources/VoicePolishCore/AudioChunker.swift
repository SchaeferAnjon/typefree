import Foundation

/// 把一段 16kHz 录音按「语音停顿」切成多个可并行识别的片段（分段并行识别的切分器）。
///
/// 方法（相对能量低谷，不用绝对音量门槛）：
/// - 每 10ms 一帧算 RMS 能量；用本条录音自己的 P10(底噪)/P90(说话) 归一化，
///   所以录音整体偏小声、或带自动增益压缩动态范围，都照样能分辨相对高低；
/// - 停顿门槛 = 归一化活跃度分布的第 30 百分位（自适应，封顶 0.6）：
///   连续说话时该分位已很高、被封顶压住，下方几乎无帧 → 不误切；
/// - 只在「连续 ≥220ms 低于门槛」的低谷、且切在其最安静一帧下刀，
///   切点两侧都留有静音，绝不贴着字切；找不到合格低谷就整段识别；
/// - 段数上限对齐并发上限（5 段一波发完），超长录音按每段 ≤90s 增加段数。
///
/// 设计依据：用 owner 两千余条真实录音 + 火山极速版端到端验证——分段识别与整段识别
/// 的文字一致性达识别接口自身的噪声水平（详见开发记录）。故意不做的两件事：
/// ①不给分段首尾垫静音（实测火山对「静音占比高」的段会误判无语音、反而丢字）；
/// ②不加声带振动检测（纯能量已足够，且长录音上自相关太慢）。
public enum AudioChunker {

    static let sampleRateAssumed = 16000
    static let winSamples = 480          // 30ms 分析窗
    static let hopSamples = 160          // 10ms 帧移
    static let minSplitDuration: Double = 10.0
    static let idealChunkCount = 5
    static let minChunkDuration: Double = 5.0    // 段数规划的最小段长
    static let maxChunkDuration: Double = 90.0
    static let pausePercentile = 30.0            // 停顿门槛取活跃度的此百分位
    static let pauseCap: Float = 0.60            // 门槛封顶（连续说话不硬切）
    static let minPauseDuration: Double = 0.22   // 可下刀的停顿最短时长
    static let smoothWindow = 5                  // 活跃度平滑窗（50ms）
    static let snapRatio: Double = 0.4
    static let minResultDuration: Double = 4.0   // 切出的段不得短于此，避免碎段

    public struct PlanDiagnostics {
        public let duration: Double
        public let plannedChunkCount: Int
        public let floor: Float?
        public let speech: Float?
        public let pauseThreshold: Float?
        public let pauseCount: Int
        public let ranges: [Range<Int>]

        public var summary: String {
            let base = String(format: "%.1fs 计划%d段", duration, plannedChunkCount)
            guard let f = floor, let s = speech, let t = pauseThreshold else {
                return base + " → 不分段（整体音量过低或无停顿结构）"
            }
            return base + String(format: "，底噪=%.4f 说话=%.4f 停顿门槛=%.2f 低谷=%d处 → 实际%d段",
                                 f, s, t, pauseCount, ranges.count)
        }
    }

    public static func plan(samples: [Float], sampleRate: Int) -> [Range<Int>] {
        planWithDiagnostics(samples: samples, sampleRate: sampleRate).ranges
    }

    public static func planWithDiagnostics(samples: [Float], sampleRate: Int) -> PlanDiagnostics {
        let whole = [0..<samples.count]
        let duration = Double(samples.count) / Double(max(sampleRate, 1))

        func noSplit(_ chunks: Int, floor: Float? = nil, speech: Float? = nil,
                     thr: Float? = nil, pauses: Int = 0) -> PlanDiagnostics {
            PlanDiagnostics(duration: duration, plannedChunkCount: chunks, floor: floor,
                            speech: speech, pauseThreshold: thr, pauseCount: pauses, ranges: whole)
        }

        guard duration >= minSplitDuration else { return noSplit(1) }
        let nchunks = plannedChunkCount(duration: duration)
        guard nchunks > 1 else { return noSplit(nchunks) }

        guard let sig = activitySignal(samples: samples) else { return noSplit(nchunks) }
        let (floor, speech, thr) = (sig.floor, sig.speech, sig.threshold)
        let pauses = findPauses(activity: sig.activity, threshold: thr)
        guard !pauses.isEmpty else {
            return noSplit(nchunks, floor: floor, speech: speech, thr: thr, pauses: 0)
        }

        let targetLen = Double(samples.count) / Double(nchunks)
        let snap = targetLen * snapRatio
        let minChunk = Int(minResultDuration * Double(sampleRate))

        var cuts: [Int] = []
        var prev = 0
        for i in 1..<nchunks {
            let ideal = Double(i) * targetLen
            var best: Int? = nil
            var bestKey: (Int, Int, Int)? = nil   // (depth×100, min(length,40), -dist) 逐项比较
            for p in pauses {
                let cs = p.centerSample
                if abs(Double(cs) - ideal) > snap { continue }
                if cs - prev < minChunk || samples.count - cs < minChunk { continue }
                let key = (Int((p.depth * 100).rounded()), min(p.lengthFrames, 40), -Int(abs(Double(cs) - ideal)))
                if bestKey == nil || key > bestKey! {
                    bestKey = key; best = cs
                }
            }
            if let cut = best { cuts.append(cut); prev = cut }
        }
        guard !cuts.isEmpty else {
            return noSplit(nchunks, floor: floor, speech: speech, thr: thr, pauses: pauses.count)
        }

        var ranges: [Range<Int>] = []
        var start = 0
        for cut in cuts { ranges.append(start..<cut); start = cut }
        ranges.append(start..<samples.count)
        return PlanDiagnostics(duration: duration, plannedChunkCount: nchunks, floor: floor,
                               speech: speech, pauseThreshold: thr, pauseCount: pauses.count, ranges: ranges)
    }

    static func plannedChunkCount(duration: Double) -> Int {
        let base = min(Int(duration / minChunkDuration), idealChunkCount)
        guard base > 1 else { return 1 }
        if duration / Double(base) > maxChunkDuration {
            return Int((duration / maxChunkDuration).rounded(.up))
        }
        return base
    }

    struct ActivitySignal { let activity: [Float]; let floor: Float; let speech: Float; let threshold: Float }

    /// 归一化+平滑的语音活跃度信号 + 自适应停顿门槛。整体音量过低（疑似无语音）返回 nil。
    /// plan() 与边录边发的停顿检测共用它，保证两条链路口径一致。
    static func activitySignal(samples: [Float]) -> ActivitySignal? {
        let energies = frameEnergies(samples: samples)
        guard energies.count >= 10 else { return nil }
        let sorted = energies.sorted()
        let floor = percentile(sorted, 10)
        let speech = percentile(sorted, 90)
        guard speech > 1e-3 else { return nil }
        let span = max(speech - floor, 1e-9)
        var act = energies.map { min(max(($0 - floor) / span, 0), 1) }
        act = boxSmooth(act, window: smoothWindow)
        let thr = min(percentile(act.sorted(), pausePercentile), pauseCap)
        return ActivitySignal(activity: act, floor: floor, speech: speech, threshold: thr)
    }

    /// 停顿候选（供边录边发选切点）：每个停顿的最安静一帧的样本位置 + 深度 + 长度帧数。
    /// 与 plan() 用完全相同的活跃度/门槛，只是不做「均分成 N 段」的取舍。
    static func pauseCandidates(samples: [Float]) -> [Pause] {
        guard let sig = activitySignal(samples: samples) else { return [] }
        return findPauses(activity: sig.activity, threshold: sig.threshold)
    }

    /// 每 10ms 一帧、30ms 窗的 RMS 能量（帧重叠）
    static func frameEnergies(samples: [Float]) -> [Float] {
        guard samples.count >= winSamples else {
            guard !samples.isEmpty else { return [] }
            var sum: Float = 0
            for s in samples { sum += s * s }
            return [(sum / Float(samples.count)).squareRoot()]
        }
        let n = 1 + (samples.count - winSamples) / hopSamples
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let start = i * hopSamples
            var sum: Float = 0
            for j in start..<(start + winSamples) { sum += samples[j] * samples[j] }
            out[i] = (sum / Float(winSamples)).squareRoot()
        }
        return out
    }

    struct Pause { let centerSample: Int; let depth: Float; let lengthFrames: Int }

    static func findPauses(activity: [Float], threshold: Float) -> [Pause] {
        let minLen = max(1, Int((minPauseDuration / 0.01).rounded()))
        var pauses: [Pause] = []
        var i = 0
        while i < activity.count {
            if activity[i] < threshold {
                var j = i
                while j < activity.count && activity[j] < threshold { j += 1 }
                if j - i >= minLen {
                    var minIdx = i
                    for k in i..<j where activity[k] < activity[minIdx] { minIdx = k }
                    let center = minIdx * hopSamples + winSamples / 2
                    pauses.append(Pause(centerSample: center, depth: 1 - activity[minIdx], lengthFrames: j - i))
                }
                i = j
            } else {
                i += 1
            }
        }
        return pauses
    }

    /// numpy convolve(a, ones(k)/k, mode="same") 的等价实现（含边界衰减）
    static func boxSmooth(_ a: [Float], window: Int) -> [Float] {
        guard window > 1, !a.isEmpty else { return a }
        let half = window / 2
        var out = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count {
            var sum: Float = 0
            for d in -half...half {
                let idx = i + d
                if idx >= 0 && idx < a.count { sum += a[idx] }
            }
            out[i] = sum / Float(window)
        }
        return out
    }

    /// numpy 默认线性插值百分位（sorted 已升序）
    static func percentile(_ sorted: [Float], _ p: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = p / 100 * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let frac = Float(rank - Double(lo))
        if lo + 1 >= sorted.count { return sorted[sorted.count - 1] }
        return sorted[lo] + frac * (sorted[lo + 1] - sorted[lo])
    }
}
