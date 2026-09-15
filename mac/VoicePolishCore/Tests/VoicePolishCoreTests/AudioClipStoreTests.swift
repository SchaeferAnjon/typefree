import XCTest
import CryptoKit
import AVFoundation
@testable import VoicePolishCore

final class AudioClipStoreTests: XCTestCase {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicepolish-audio-tests-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    /// 一段可识别的正弦波样本（16kHz 单声道）。
    private func sineSamples(seconds: Double = 0.5, sampleRate: Double = 16000) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            Float(sin(2.0 * Double.pi * 440.0 * Double(i) / sampleRate)) * 0.5
        }
    }

    func testSaveThenLoadRoundTrips() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AudioClipStore(directory: dir)

        let samples = sineSamples()
        let name = try XCTUnwrap(store.save(samples: samples, id: "abc123"))
        XCTAssertEqual(name, "abc123.m4a")
        XCTAssertTrue(store.exists(name))

        // 解码回来：AAC 有损，长度可能略有出入，但应在同量级且非空。
        let loaded = try XCTUnwrap(store.loadSamples(fileName: name))
        XCTAssertFalse(loaded.isEmpty)
        XCTAssertGreaterThan(loaded.count, samples.count / 2)
    }

    /// 落盘必须是真 MP4 容器（头部 "ftyp"），不能是 CAF——浏览器只认前者。
    /// 回归保护：AVAudioFile 按扩展名定容器，临时文件若以 .tmp 结尾会默默写成 CAF。
    func testSavedFileIsRealM4AContainer() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AudioClipStore(directory: dir)

        let name = try XCTUnwrap(store.save(samples: sineSamples(), id: "container"))
        let data = try Data(contentsOf: store.url(forFileName: name))
        let header = String(data: data.prefix(12), encoding: .ascii) ?? ""
        XCTAssertTrue(header.contains("ftyp"), "应为 MP4/M4A 容器（ftyp），实际头部：\(header)")
        XCTAssertFalse(header.hasPrefix("caff"), "不得写成 CAF 容器")
    }

    func testEncryptedSaveStoresCiphertextButLoadDataReturnsM4A() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let enc = Encryptor(key: SymmetricKey(size: .bits256))
        let store = AudioClipStore(directory: dir, encryptor: enc, encryptNewFiles: true)

        let name = try XCTUnwrap(store.save(samples: sineSamples(), id: "encrypted"))
        let stored = try Data(contentsOf: store.url(forFileName: name))

        XCTAssertTrue(stored.starts(with: AudioClipStore.audioMagic))
        XCTAssertFalse(AudioClipStore.looksLikePlaintextM4A(stored))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("encrypted.tmp.m4a").path))

        let plain = try XCTUnwrap(store.loadData(fileName: name))
        XCTAssertTrue(AudioClipStore.looksLikePlaintextM4A(plain))
        XCTAssertFalse(try XCTUnwrap(store.loadSamples(fileName: name)).isEmpty)
    }

    func testMigrateAllEncryptsPlaintextM4AFiles() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plainStore = AudioClipStore(directory: dir)
        let name = try XCTUnwrap(plainStore.save(samples: sineSamples(), id: "legacy"))
        let before = try Data(contentsOf: plainStore.url(forFileName: name))
        XCTAssertTrue(AudioClipStore.looksLikePlaintextM4A(before))

        let enc = Encryptor(key: SymmetricKey(size: .bits256))
        let encryptedStore = AudioClipStore(directory: dir, encryptor: enc, encryptNewFiles: true)
        encryptedStore.migrateAll()

        let after = try Data(contentsOf: encryptedStore.url(forFileName: name))
        XCTAssertTrue(after.starts(with: AudioClipStore.audioMagic))
        XCTAssertTrue(AudioClipStore.looksLikePlaintextM4A(try XCTUnwrap(encryptedStore.loadData(fileName: name))))
    }

    /// 造一个「名字是 .m4a、内容其实是 CAF」的历史遗留文件（复刻早期 .tmp 坑：
    /// AVAudioFile 按扩展名定容器，旧版临时文件以 .tmp 结尾会默默写成 CAF）。
    private func writeLegacyCAF(samples: [Float], sampleRate: Double = 16000, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let cafURL = url.deletingPathExtension().appendingPathExtension("caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        let file = try AVAudioFile(forWriting: cafURL, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in samples.indices { buffer.floatChannelData![0][i] = samples[i] }
        try file.write(from: buffer)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: cafURL, to: url)
    }

    /// 回归保护：早期 .tmp 坑写出的「名为 .m4a、实为 CAF」历史录音，
    /// migrateAll 必须也能识别并加密——不能因为它不是 ftyp 就漏掉，留明文录音在盘上。
    func testMigrateAllEncryptsLegacyCAFFiles() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let name = "legacy-caf.m4a"
        let url = dir.appendingPathComponent(name)
        try writeLegacyCAF(samples: sineSamples(), to: url)

        // 前提：它确实是明文 CAF（头 "caff"），且不被当作标准 m4a。
        let before = try Data(contentsOf: url)
        XCTAssertEqual(String(data: before.prefix(4), encoding: .ascii), "caff")
        XCTAssertFalse(AudioClipStore.looksLikePlaintextM4A(before))

        let enc = Encryptor(key: SymmetricKey(size: .bits256))
        let store = AudioClipStore(directory: dir, encryptor: enc, encryptNewFiles: true)
        store.migrateAll()

        // 迁移后应为密文，且解密后能解码出样本（恢复可用、不丢数据）。
        let after = try Data(contentsOf: url)
        XCTAssertTrue(after.starts(with: AudioClipStore.audioMagic), "CAF 历史录音应被加密")
        XCTAssertFalse(try XCTUnwrap(store.loadSamples(fileName: name)).isEmpty, "解密后应能解码出样本")
    }

    func testSaveEmptySamplesReturnsNil() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AudioClipStore(directory: dir)
        XCTAssertNil(store.save(samples: [], id: "empty"))
    }

    func testDeleteRemovesFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AudioClipStore(directory: dir)

        let name = try XCTUnwrap(store.save(samples: sineSamples(), id: "todelete"))
        XCTAssertTrue(store.exists(name))
        store.delete(fileName: name)
        XCTAssertFalse(store.exists(name))
    }

    func testDeleteAllClearsDirectory() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AudioClipStore(directory: dir)

        _ = store.save(samples: sineSamples(), id: "a")
        _ = store.save(samples: sineSamples(), id: "b")
        XCTAssertGreaterThan(store.totalBytes(), 0)

        store.deleteAll()
        XCTAssertFalse(store.exists("a.m4a"))
        XCTAssertFalse(store.exists("b.m4a"))
        XCTAssertEqual(store.totalBytes(), 0)
    }

    func testPruneOrphansKeepsOnlyKnownFiles() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AudioClipStore(directory: dir)

        _ = store.save(samples: sineSamples(), id: "keep")
        _ = store.save(samples: sineSamples(), id: "orphan")

        store.pruneOrphans(keeping: ["keep.m4a"])
        XCTAssertTrue(store.exists("keep.m4a"))
        XCTAssertFalse(store.exists("orphan.m4a"))
    }

    func testExistsHandlesNilAndMissing() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AudioClipStore(directory: dir)
        XCTAssertFalse(store.exists(nil))
        XCTAssertFalse(store.exists(""))
        XCTAssertFalse(store.exists("nope.m4a"))
    }
}

final class PolishLogAudioFieldsTests: XCTestCase {

    /// 旧数据（无 id / audioFile 字段）必须仍能解码，且两字段为 nil。
    func testDecodesLegacyEntryWithoutNewFields() throws {
        let legacyJSON = """
        {"time":"2026-05-18 10:00:00","app":"Finder","asr":"hi","output":"hi","duration_ms":1,"input_tokens":0,"output_tokens":0}
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let log = try JSONDecoder().decode(AIPolisher.PolishLog.self, from: data)
        XCTAssertNil(log.id)
        XCTAssertNil(log.audioFile)
        XCTAssertEqual(log.output, "hi")
    }

    func testStableIdentityUsesIdWhenPresentElseFallsBack() {
        let withID = AIPolisher.PolishLog(time: "t", app: "a", asr: "x", output: "y",
                                          duration_ms: 0, input_tokens: 0, output_tokens: 0,
                                          id: "uuid-1", audioFile: "uuid-1.m4a")
        XCTAssertEqual(withID.stableIdentity(lineIndex: 5), "uuid-1")

        let legacy = AIPolisher.PolishLog(time: "t", app: "a", asr: "x", output: "y",
                                          duration_ms: 0, input_tokens: 0, output_tokens: 0)
        XCTAssertTrue(legacy.stableIdentity(lineIndex: 5).hasPrefix("legacy-5-"))
    }

    /// 裁剪过期记录时，onRemove 应带出被删记录（含 audioFile），供调用方删音频。
    func testPruneReportsRemovedAudioFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicepolish-prune-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("polish_log.jsonl")

        let encoder = JSONEncoder()
        let keep = AIPolisher.PolishLog(time: "2026-05-18 10:00:00", app: "F", asr: "keep", output: "keep",
                                        duration_ms: 1, input_tokens: 0, output_tokens: 0,
                                        id: "keep-id", audioFile: "keep-id.m4a")
        let drop = AIPolisher.PolishLog(time: "2026-05-18 09:59:59", app: "F", asr: "drop", output: "drop",
                                        duration_ms: 1, input_tokens: 0, output_tokens: 0,
                                        id: "drop-id", audioFile: "drop-id.m4a")
        let content = try [drop, keep]
            .map { try String(data: encoder.encode($0), encoding: .utf8)! }
            .joined(separator: "\n") + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)

        var removedAudio: [String] = []
        let removed = AIPolisher.pruneLogFile(at: file, retention: .oneDay,
                                              now: fixedDate("2026-05-19 10:00:00")) { log in
            if let a = log.audioFile { removedAudio.append(a) }
        }

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(removedAudio, ["drop-id.m4a"])
    }

    private func fixedDate(_ raw: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)!
    }
}
