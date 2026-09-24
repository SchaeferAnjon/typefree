import Cocoa
import Combine
import AudioToolbox
import AVFoundation
import ApplicationServices
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

// MARK: - Polish history store

final class PolishHistoryStore {
    private let logFileURL: URL

    init(logFileURL: URL = AppIdentity.macConfigDirectory.appendingPathComponent("polish_log.jsonl")) {
        self.logFileURL = logFileURL
    }

    var fileURL: URL { logFileURL }

    // 所有读-改-写都走 HistoryFileLock：pipeline 后台追加与这里的整文件重写此前互不相知，会丢条。

    func load(limit: Int = 100) -> [AIPolisher.PolishLog] {
        HistoryFileLock.withLock {
            pruneExpiredEntries()
            guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else {
                return []
            }
            let lines = content
                .split(separator: "\n")
                .suffix(limit)
                .reversed()
            let enc = HistoryCrypto.defaultEncryptor()
            return lines.compactMap { line in
                HistoryCrypto.decodeLine(String(line), enc: enc)
            }
        }
    }

    /// 导出历史为 Markdown（从新到旧，每条 `## 时间` + 整理后的文字）。
    /// 不受界面 500 条显示上限影响，读全部后按 `retention` 过滤时间范围
    /// （`.oneWeek` 近 7 天 / `.oneMonth` 近一个月 / `.forever` 全部，复用保留策略同一套判断）。
    /// 该范围内无记录返回 nil。
    func exportAllAsMarkdown(retention: AIPolisher.HistoryRetention = .forever) -> String? {
        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return nil }
        let enc = HistoryCrypto.defaultEncryptor()
        let logs = content
            .split(separator: "\n")
            .reversed()
            .compactMap { HistoryCrypto.decodeLine(String($0), enc: enc) }
            .filter { AIPolisher.shouldKeepPolishLog($0, retention: retention) }
        guard !logs.isEmpty else { return nil }
        var out = "# Typefree 转写记录\n\n"
        for log in logs {
            if log.isAsk {
                out += "## \(log.time) · 问 AI\n**问：** \(log.asr)\n\n\(log.output.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
                continue
            }
            let polished = log.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = polished.isEmpty ? log.asr.trimmingCharacters(in: .whitespacesAndNewlines) : polished
            out += "## \(log.time)\n\(body)\n\n"
        }
        return out
    }

    func clear() {
        HistoryFileLock.withLock {
            try? FileManager.default.createDirectory(
                at: logFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
            AudioClipStore.defaultStore().deleteAll()  // 清空历史时一并删掉所有音频
        }
    }

    @discardableResult
    func pruneExpiredEntries() -> Int {
        let audioStore = AudioClipStore.defaultStore()
        return AIPolisher.pruneLogFile(
            at: logFileURL,
            retention: AIPolisher.currentHistoryRetention()
        ) { removed in
            audioStore.delete(fileName: removed.audioFile)
        }
    }

    /// 是否为同一条记录：有 id 用 id 比，否则比关键字段（旧数据兜底）。
    private func sameEntry(_ a: AIPolisher.PolishLog, _ b: AIPolisher.PolishLog) -> Bool {
        if let ia = a.id, let ib = b.id, !ia.isEmpty, !ib.isEmpty { return ia == ib }
        return a.time == b.time && a.app == b.app && a.asr == b.asr && a.output == b.output
    }

    /// 重写匹配到的那一行（用于重新润色/重新转写后更新 asr/output，其余字段保留）。
    @discardableResult
    func updateEntry(matching target: AIPolisher.PolishLog, newASR: String?, newOutput: String?) -> Bool {
        HistoryFileLock.withLock {
            guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return false }
            var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let enc = HistoryCrypto.defaultEncryptor() else { return false }
            var changed = false
            for (idx, line) in lines.enumerated() where !line.isEmpty {
                guard let log = HistoryCrypto.decodeLine(line, enc: enc),
                      sameEntry(log, target) else { continue }
                let updated = AIPolisher.PolishLog(
                    time: log.time, app: log.app,
                    asr: newASR ?? log.asr,
                    output: newOutput ?? log.output,
                    duration_ms: log.duration_ms,
                    input_tokens: log.input_tokens,
                    output_tokens: log.output_tokens,
                    id: log.id, audioFile: log.audioFile,
                    kind: log.kind, thread: log.thread
                )
                if let s = HistoryCrypto.encodeLine(updated, enc: enc) {
                    lines[idx] = s
                    changed = true
                }
                break
            }
            guard changed else { return false }
            try? lines.joined(separator: "\n").write(to: logFileURL, atomically: true, encoding: .utf8)
            return true
        }
    }

    /// 删除匹配到的那一行，并删掉其音频。
    @discardableResult
    func deleteEntry(matching target: AIPolisher.PolishLog) -> Bool {
        HistoryFileLock.withLock {
            guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return false }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let enc = HistoryCrypto.defaultEncryptor()
            var kept: [String] = []
            var removed = false
            for line in lines where !line.isEmpty {
                if !removed,
                   let log = HistoryCrypto.decodeLine(line, enc: enc),
                   sameEntry(log, target) {
                    removed = true
                    AudioClipStore.defaultStore().delete(fileName: log.audioFile)
                    continue
                }
                kept.append(line)
            }
            guard removed else { return false }
            let next = kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
            try? next.write(to: logFileURL, atomically: true, encoding: .utf8)
            return true
        }
    }
}
