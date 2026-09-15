import XCTest
@testable import VoicePolishCore

final class AppcastParserTests: XCTestCase {

    /// 与线上 appcast 同构：老版本无更新说明，新版本带 CDATA 说明。
    private let sample = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel>
            <title>Typefree</title>
            <description>Typefree updates</description>
            <item>
                <title>2.7.2</title>
                <sparkle:shortVersionString>2.7.2</sparkle:shortVersionString>
                <pubDate>Mon, 13 Jul 2026 07:31:10 +0000</pubDate>
                <enclosure url="https://example.com/a.dmg" length="1" type="application/octet-stream"/>
            </item>
            <item>
                <title>2.8.0</title>
                <sparkle:shortVersionString>2.8.0</sparkle:shortVersionString>
                <pubDate>Fri, 07 Aug 2026 02:16:53 +0000</pubDate>
                <description><![CDATA[<h3>免费额度改成按周算</h3><p>每周 1 万字，周一重置。</p>]]></description>
                <enclosure url="https://example.com/b.dmg" length="2" type="application/octet-stream"/>
            </item>
        </channel>
    </rss>
    """

    func testParsesVersionsNewestFirst() {
        let entries = AppcastParser.parse(sample)
        XCTAssertEqual(entries.map(\.version), ["2.8.0", "2.7.2"], "应按发布时间从新到旧")
    }

    func testParsesReleaseNotesFromCDATA() {
        let entries = AppcastParser.parse(sample)
        XCTAssertTrue(entries[0].notesHTML.contains("免费额度改成按周算"))
        XCTAssertTrue(entries[0].notesHTML.contains("<p>"), "HTML 标签应原样保留，交给渲染层")
    }

    func testEntryWithoutNotesIsKeptWithEmptyNotes() {
        let entries = AppcastParser.parse(sample)
        let old = entries.first { $0.version == "2.7.2" }
        XCTAssertNotNil(old, "没有更新说明的老版本也要出现在历史里")
        XCTAssertEqual(old?.notesHTML, "")
    }

    func testParsesPubDate() throws {
        let entries = AppcastParser.parse(sample)
        let d = try XCTUnwrap(entries[0].pubDate)
        // 2026-08-07 02:16:53 UTC
        XCTAssertEqual(d.timeIntervalSince1970, 1786069013, accuracy: 1)
    }

    func testChannelLevelDescriptionIsNotTreatedAsReleaseNotes() {
        // <channel> 自己也有 <description>Typefree updates</description>，不能混进任何条目
        let entries = AppcastParser.parse(sample)
        XCTAssertFalse(entries.contains { $0.notesHTML.contains("Typefree updates") })
    }

    func testMalformedXMLReturnsEmpty() {
        XCTAssertTrue(AppcastParser.parse("<rss><channel><item>").isEmpty)
        XCTAssertTrue(AppcastParser.parse("").isEmpty)
    }
}
