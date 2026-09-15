import XCTest
@testable import VoicePolishCore

final class SupportChatTests: XCTestCase {
    private func out(text: String = "hi", image: Data? = nil, audio: Data? = nil, log: String? = nil) -> SupportChatService.Outgoing {
        SupportChatService.Outgoing(text: text, imageJPEG: image, audioM4A: audio, log: log,
                                    deviceName: "Mac", appVersion: "3.0")
    }

    func testEmptyMessageWithoutAttachmentIsRejected() {
        XCTAssertNil(SupportChatService.makePayload(out(text: "   "), deviceID: "d", secret: nil, osVersion: "26.0"))
    }

    func testImageOnlyMessageIsAllowedAndBase64Encoded() {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        let p = SupportChatService.makePayload(out(text: "", image: png), deviceID: "d", secret: "s", osVersion: "26.0")
        XCTAssertEqual(p?["image_b64"] as? String, png.base64EncodedString())
        XCTAssertEqual(p?["secret"] as? String, "s")
        XCTAssertEqual(p?["text"] as? String, "")
    }

    func testOversizeAttachmentsAreDroppedNotSent() {
        let big = Data(count: SupportChatService.maxImageBytes + 1)
        let p = SupportChatService.makePayload(out(text: "x", image: big), deviceID: "d", secret: nil, osVersion: "26.0")
        XCTAssertNil(p?["image_b64"], "超限的截图不该上传")
        XCTAssertNil(p?["secret"], "首次发消息没有凭证")
    }

    func testLogIsTruncatedFromTheEnd() {
        let long = String(repeating: "a", count: SupportChatService.maxLogChars) + "TAIL"
        let p = SupportChatService.makePayload(out(log: long), deviceID: "d", secret: nil, osVersion: "26.0")
        let log = p?["log"] as? String
        XCTAssertEqual(log?.count, SupportChatService.maxLogChars)
        XCTAssertTrue(log?.hasSuffix("TAIL") == true, "留最新的一段")
    }

    func testUnreadCountsOnlyAdminMessagesAfterLastSeen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("support-test-\(UUID().uuidString)")
        let suite = UserDefaults(suiteName: "support-test-\(UUID().uuidString)")!
        let list = [
            SupportMessage(id: 1, role: .user, text: "q", createdAt: "2026-09-15 08:00:00"),
            SupportMessage(id: 2, role: .admin, text: "a", createdAt: "2026-09-15 08:01:00"),
            SupportMessage(id: 3, role: .admin, text: "b", createdAt: "2026-09-15 08:02:00"),
        ]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: dir.appendingPathComponent("support.json"))
        let service = SupportChatService(defaults: suite, storeDir: dir, apiBase: "http://127.0.0.1:1")
        XCTAssertEqual(service.messages.count, 3)
        XCTAssertEqual(service.unreadCount, 2)
        service.markAllSeen()
        XCTAssertEqual(service.unreadCount, 0)
        XCTAssertFalse(service.hasThread)
    }
}
