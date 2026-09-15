import Foundation

public enum AudioCaptureState: Equatable {
    case idle
    case standby
    case recording(returnsToStandby: Bool)
}

public enum AudioCaptureEvent: Equatable {
    case startStandby
    case stopStandby
    case startRecording
    case startRecordingKeepingStandby
    case stopRecording
}

public enum AudioGraphAction: Equatable {
    case keepRunning
    case startRunning
    case stopRunning
}

public struct AudioCaptureTransition: Equatable {
    public let nextState: AudioCaptureState
    public let graphAction: AudioGraphAction
    public let shouldWriteToFile: Bool

    public init(nextState: AudioCaptureState, graphAction: AudioGraphAction, shouldWriteToFile: Bool) {
        self.nextState = nextState
        self.graphAction = graphAction
        self.shouldWriteToFile = shouldWriteToFile
    }
}

public enum AudioCaptureStateMachine {
    public static func transition(from state: AudioCaptureState, event: AudioCaptureEvent) -> AudioCaptureTransition {
        switch (state, event) {
        case (.idle, .startStandby):
            return AudioCaptureTransition(
                nextState: .standby,
                graphAction: .startRunning,
                shouldWriteToFile: false
            )

        case (.standby, .startRecording):
            return AudioCaptureTransition(
                nextState: .recording(returnsToStandby: true),
                graphAction: .keepRunning,
                shouldWriteToFile: true
            )

        case (.idle, .startRecordingKeepingStandby):
            return AudioCaptureTransition(
                nextState: .recording(returnsToStandby: true),
                graphAction: .startRunning,
                shouldWriteToFile: true
            )

        case (.standby, .startRecordingKeepingStandby):
            return AudioCaptureTransition(
                nextState: .recording(returnsToStandby: true),
                graphAction: .keepRunning,
                shouldWriteToFile: true
            )

        case (.idle, .startRecording):
            return AudioCaptureTransition(
                nextState: .recording(returnsToStandby: false),
                graphAction: .startRunning,
                shouldWriteToFile: true
            )

        case (.recording(let returnsToStandby), .stopRecording):
            return AudioCaptureTransition(
                nextState: returnsToStandby ? .standby : .idle,
                graphAction: returnsToStandby ? .keepRunning : .stopRunning,
                shouldWriteToFile: false
            )

        case (.standby, .stopStandby):
            return AudioCaptureTransition(
                nextState: .idle,
                graphAction: .stopRunning,
                shouldWriteToFile: false
            )

        default:
            return AudioCaptureTransition(
                nextState: state,
                graphAction: .keepRunning,
                shouldWriteToFile: state.isWritingToFile
            )
        }
    }
}

private extension AudioCaptureState {
    var isWritingToFile: Bool {
        switch self {
        case .recording:
            return true
        case .idle, .standby:
            return false
        }
    }
}
