import XCTest
@testable import VoicePolishCore

final class AskSpeechDetectorTests: XCTestCase {
    /// 返回第几帧（从 0 数）判出开口，判不出返回 nil
    private func detectionFrame(_ levels: [Float]) -> Int? {
        var detector = AskSpeechDetector()
        for (index, level) in levels.enumerated() {
            if detector.feed(level) { return index }
        }
        return nil
    }

    func testQuietRoomAboveOldFixedLineIsNotSpeech() {
        // 2026-09-14 外置麦在家没说话：一开麦就在 0.11～0.13，旧的固定线 0.08 第 3 帧就误判开口
        let quietHome: [Float] = [0.12, 0.13, 0.11, 0.12, 0.13, 0.12, 0.11, 0.13, 0.12, 0.12,
                                  0.11, 0.13, 0.12, 0.13, 0.11, 0.12, 0.12, 0.13, 0.11, 0.12]
        XCTAssertNil(detectionFrame(quietHome))
    }

    func testSoftSpeechOnFarBuiltInMicIsDetected() {
        // 2026-09-11 MacBook 自带麦、人坐得远：静音 0.03～0.05，说话峰值才 0.05～0.22
        XCTAssertEqual(detectionFrame([0.04, 0.03, 0.05, 0.04, 0.12, 0.18, 0.10, 0.22, 0.15]), 6)
    }

    func testWarmUpZerosThenRoomNoiseIsNotSpeech() {
        // 开麦头几帧是 0（设备预热）不定基准，否则基准塌成 0、底噪直接过保底线
        XCTAssertNil(detectionFrame([0, 0, 0, 0.12, 0.13, 0.11, 0.12, 0.13, 0.12, 0.11]))
    }

    func testMicStartPopIsNotSpeech() {
        XCTAssertNil(detectionFrame([0.30, 0.35, 0.30, 0.05, 0.04, 0.05, 0.04, 0.05]))
    }

    func testSpeechOnNoiseGatedMicIsDetectedAfterFirstGap() {
        // 降噪麦安静时直接输出 0：听到过声音之后的 0 是真安静，照常算进基准
        XCTAssertEqual(detectionFrame([0, 0, 0.30, 0.32, 0, 0.35, 0.40, 0.33]), 7)
    }

    func testSingleClicksDoNotAddUpToSpeech() {
        XCTAssertNil(detectionFrame([0.02, 0.02, 0.15, 0.02, 0.02, 0.15, 0.02, 0.02, 0.15, 0.02]))
    }

    func testTalkingWithoutPauseWaitsForAQuieterFrame() {
        // 已知代价：一开麦就不停顿地说，基准就是说话声，要等出现一帧安静的才判得出
        let nonStop: [Float] = [0.30, 0.32, 0.31, 0.30, 0.33]
        XCTAssertNil(detectionFrame(nonStop))
        XCTAssertEqual(detectionFrame(nonStop + [0.06, 0.30, 0.30, 0.30]), 8)
    }

    func testSpeechInNoisierRoomIsDetected() {
        // 2026-09-14 15:23 真实电平：屋里较吵（安静 0.15 左右），说话只有 0.3～0.4——倍数 2.5 判不出，1.8 第 9 帧判出
        let levels: [Float] = [0.19, 0.22, 0.16, 0.21, 0.32, 0.25, 0.33, 0.31, 0.40, 0.28,
                               0.29, 0.33, 0.20, 0.29, 0.31, 0.33, 0.22, 0.14, 0.21]
        XCTAssertEqual(detectionFrame(levels), 8)
    }

    func testNoisierRoomWithoutSpeechIsNotSpeech() {
        // 同一时段没说话的真实电平：有一帧 0.28 刚过 1.8 倍线，攒不够 3 帧
        XCTAssertNil(detectionFrame([0.15, 0.17, 0.21, 0.22, 0.28, 0.19, 0.16]))
    }
}
