import XCTest
@testable import VoicePolishCore

final class FeedbackServiceTests: XCTestCase {
    func testPayloadTrimsAndIncludesVersions() {
        let p = FeedbackService.makePayload(message: "  识别有点慢  ", appVersion: "2.3", osVersion: "26.4")
        XCTAssertEqual(p?["message"], "识别有点慢")
        XCTAssertEqual(p?["app_version"], "2.3")
        XCTAssertEqual(p?["os_version"], "26.4")
    }

    func testPayloadNilForBlank() {
        XCTAssertNil(FeedbackService.makePayload(message: "   \n ", appVersion: "2.3", osVersion: "26.4"))
        XCTAssertNil(FeedbackService.makePayload(message: "", appVersion: "2.3", osVersion: "26.4"))
    }

    func testPayloadIncludesDeviceNameAndAttachment() {
        let audio = Data([0x01, 0x02, 0x03])
        let p = FeedbackService.makePayload(
            message: "优化结果不对", appVersion: "2.4", osVersion: "26.4",
            deviceName: "Ray 的 MacBook Pro",
            attachment: .init(asrText: "原始转写", polishedText: "优化结果", audioData: audio))
        XCTAssertEqual(p?["device_name"], "Ray 的 MacBook Pro")
        XCTAssertEqual(p?["asr_text"], "原始转写")
        XCTAssertEqual(p?["polished_text"], "优化结果")
        XCTAssertEqual(p?["audio_b64"], audio.base64EncodedString())
    }

    func testPayloadIncludesModelEnvironmentWhenProvided() {
        let env = FeedbackService.ModelEnvironment(
            processingMode: "cloud_only",
            asrProvider: "volcano",
            asrVersion: "turbo",
            asrModel: "volc.bigasr.auc_turbo",
            asrResourceID: "volc.bigasr.auc_turbo",
            polishProvider: "qwen",
            polishModel: "qwen3.6-flash")
        let p = FeedbackService.makePayload(
            message: "识别不准",
            appVersion: "2.4",
            osVersion: "26.4",
            modelEnvironment: env)
        XCTAssertEqual(p?["processing_mode"], "cloud_only")
        XCTAssertEqual(p?["asr_provider"], "volcano")
        XCTAssertEqual(p?["asr_version"], "turbo")
        XCTAssertEqual(p?["asr_model"], "volc.bigasr.auc_turbo")
        XCTAssertEqual(p?["asr_resource_id"], "volc.bigasr.auc_turbo")
        XCTAssertEqual(p?["polish_provider"], "qwen")
        XCTAssertEqual(p?["polish_model"], "qwen3.6-flash")
    }

    func testPayloadOmitsOversizeOrMissingAudioButKeepsTexts() {
        let oversize = Data(count: FeedbackService.maxAudioBytes + 1)
        let p1 = FeedbackService.makePayload(
            message: "x", appVersion: "2.4", osVersion: "26.4",
            attachment: .init(asrText: "a", polishedText: "b", audioData: oversize))
        XCTAssertNil(p1?["audio_b64"])
        XCTAssertEqual(p1?["asr_text"], "a")

        let p2 = FeedbackService.makePayload(
            message: "x", appVersion: "2.4", osVersion: "26.4",
            attachment: .init(asrText: "a", polishedText: "b", audioData: nil))
        XCTAssertNil(p2?["audio_b64"])
        XCTAssertEqual(p2?["polished_text"], "b")
    }

    func testPayloadOmitsEmptyDeviceNameAndNilAttachment() {
        let p = FeedbackService.makePayload(message: "x", appVersion: "2.4", osVersion: "26.4")
        XCTAssertNil(p?["device_name"])
        XCTAssertNil(p?["asr_text"])
        XCTAssertNil(p?["audio_b64"])
    }

    func testSendRejectsBlankBeforeNetwork() {
        let exp = expectation(description: "blank rejected")
        FeedbackService.send(message: "   ", appVersion: "2.3", apiBase: "https://example.invalid") { result in
            if case .failure(.empty) = result { exp.fulfill() } else { XCTFail("应因空内容被拒") }
        }
        wait(for: [exp], timeout: 2)
    }
}
