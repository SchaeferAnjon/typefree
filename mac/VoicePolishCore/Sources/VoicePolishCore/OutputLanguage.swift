import Foundation

/// 输出语言：语音口令的目标，也可设为「默认输出语言」（不管说什么都翻成它）。
/// 内置几种常用语言；用户可改触发词、开关，也可添加任意语言（模型能翻它认识的任何语言）。
public struct OutputLanguage: Equatable, Codable {
    public let id: String          // en / ja / ko / zh / fr / de / es，自定义为 custom-xxx
    public var name: String        // 显示名，也用于给模型的指令（「用日文输出」）
    public var tag: String         // 胶囊上的小标签（EN / JA / KO）
    public var phrases: [String]   // 触发口令
    public var enabled: Bool

    public init(id: String, name: String, tag: String, phrases: [String], enabled: Bool) {
        self.id = id; self.name = name; self.tag = tag; self.phrases = phrases; self.enabled = enabled
    }

    public var isBuiltin: Bool { !id.hasPrefix("custom-") }

    public static let listConfigKey = "output_languages"
    public static let defaultConfigKey = "default_output_language"   // 语言 id；空 = 跟随说话语言
    public static let commandEnabledConfigKey = "output_language_command_enabled"

    public static let builtin: [OutputLanguage] = [
        OutputLanguage(id: "en", name: "英文", tag: "EN", phrases: [
            "用英文", "用英语", "翻译成英文", "翻译成英语", "翻成英文", "翻成英语", "转成英文", "转英文",
            "英文输出", "输出英文", "说英文", "English", "in English",
        ], enabled: true),
        OutputLanguage(id: "ja", name: "日文", tag: "JA", phrases: [
            "用日文", "用日语", "翻译成日文", "翻译成日语", "翻成日文", "翻成日语", "转日文",
            "日文输出", "输出日文", "说日语", "Japanese", "日本語",
        ], enabled: true),
        OutputLanguage(id: "ko", name: "韩文", tag: "KO", phrases: [
            "用韩文", "用韩语", "翻译成韩文", "翻译成韩语", "翻成韩文", "翻成韩语", "转韩文",
            "韩文输出", "输出韩文", "说韩语", "Korean", "한국어",
        ], enabled: true),
        OutputLanguage(id: "zh", name: "中文", tag: "ZH", phrases: [
            "用中文", "翻译成中文", "翻成中文", "转中文", "中文输出", "输出中文", "说中文", "Chinese",
        ], enabled: true),
        OutputLanguage(id: "fr", name: "法语", tag: "FR", phrases: ["用法语", "翻译成法语", "翻成法语", "法语输出", "French"], enabled: false),
        OutputLanguage(id: "de", name: "德语", tag: "DE", phrases: ["用德语", "翻译成德语", "翻成德语", "德语输出", "German"], enabled: false),
        OutputLanguage(id: "es", name: "西班牙语", tag: "ES", phrases: ["用西班牙语", "翻译成西班牙语", "西班牙语输出", "Spanish"], enabled: false),
    ]

    // MARK: - 持久化（config.json 的 output_languages：内置项按 id 覆盖，自定义项追加）

    public static func configured(config: VoicePolishConfig = .shared) -> [OutputLanguage] {
        guard let stored = config.loadConfig()[listConfigKey] as? [[String: Any]] else { return builtin }
        var byID: [String: [String: Any]] = [:]
        for item in stored { if let id = item["id"] as? String { byID[id] = item } }
        var result = builtin.map { base -> OutputLanguage in
            guard let s = byID[base.id] else { return base }
            var l = base
            if let name = s["name"] as? String, !name.isEmpty { l.name = name }
            if let tag = s["tag"] as? String, !tag.isEmpty { l.tag = tag }
            if let phrases = s["phrases"] as? [String] { l.phrases = phrases }
            if let enabled = s["enabled"] as? Bool { l.enabled = enabled }
            return l
        }
        for item in stored {
            guard let id = item["id"] as? String, id.hasPrefix("custom-"),
                  let name = item["name"] as? String, !name.isEmpty else { continue }
            result.append(OutputLanguage(id: id,
                                         name: name,
                                         tag: (item["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.makeTag(for: name),
                                         phrases: item["phrases"] as? [String] ?? [],
                                         enabled: item["enabled"] as? Bool ?? true))
        }
        return result
    }

    public static func save(_ list: [OutputLanguage], config: VoicePolishConfig = .shared) {
        let items: [[String: Any]] = list.map { ["id": $0.id, "name": $0.name, "tag": $0.tag, "phrases": $0.phrases, "enabled": $0.enabled] }
        config.save(values: [listConfigKey: items])
    }

    /// 默认输出语言；nil = 跟随说话语言
    public static func defaultLanguage(config: VoicePolishConfig = .shared) -> OutputLanguage? {
        guard let id = config.string(forKey: defaultConfigKey), !id.isEmpty else { return nil }
        return configured(config: config).first { $0.id == id }
    }

    public static func makeCustom(name: String, phrases: [String]) -> OutputLanguage {
        OutputLanguage(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), name: name, tag: makeTag(for: name), phrases: phrases, enabled: true)
    }

    /// 自定义语言的标签：取名字前两个字符（「泰语」→「泰语」；「Thai」→「TH」）
    static func makeTag(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.unicodeScalars.allSatisfy({ $0.isASCII }) { return String(trimmed.prefix(2)).uppercased() }
        return String(trimmed.prefix(2))
    }

    public static func parsePhrases(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
