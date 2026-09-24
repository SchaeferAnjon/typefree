import Cocoa
import AVFoundation
import ApplicationServices
import Sparkle
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

extension AppDelegate {
    func debugLog(_ message: String) {
        let logFile = AppIdentity.debugLogFileURL
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let maxBytes = debugLogMaxBytes
        debugLogQueue.async {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)

            let attributes = try? fileManager.attributesOfItem(atPath: logFile.path)
            let currentBytes = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            if currentBytes + UInt64(data.count) > maxBytes {
                try? fileManager.removeItem(at: logFile)
            }

            if fileManager.fileExists(atPath: logFile.path),
               let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logFile, options: .atomic)
            }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFile.path)
        }
    }

    func removeLegacyPlaintextDebugLogIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: debugLogPrivacyMigrationKey) else { return }
        let logFile = AppIdentity.debugLogFileURL
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: logFile.path) {
                try fileManager.removeItem(at: logFile)
            }
            defaults.set(true, forKey: debugLogPrivacyMigrationKey)
        } catch {
            return
        }
    }

    /// 最近 120 行调试日志（不含用户说的内容：日志里只有字数、耗时、软件名这类元信息）
    func debugLogTail() -> String {
        let logFile = AppIdentity.debugLogFileURL
        guard let data = try? Data(contentsOf: logFile), let text = String(data: data, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let tail = lines.suffix(120).joined(separator: "\n")
        return String(tail.suffix(SupportChatService.maxLogChars))
    }
}
