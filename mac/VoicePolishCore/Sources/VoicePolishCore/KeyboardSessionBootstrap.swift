import Foundation

public enum KeyboardSessionEntryPath: Equatable {
    case appLaunch
    case standbyDirect
}

public enum KeyboardRecoveryMode: Equatable {
    case launchAcknowledgement
    case recordingAcknowledgement
}

public struct KeyboardSessionBootstrap: Equatable {
    public let initialStatus: RecordingSessionStatus
    public let recoveryMode: KeyboardRecoveryMode

    public init(initialStatus: RecordingSessionStatus, recoveryMode: KeyboardRecoveryMode) {
        self.initialStatus = initialStatus
        self.recoveryMode = recoveryMode
    }

    public static func bootstrap(for entryPath: KeyboardSessionEntryPath) -> KeyboardSessionBootstrap {
        switch entryPath {
        case .appLaunch:
            return KeyboardSessionBootstrap(
                initialStatus: .launching,
                recoveryMode: .launchAcknowledgement
            )
        case .standbyDirect:
            return KeyboardSessionBootstrap(
                initialStatus: .recording,
                recoveryMode: .recordingAcknowledgement
            )
        }
    }
}
