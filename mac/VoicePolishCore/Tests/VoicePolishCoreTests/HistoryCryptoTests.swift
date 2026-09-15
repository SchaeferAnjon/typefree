import CryptoKit
import XCTest
@testable import VoicePolishCore

final class HistoryCryptoTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    func testSealOpenRoundTripAndTamperRejected() throws {
        let enc = Encryptor(key: key)
        let plain = Data("hello history".utf8)
        let cipher = try XCTUnwrap(enc.seal(plain))

        XCTAssertEqual(enc.open(cipher), plain)

        var tampered = cipher
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertNil(enc.open(tampered))
    }

    func testEncodeDecodeAndClassifyThreeStates() throws {
        let enc = Encryptor(key: key)
        let log = makeLog(asr: "raw text", output: "polished text")
        let plainJSON = String(data: try JSONEncoder().encode(log), encoding: .utf8)!

        let cipherLine = try XCTUnwrap(HistoryCrypto.encodeLine(log, enc: enc))
        XCTAssertTrue(cipherLine.hasPrefix(HistoryCrypto.linePrefix))
        XCTAssertEqual(HistoryCrypto.decodeLine(cipherLine, enc: enc)?.asr, "raw text")
        XCTAssertEqual(HistoryCrypto.decodeLine(plainJSON, enc: enc)?.output, "polished text")

        if case .plaintext = HistoryCrypto.classify(plainJSON, enc: enc) {} else { XCTFail("expected plaintext") }
        if case .encrypted = HistoryCrypto.classify(cipherLine, enc: enc) {} else { XCTFail("expected encrypted") }
        if case .unknown = HistoryCrypto.classify("not-json", enc: enc) {} else { XCTFail("expected unknown") }
    }

    func testHistoryKeyPersistsThroughSecretStore() throws {
        let secrets = InMemorySecretStore()
        let first = try XCTUnwrap(HistoryCrypto.historyKey(secrets: secrets))
        let second = try XCTUnwrap(HistoryCrypto.historyKey(secrets: secrets))
        let firstEnc = Encryptor(key: first)
        let secondEnc = Encryptor(key: second)
        let cipher = try XCTUnwrap(firstEnc.seal(Data("same-key".utf8)))

        XCTAssertEqual(secondEnc.open(cipher), Data("same-key".utf8))
    }

    func testCorruptCipherLineDecodesToNilButClassifiesEncrypted() {
        let enc = Encryptor(key: key)
        let corrupt = "\(HistoryCrypto.linePrefix)%%%notbase64%%%"

        XCTAssertNil(HistoryCrypto.decodeLine(corrupt, enc: enc))
        if case .encrypted = HistoryCrypto.classify(corrupt, enc: enc) {} else {
            XCTFail("corrupt encrypted lines must stay encrypted")
        }
    }

    func testMigrateLogFileEncryptsPlaintextAndKeepsUnknownLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicepolish-history-crypto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("polish_log.jsonl")
        let log = makeLog(asr: "secret raw", output: "secret output")
        let plain = String(data: try JSONEncoder().encode(log), encoding: .utf8)!
        try "\(plain)\nnot-json\n".write(to: file, atomically: true, encoding: .utf8)

        let secrets = InMemorySecretStore()
        XCTAssertTrue(HistoryCrypto.migrateLogFile(at: file, secrets: secrets))

        let migrated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(migrated.contains("secret raw"))
        XCTAssertTrue(migrated.contains(HistoryCrypto.linePrefix))
        XCTAssertTrue(migrated.contains("not-json"))

        let enc = Encryptor(key: try XCTUnwrap(HistoryCrypto.historyKey(secrets: secrets)))
        let decoded = migrated
            .split(separator: "\n")
            .compactMap { HistoryCrypto.decodeLine(String($0), enc: enc) }
        XCTAssertEqual(decoded.first?.output, "secret output")
    }

    func testPruneEncryptedLogKeepsCorruptCipherLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicepolish-history-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("polish_log.jsonl")
        let enc = Encryptor(key: key)
        let drop = try XCTUnwrap(HistoryCrypto.encodeLine(makeLog(time: "2026-05-18 09:59:59", asr: "drop", output: "drop"), enc: enc))
        let keep = try XCTUnwrap(HistoryCrypto.encodeLine(makeLog(time: "2026-05-18 10:00:00", asr: "keep", output: "keep"), enc: enc))
        let corrupt = "\(HistoryCrypto.linePrefix)not-valid"
        try "\(drop)\n\(corrupt)\n\(keep)\n".write(to: file, atomically: true, encoding: .utf8)

        let removed = AIPolisher.pruneLogFile(
            at: file,
            retention: .oneDay,
            now: fixedDate("2026-05-19 10:00:00"),
            encryptor: enc
        )
        let remaining = try String(contentsOf: file, encoding: .utf8)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(remaining.contains("drop"))
        XCTAssertTrue(remaining.contains(corrupt))
        XCTAssertTrue(remaining.contains(keep))
    }

    private func makeLog(time: String = "2026-06-25 10:00:00", asr: String, output: String) -> AIPolisher.PolishLog {
        AIPolisher.PolishLog(
            time: time,
            app: "Finder",
            asr: asr,
            output: output,
            duration_ms: 1,
            input_tokens: 0,
            output_tokens: 0,
            id: UUID().uuidString,
            audioFile: nil
        )
    }

    private func fixedDate(_ raw: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)!
    }
}
