import XCTest
@testable import VoicePolishCore

final class AppGroupBridgeTests: XCTestCase {
    func testWriteAndReadCommandRoundTrip() throws {
        let bridge = AppGroupBridge.testingBridge()
        let command = RecordingSessionCommand(
            sessionID: "session-1",
            kind: .start,
            hostBundleID: "com.example.notes",
            timestamp: 1
        )
        bridge.writeCommand(command)
        XCTAssertEqual(bridge.readCommand(), command)
    }

    func testStandbyPingAndPongRoundTrip() throws {
        let bridge = AppGroupBridge.testingBridge()
        let command = AppGroupBridge.StandbyCommand(action: .ping, sessionID: "probe-1", timestamp: 10)
        let response = AppGroupBridge.StandbyResponse(kind: .pong, sessionID: "probe-1", timestamp: 11)

        bridge.writeStandbyCommand(command)
        bridge.writeStandbyResponse(response)

        XCTAssertEqual(bridge.readStandbyCommand()?.action, .ping)
        XCTAssertEqual(bridge.readStandbyCommand()?.sessionID, "probe-1")
        XCTAssertEqual(bridge.readStandbyResponse()?.kind, .pong)
        XCTAssertEqual(bridge.readStandbyResponse()?.sessionID, "probe-1")
    }

    func testClearStandbyResponseRemovesPong() throws {
        let bridge = AppGroupBridge.testingBridge()
        bridge.writeStandbyResponse(AppGroupBridge.StandbyResponse(kind: .pong, sessionID: "probe-2"))

        bridge.clearStandbyResponse()

        XCTAssertNil(bridge.readStandbyResponse())
    }

    func testClearStaleTypedSnapshotLeavesNoReadableState() throws {
        let bridge = AppGroupBridge.testingBridge()
        bridge.writeSnapshot(
            RecordingSessionSnapshot(
                sessionID: "old",
                status: .error,
                text: nil,
                errorMessage: "failed",
                timestamp: 1
            )
        )

        bridge.clearSnapshot()

        XCTAssertNil(bridge.readSnapshot())
    }

    func testLegacyReadAndConsumeIgnoreActiveTypedSnapshot() throws {
        let bridge = AppGroupBridge.testingBridge()
        let snapshot = RecordingSessionSnapshot(
            sessionID: "session-2",
            status: .recording,
            text: nil,
            errorMessage: nil,
            timestamp: 2
        )
        bridge.writeSnapshot(snapshot)

        XCTAssertNil(bridge.readResult())
        XCTAssertNil(bridge.consumeResult())
        XCTAssertEqual(bridge.readSnapshot(), snapshot)
        XCTAssertFalse(bridge.hasPendingResult())
    }

    func testLegacyTerminalSnapshotCanBeConsumedAndCleared() throws {
        let bridge = AppGroupBridge.testingBridge()
        let snapshot = RecordingSessionSnapshot(
            sessionID: "legacy",
            status: .done,
            text: "final",
            errorMessage: nil,
            timestamp: 3
        )
        bridge.writeSnapshot(snapshot)

        XCTAssertTrue(bridge.hasPendingResult())
        XCTAssertEqual(bridge.readResult()?.text, "final")
        XCTAssertEqual(bridge.consumeResult()?.text, "final")
        XCTAssertNil(bridge.readSnapshot())
    }

    // MARK: - Audio Level (mmap)

    func testAudioLevelWriteAndRead() throws {
        let bridge = AppGroupBridge.testingBridge()
        bridge.writeAudioLevel(0.5)
        XCTAssertEqual(bridge.readAudioLevel(), 0.5, accuracy: 0.001)
    }

    func testAudioLevelWriteZero() throws {
        let bridge = AppGroupBridge.testingBridge()
        bridge.writeAudioLevel(0.5)
        bridge.writeAudioLevel(0.0)
        XCTAssertEqual(bridge.readAudioLevel(), 0.0, accuracy: 0.001)
    }

    func testAudioLevelReadDefaultsToZero() throws {
        let bridge = AppGroupBridge.testingBridge()
        XCTAssertEqual(bridge.readAudioLevel(), 0.0, accuracy: 0.001)
    }

    func testPrepareAudioLevelMmapEnablesReadWriteRoundTrip() throws {
        let bridge = AppGroupBridge.testingBridge()
        XCTAssertTrue(bridge.prepareAudioLevelMmap())
        bridge.writeAudioLevel(0.42)
        XCTAssertEqual(bridge.readAudioLevel(), 0.42, accuracy: 0.001)
    }

    func testAudioLevelClampAboveOne() throws {
        let bridge = AppGroupBridge.testingBridge()
        bridge.writeAudioLevel(1.5)
        XCTAssertEqual(bridge.readAudioLevel(), 1.0, accuracy: 0.001)
    }

    func testAudioLevelClampBelowZero() throws {
        let bridge = AppGroupBridge.testingBridge()
        bridge.writeAudioLevel(-0.3)
        XCTAssertEqual(bridge.readAudioLevel(), 0.0, accuracy: 0.001)
    }

    func testClearResultIgnoresNonTerminalLegacySnapshot() throws {
        let bridge = AppGroupBridge.testingBridge()
        let snapshot = RecordingSessionSnapshot(
            sessionID: "legacy",
            status: .recording,
            text: nil,
            errorMessage: nil,
            timestamp: 4
        )
        bridge.writeSnapshot(snapshot)

        bridge.clearResult()

        XCTAssertEqual(bridge.readSnapshot(), snapshot)
        XCTAssertNil(bridge.readResult())
        XCTAssertFalse(bridge.hasPendingResult())
    }
}
