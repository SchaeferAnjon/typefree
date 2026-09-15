import XCTest
@testable import VoicePolishCore

final class RecordingSessionModelsTests: XCTestCase {
    func testStandbyStartRecordingKeepsAudioGraphRunning() {
        let transition = AudioCaptureStateMachine.transition(
            from: .standby,
            event: .startRecording
        )

        XCTAssertEqual(transition.nextState, .recording(returnsToStandby: true))
        XCTAssertEqual(transition.graphAction, .keepRunning)
        XCTAssertTrue(transition.shouldWriteToFile)
    }

    func testStopRecordingReturnsToStandbyWithoutStoppingCapture() {
        let transition = AudioCaptureStateMachine.transition(
            from: .recording(returnsToStandby: true),
            event: .stopRecording
        )

        XCTAssertEqual(transition.nextState, .standby)
        XCTAssertEqual(transition.graphAction, .keepRunning)
        XCTAssertFalse(transition.shouldWriteToFile)
    }

    func testDirectRecordingStopsCaptureWhenStandbyWasNeverArmed() {
        let transition = AudioCaptureStateMachine.transition(
            from: .recording(returnsToStandby: false),
            event: .stopRecording
        )

        XCTAssertEqual(transition.nextState, .idle)
        XCTAssertEqual(transition.graphAction, .stopRunning)
        XCTAssertFalse(transition.shouldWriteToFile)
    }

    func testIdleRecordingCanRequestStandbyAfterStopWithoutDoubleStart() {
        let transition = AudioCaptureStateMachine.transition(
            from: .idle,
            event: .startRecordingKeepingStandby
        )

        XCTAssertEqual(transition.nextState, .recording(returnsToStandby: true))
        XCTAssertEqual(transition.graphAction, .startRunning)
        XCTAssertTrue(transition.shouldWriteToFile)
    }

    func testStartFactoryCreatesStartCommand() {
        let payload = RecordingSessionCommand.start(sessionID: "session-123", hostBundleID: "com.example.target")

        XCTAssertEqual(payload.sessionID, "session-123")
        XCTAssertEqual(payload.kind, .start)
        XCTAssertEqual(payload.hostBundleID, "com.example.target")
    }

    func testStopFactoryCreatesStopCommand() {
        let payload = RecordingSessionCommand.stop(sessionID: "session-456")

        XCTAssertEqual(payload.sessionID, "session-456")
        XCTAssertEqual(payload.kind, .stop)
        XCTAssertNil(payload.hostBundleID)
    }

    func testCommandRoundTripPreservesSessionID() throws {
        let payload = RecordingSessionCommand(
            sessionID: "session-123",
            kind: .start,
            hostBundleID: "com.example.target",
            timestamp: 1_700_000_000
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(RecordingSessionCommand.self, from: data)
        XCTAssertEqual(decoded.sessionID, "session-123")
        XCTAssertEqual(decoded.kind, .start)
        XCTAssertEqual(decoded.hostBundleID, "com.example.target")
        XCTAssertEqual(decoded.timestamp, 1_700_000_000)
    }

    func testSnapshotRejectsTerminalAsActive() {
        XCTAssertFalse(RecordingSessionStatus.idle.isActive)
        XCTAssertTrue(RecordingSessionStatus.launching.isActive)
        XCTAssertTrue(RecordingSessionStatus.recording.isActive)
        XCTAssertTrue(RecordingSessionStatus.processing.isActive)
        XCTAssertFalse(RecordingSessionStatus.done.isActive)
        XCTAssertFalse(RecordingSessionStatus.error.isActive)
    }

    func testStandbyBootstrapStartsRecordingOptimistically() {
        let bootstrap = KeyboardSessionBootstrap.bootstrap(for: .standbyDirect)

        XCTAssertEqual(bootstrap.initialStatus, .recording)
        XCTAssertEqual(bootstrap.recoveryMode, .recordingAcknowledgement)
    }

    func testAppLaunchBootstrapStartsInLaunchingState() {
        let bootstrap = KeyboardSessionBootstrap.bootstrap(for: .appLaunch)

        XCTAssertEqual(bootstrap.initialStatus, .launching)
        XCTAssertEqual(bootstrap.recoveryMode, .launchAcknowledgement)
    }
}
