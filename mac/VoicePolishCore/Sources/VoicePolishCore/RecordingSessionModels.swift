import Foundation

public enum RecordingSessionCommandKind: String, Codable, Equatable {
    case start
    case stop
}

public enum RecordingSessionStatus: String, Codable, Equatable {
    case idle
    case launching
    case recording
    case processing
    case done
    case error

    public var isActive: Bool {
        switch self {
        case .launching, .recording, .processing:
            return true
        case .idle, .done, .error:
            return false
        }
    }
}

public struct RecordingSessionCommand: Codable, Equatable {
    public let sessionID: String
    public let kind: RecordingSessionCommandKind
    public let hostBundleID: String?
    public let timestamp: TimeInterval

    public init(
        sessionID: String,
        kind: RecordingSessionCommandKind,
        hostBundleID: String? = nil,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.hostBundleID = hostBundleID
        self.timestamp = timestamp
    }

    public static func start(sessionID: String, hostBundleID: String? = nil) -> RecordingSessionCommand {
        RecordingSessionCommand(sessionID: sessionID, kind: .start, hostBundleID: hostBundleID)
    }

    public static func stop(sessionID: String) -> RecordingSessionCommand {
        RecordingSessionCommand(sessionID: sessionID, kind: .stop)
    }
}

public struct RecordingSessionSnapshot: Codable, Equatable {
    public let sessionID: String
    public let status: RecordingSessionStatus
    public let text: String?
    public let errorMessage: String?
    public let timestamp: TimeInterval

    public init(
        sessionID: String,
        status: RecordingSessionStatus,
        text: String? = nil,
        errorMessage: String? = nil,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.sessionID = sessionID
        self.status = status
        self.text = text
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }
}
