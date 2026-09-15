import XCTest
@testable import VoicePolishCore

final class AudioChunkerTests: XCTestCase {

    private let sampleRate = 16000

    /// 合成"说话"：440Hz 正弦波 + 轻微白噪，模拟带底噪的真实录音
    private func speech(seconds: Double, amplitude: Float = 0.2, noise: Float = 0.01, seed: inout UInt64) -> [Float] {
        let count = Int(seconds * Double(sampleRate))
        return (0..<count).map { i in
            amplitude * sin(2 * .pi * 440 * Float(i) / Float(sampleRate)) + noise * pseudoRandom(&seed)
        }
    }

    /// 合成"停顿"：只有底噪（能量远低于说话，但不是绝对零）
    private func silence(seconds: Double, noise: Float = 0.01, seed: inout UInt64) -> [Float] {
        let count = Int(seconds * Double(sampleRate))
        return (0..<count).map { _ in noise * pseudoRandom(&seed) }
    }

    /// 可复现的 [-1,1] 伪随机（不用 Date/Random，保证测试确定性）
    private func pseudoRandom(_ seed: inout UInt64) -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
    }

    // MARK: - 不该分段的情况

    /// 10 秒以内不分段（短录音路径完全不变）
    func testShortRecordingSingleChunk() {
        var s: UInt64 = 1
        XCTAssertEqual(AudioChunker.plan(samples: speech(seconds: 8, seed: &s), sampleRate: sampleRate).count, 1)
    }

    /// 连续说话没有停顿 → 找不到低谷，不分段（宁可不快也不切在字中间）
    func testContinuousSpeechWithoutPauseSingleChunk() {
        var s: UInt64 = 2
        XCTAssertEqual(AudioChunker.plan(samples: speech(seconds: 16, seed: &s), sampleRate: sampleRate).count, 1)
    }

    /// 整条都很安静（疑似无语音）→ 不切，交给服务端判定
    func testPureQuietSingleChunk() {
        var s: UInt64 = 3
        XCTAssertEqual(AudioChunker.plan(samples: silence(seconds: 20, noise: 0.0003, seed: &s), sampleRate: sampleRate).count, 1)
    }

    // MARK: - 该分段的情况

    /// 12 秒、中间一处 0.4s 停顿 → 切成 2 段，切点落在停顿里
    func testMiddlePauseSplitsInTwo() {
        var s: UInt64 = 4
        var samples = speech(seconds: 5.6, seed: &s)
        let gapStart = samples.count
        samples += silence(seconds: 0.5, seed: &s)
        let gapEnd = samples.count
        samples += speech(seconds: 5.9, seed: &s)
        let ranges = AudioChunker.plan(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(ranges.count, 2)
        let cut = ranges[0].upperBound
        XCTAssertGreaterThanOrEqual(cut, gapStart - sampleRate / 10)
        XCTAssertLessThanOrEqual(cut, gapEnd + sampleRate / 10)
    }

    /// 30 秒、每 ~6s 一处停顿 → 切成 5 段（对齐并发上限），且无缝覆盖整段
    func testRegularPausesSplitToFive() {
        var s: UInt64 = 5
        var samples: [Float] = []
        for _ in 0..<5 {
            samples += speech(seconds: 5.6, seed: &s)
            samples += silence(seconds: 0.4, seed: &s)
        }
        let ranges = AudioChunker.plan(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(ranges.count, 5)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, samples.count)
        for i in 1..<ranges.count {
            XCTAssertEqual(ranges[i].lowerBound, ranges[i - 1].upperBound)
        }
        let minSamples = Int(AudioChunker.minResultDuration * Double(sampleRate))
        for r in ranges { XCTAssertGreaterThanOrEqual(r.count, minSamples) }
    }

    /// 切点必须落在低能量处（绝不切进说话）——安全属性
    func testCutsLandInLowEnergy() {
        var s: UInt64 = 6
        var samples: [Float] = []
        var gaps: [(Int, Int)] = []
        for k in 0..<5 {
            samples += speech(seconds: 5.6, seed: &s)
            if k < 4 {
                let g0 = samples.count
                samples += silence(seconds: 0.4, seed: &s)
                gaps.append((g0, samples.count))
            }
        }
        let ranges = AudioChunker.plan(samples: samples, sampleRate: sampleRate)
        for i in 1..<ranges.count {
            let cut = ranges[i].lowerBound
            let inGap = gaps.contains { $0.0 - sampleRate / 10 <= cut && cut <= $0.1 + sampleRate / 10 }
            XCTAssertTrue(inGap, "切点 \(cut) 未落在停顿内")
        }
    }

    // MARK: - 段数规划

    func testPlannedChunkCount() {
        XCTAssertEqual(AudioChunker.plannedChunkCount(duration: 9.9), 1)
        XCTAssertEqual(AudioChunker.plannedChunkCount(duration: 10), 2)
        XCTAssertEqual(AudioChunker.plannedChunkCount(duration: 12), 2)
        XCTAssertEqual(AudioChunker.plannedChunkCount(duration: 30), 5)
        XCTAssertEqual(AudioChunker.plannedChunkCount(duration: 300), 5)
        XCTAssertEqual(AudioChunker.plannedChunkCount(duration: 451), 6)
        XCTAssertEqual(AudioChunker.plannedChunkCount(duration: 1800), 20)
    }

    // MARK: - 数值工具（与 Python 参照实现对齐的基石）

    /// 线性插值百分位，对齐 numpy.percentile 默认行为
    func testPercentileLinearInterpolation() {
        let a: [Float] = [0, 1, 2, 3, 4]  // 已升序
        XCTAssertEqual(AudioChunker.percentile(a, 0), 0, accuracy: 1e-6)
        XCTAssertEqual(AudioChunker.percentile(a, 100), 4, accuracy: 1e-6)
        XCTAssertEqual(AudioChunker.percentile(a, 50), 2, accuracy: 1e-6)
        XCTAssertEqual(AudioChunker.percentile(a, 25), 1, accuracy: 1e-6)
        XCTAssertEqual(AudioChunker.percentile(a, 10), 0.4, accuracy: 1e-6)
    }

    /// 盒式平滑对齐 numpy convolve(ones/k, "same")，含边界衰减
    func testBoxSmoothMatchesNumpySame() {
        let a: [Float] = [0, 0, 10, 0, 0]
        let out = AudioChunker.boxSmooth(a, window: 5)
        // 每点为 ±2 邻域和/5；含 10 的窗都得 2，其余为 0
        XCTAssertEqual(out[0], 2, accuracy: 1e-6)  // (0+0+10)/5，左侧越界补0
        XCTAssertEqual(out[2], 2, accuracy: 1e-6)  // (0+0+10+0+0)/5
        XCTAssertEqual(out[4], 2, accuracy: 1e-6)
    }

    /// 帧能量：静音段能量应远低于说话段
    func testFrameEnergiesSeparateSpeechFromSilence() {
        var s: UInt64 = 7
        let loud = speech(seconds: 1, amplitude: 0.3, seed: &s)
        let quiet = silence(seconds: 1, noise: 0.005, seed: &s)
        let eLoud = AudioChunker.frameEnergies(samples: loud).reduce(0, +) / Float(AudioChunker.frameEnergies(samples: loud).count)
        let eQuiet = AudioChunker.frameEnergies(samples: quiet).reduce(0, +) / Float(AudioChunker.frameEnergies(samples: quiet).count)
        XCTAssertGreaterThan(eLoud, eQuiet * 5)
    }
}
