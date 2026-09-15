import XCTest
@testable import VoicePolishCore

final class RippleTriggerTests: XCTestCase {
    func testTriggeringDoesNotDependOnAbsoluteTimeEpoch() {
        let trigger = RippleTrigger()

        let relativeResults = [
            trigger.update(level: 0.1, time: 0),
            trigger.update(level: 0.3, time: 0.1),
        ]

        trigger.reset()

        let base = 10_000.0
        let absoluteResults = [
            trigger.update(level: 0.1, time: base),
            trigger.update(level: 0.3, time: base + 0.1),
        ]

        XCTAssertEqual(relativeResults, absoluteResults)
        XCTAssertEqual(relativeResults, [false, true])
    }

    func testThresholdCrossingTriggersRipple() {
        let trigger = RippleTrigger()
        // Below threshold — no trigger
        XCTAssertFalse(trigger.update(level: 0.1, time: 0))
        // Cross threshold upward — triggers
        XCTAssertTrue(trigger.update(level: 0.3, time: 0.1))
    }

    func testBelowThresholdDoesNotTrigger() {
        let trigger = RippleTrigger()
        XCTAssertFalse(trigger.update(level: 0.1, time: 0))
        XCTAssertFalse(trigger.update(level: 0.2, time: 0.1))
        XCTAssertFalse(trigger.update(level: 0.15, time: 0.2))
    }

    func testMinIntervalSuppressesFastTriggers() {
        let trigger = RippleTrigger()
        // First trigger
        _ = trigger.update(level: 0.1, time: 0)
        XCTAssertTrue(trigger.update(level: 0.3, time: 0.1))
        // Drop and re-cross within 0.3s — suppressed
        _ = trigger.update(level: 0.1, time: 0.15)
        XCTAssertFalse(trigger.update(level: 0.3, time: 0.2))
        // After minInterval — triggers again
        _ = trigger.update(level: 0.1, time: 0.35)
        XCTAssertTrue(trigger.update(level: 0.3, time: 0.45))
    }

    func testSilenceStopsRipples() {
        let trigger = RippleTrigger()
        // Start with a trigger
        _ = trigger.update(level: 0.1, time: 0)
        XCTAssertTrue(trigger.update(level: 0.3, time: 0.1))
        // Go silent for > 1 second
        _ = trigger.update(level: 0.05, time: 0.5)
        _ = trigger.update(level: 0.05, time: 1.0)
        _ = trigger.update(level: 0.05, time: 1.6)
        // Even crossing threshold after prolonged silence — should not trigger
        // (silenceSince was set at 0.5, 1.6 - 0.5 = 1.1 > silenceTimeout 1.0)
        XCTAssertFalse(trigger.update(level: 0.3, time: 1.7))
    }

    func testSustainedLoudAudioTriggersAtIntervals() {
        let trigger = RippleTrigger()
        // Initial crossing
        _ = trigger.update(level: 0.1, time: 0)
        XCTAssertTrue(trigger.update(level: 0.5, time: 0.1))
        // Stay loud — no trigger before 0.6s interval
        XCTAssertFalse(trigger.update(level: 0.5, time: 0.5))
        // After 0.6s sustained — triggers again
        XCTAssertTrue(trigger.update(level: 0.5, time: 0.75))
    }

    func testResetClearsState() {
        let trigger = RippleTrigger()
        _ = trigger.update(level: 0.1, time: 0)
        _ = trigger.update(level: 0.3, time: 0.1)
        trigger.reset()
        // After reset, should trigger again as if fresh
        _ = trigger.update(level: 0.1, time: 1.0)
        XCTAssertTrue(trigger.update(level: 0.3, time: 1.1))
    }
}
