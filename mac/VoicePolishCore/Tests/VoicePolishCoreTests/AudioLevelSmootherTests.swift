import XCTest
@testable import VoicePolishCore

final class AudioLevelSmootherTests: XCTestCase {
    func testAttackRisesQuicklyTowardHigherInput() {
        var smoother = AudioLevelSmoother()
        let output = smoother.update(with: 1.0)
        XCTAssertGreaterThan(output, 0.6)
    }

    func testDecayFallsGraduallyTowardLowerInput() {
        var smoother = AudioLevelSmoother()
        _ = smoother.update(with: 1.0)
        let output = smoother.update(with: 0.0)
        XCTAssertGreaterThan(output, 0.0)
        XCTAssertLessThan(output, 1.0)
    }

    func testResetClearsInternalState() {
        var smoother = AudioLevelSmoother()
        _ = smoother.update(with: 1.0)
        smoother.reset()
        XCTAssertEqual(smoother.currentValue, 0)
    }
}
