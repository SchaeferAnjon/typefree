import Foundation

/// 一次发版在 appcast 里的记录。
public struct AppcastEntry: Equatable {
    public let version: String       // 展示用版本号（sparkle:shortVersionString，缺失时回落 title）
    public let pubDate: Date?        // 发布时间（RFC 822）
    public let notesHTML: String     // 更新说明（<description> 的 CDATA），没有则为空串

    public init(version: String, pubDate: Date?, notesHTML: String) {
        self.version = version
        self.pubDate = pubDate
        self.notesHTML = notesHTML
    }
}

/// 解析 Sparkle appcast.xml，取出「更新历史」需要的字段。
///
/// 为什么复用 appcast 而不另建更新日志文件：它已经随每次发版更新、已经在线上、
/// 且本来就带版本号与发布日期——一份数据同时喂给 Sparkle 更新弹窗和 App 内更新历史。
public enum AppcastParser {

    /// 按版本从新到旧返回；解析失败返回空数组（调用方按"暂时取不到"处理即可）。
    public static func parse(_ xml: String) -> [AppcastEntry] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        // appcast 里通常旧版在前；统一按发布时间倒序，没有日期的排最后但保持相对顺序。
        return delegate.entries.enumerated().sorted { a, b in
            switch (a.element.pubDate, b.element.pubDate) {
            case let (x?, y?): return x > y
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// appcast 用 RFC 822（如 "Fri, 07 Aug 2026 02:16:53 +0000"）。
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [AppcastEntry] = []

        private var inItem = false
        private var currentElement = ""
        private var title = ""
        private var shortVersion = ""
        private var pubDateText = ""
        private var descriptionText = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            currentElement = elementName
            if elementName == "item" {
                inItem = true
                title = ""; shortVersion = ""; pubDateText = ""; descriptionText = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inItem else { return }
            switch currentElement {
            case "title":                       title += string
            case "sparkle:shortVersionString":  shortVersion += string
            case "pubDate":                     pubDateText += string
            case "description":                 descriptionText += string
            default: break
            }
        }

        /// 更新说明用 CDATA 包裹（内含 HTML 标签），走这个回调而非 foundCharacters。
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard inItem, currentElement == "description",
                  let s = String(data: CDATABlock, encoding: .utf8) else { return }
            descriptionText += s
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "item" {
                let version = shortVersion.trimmed.isEmpty ? title.trimmed : shortVersion.trimmed
                if !version.isEmpty {
                    entries.append(AppcastEntry(
                        version: version,
                        pubDate: AppcastParser.dateFormatter.date(from: pubDateText.trimmed),
                        notesHTML: descriptionText.trimmed))
                }
                inItem = false
            }
            currentElement = ""
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
