import Foundation

// MARK: - 场景分类

/// 按前台 App 把一次输入归到一个"场合"。
/// 风格画像分两层：人身特征（跟人走，全局学）+ 场合特征（跟场合走，按场景学）——
/// 在工作软件里爱用列表 ≠ 跟朋友聊天也要列表（owner 2026-07 指出的关键区分）。
public enum SceneCategory: String, CaseIterable, Codable {
    case chat      // 聊天/即时通讯
    case writing   // 文档/笔记/邮件
    case coding    // 开发工具/终端
    case ai        // AI 对话
    case other     // 其他（含浏览器——里面什么都有，不可分类）

    public var displayName: String {
        switch self {
        case .chat: return "聊天对话"
        case .writing: return "文档写作"
        case .coding: return "开发工具"
        case .ai: return "AI 对话"
        case .other: return "其他场景"
        }
    }

    /// 按 App 名称归类（大小写不敏感的包含匹配；识别不了归 other）。
    /// 注意顺序：先 chat/ai 再 coding/writing，避免"微信输入法""Copilot"这类名字被抢先误归。
    public static func classify(appName: String?) -> SceneCategory {
        guard let raw = appName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return .other }

        let chatKeys = ["微信", "wechat", "wecom", "企业微信", "qq", "钉钉", "dingtalk",
                        "飞书", "lark", "feishu", "telegram", "whatsapp", "slack",
                        "discord", "messages", "信息", "imessage"]
        let aiKeys = ["claude", "chatgpt", "豆包", "doubao", "kimi", "元宝", "deepseek",
                      "gemini", "perplexity", "通义", "文心", "copilot"]
        let codingKeys = ["xcode", "cursor", "vs code", "vscode", "terminal", "终端", "iterm",
                          "warp", "intellij", "pycharm", "webstorm", "goland", "android studio",
                          "zed", "sublime", "fleet", "code"]
        let writingKeys = ["word", "pages", "备忘录", "notes", "notion", "obsidian", "typora",
                           "ulysses", "bear", "语雀", "yuque", "wps", "石墨", "craft",
                           "textedit", "邮件", "mail", "outlook", "docs"]

        if chatKeys.contains(where: raw.contains) { return .chat }
        if aiKeys.contains(where: raw.contains) { return .ai }
        if codingKeys.contains(where: raw.contains) { return .coding }
        if writingKeys.contains(where: raw.contains) { return .writing }
        return .other
    }
}

// MARK: - 风格画像

/// 风格画像：从用户的历史成稿统计表达习惯，生成可拼进润色 system prompt 的段落。
/// 全本地统计、确定性输出；信号不显著就闭嘴，数据不足宁缺毋滥。
public enum StyleProfiler {

    /// 一层画像至少要这么多条有效成稿——"越用越懂你"的自然起点。
    public static let minRecords = 10
    /// 每层最多回看这么多条（调用方按新→旧传入），旧习惯自然淡出。
    public static let maxRecords = 100

    /// 一条样本：成稿 + 识别原文（原话用于判断"你怎么说"，如列表口癖）。
    public struct Sample {
        public let output: String
        public let asr: String

        public init(output: String, asr: String) {
            self.output = output
            self.asr = asr
        }
    }

    // MARK: 全局层（人身特征：跟人走，不随场合变）

    /// 全局画像段落：中英混说 / 句子节奏 / 语气词。数据不足或无显著信号返回 nil。
    public static func globalPromptSection(fromOutputs outputs: [String]) -> String? {
        let usable = usableTexts(outputs)
        guard usable.count >= minRecords else { return nil }
        let traits = personTraits(usable)
        guard !traits.isEmpty else { return nil }
        return section(header: "## 该用户的表达习惯（依据其历史成稿自动统计）", traits: traits)
    }

    /// 场景画像段落：列表 / 感叹号 / 敬语 / 分段——这些跟场合走，只用该场景自己的历史。
    public static func scenePromptSection(scene: SceneCategory, samples: [Sample]) -> String? {
        let usable = samples.filter { $0.output.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5 }
        let window = Array(usable.prefix(maxRecords))
        guard window.count >= minRecords else { return nil }
        let traits = sceneTraits(window)
        guard !traits.isEmpty else { return nil }
        return section(header: "## 当前场景（\(scene.displayName)）里该用户的习惯（依据该场景的历史成稿统计）",
                       traits: traits)
    }

    private static func section(header: String, traits: [String]) -> String {
        let lines = traits.prefix(5).map { "- \($0)" }.joined(separator: "\n")
        return """
        \(header)
        在忠实原意的前提下，让整理结果贴合以下习惯：
        \(lines)
        """
    }

    // MARK: 人身特征

    static func personTraits(_ texts: [String]) -> [String] {
        var traits: [String] = []
        let joined = texts.joined(separator: "\n")

        var cjkCount = 0
        var latinCount = 0
        var particleCount = 0
        let particles: Set<Character> = ["哈", "啦", "嘛", "呀", "哦", "嘞", "咯", "呗", "嘿", "哟"]

        for char in joined {
            if isCJK(char) {
                cjkCount += 1
                if particles.contains(char) { particleCount += 1 }
            } else if char.isASCII && char.isLetter {
                latinCount += 1
            }
        }

        // 1. 中英混排：防止润色模型翻译或改写英文术语
        if latinCount >= 200, Double(latinCount) / Double(max(1, latinCount + cjkCount)) >= 0.08 {
            traits.append("常中英混说：英文单词、产品名、代码术语一律保留原文与原大小写，绝不翻译")
        }

        // 2. 句子长短（中位数，低位中值，确定性）
        let sentenceLengths = sentenceSegments(in: joined).map(\.count).sorted()
        if !sentenceLengths.isEmpty {
            let median = sentenceLengths[(sentenceLengths.count - 1) / 2]
            if median <= 14 {
                traits.append("偏好简短直接的句子，不要把短句合并成长句")
            } else if median >= 40 {
                traits.append("习惯较长的完整句子，不要过度切碎")
            }
        }

        // 3. 语气词密度（每百个汉字）——这些字是用户亲口说的
        if cjkCount >= 300, Double(particleCount) / Double(max(1, cjkCount)) * 100 >= 0.6 {
            traits.append("说话自带轻微语气词（如「哈、啦、呀」），保留这种亲和语气，不要删光")
        }

        return traits
    }

    // MARK: 场合特征

    static func sceneTraits(_ samples: [Sample]) -> [String] {
        var traits: [String] = []
        let outputs = samples.map(\.output)
        let joined = outputs.joined(separator: "\n")
        let totalChars = max(1, joined.count)

        // 1. 列表：不看"模型排没排"，看"用户嘴里有没有真的并列着说"——
        //    成稿有列表 且 原话出现两种以上并列口癖（第一/第二/一是/再一个…）才算一次。
        let listRecords = samples.filter { containsListLine($0.output) && spokenEnumeration(in: $0.asr) }.count
        let listRatio = Double(listRecords) / Double(samples.count)
        if listRatio >= 0.25 {
            traits.append("在这类场合常并列着说事情，符合条件时大胆用编号列表")
        } else if Double(outputs.filter(containsListLine).count) / Double(samples.count) <= 0.02, samples.count >= 30 {
            traits.append("在这类场合几乎不用列表、倾向自然段落，非明确并列不要拆成列表")
        }

        // 2. 感叹号
        var exclamationCount = 0
        for char in joined where char == "！" || char == "!" { exclamationCount += 1 }
        if Double(exclamationCount) / Double(totalChars) * 100 >= 0.5 {
            traits.append("在这类场合常用感叹号表达情绪，适度保留")
        } else if exclamationCount == 0, samples.count >= 30 {
            traits.append("在这类场合从不使用感叹号，也不要替他添加")
        }

        // 3. 敬语——对谁说话用什么称呼也是场合属性（对客户"您"、对朋友"你"）
        let ninCount = countOccurrences(of: "您", in: joined)
        let niCount = countOccurrences(of: "你", in: joined)
        if ninCount >= 5, ninCount >= niCount {
            traits.append("在这类场合称呼他人常用敬语「您」")
        }

        // 4. 长内容分段习惯（样本足够才判断）
        let longTexts = outputs.filter { $0.count >= 100 }
        if longTexts.count >= 5 {
            let withBreaks = longTexts.filter { $0.contains("\n") }.count
            if Double(withBreaks) / Double(longTexts.count) >= 0.5 {
                traits.append("长内容习惯分段呈现，别堆成一大段")
            }
        }

        return traits
    }

    // MARK: - 小工具

    static func usableTexts(_ outputs: [String]) -> [String] {
        Array(
            outputs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 5 }
                .prefix(maxRecords)
        )
    }

    /// 原话里是否出现两种以上并列口癖——"用户真的在并列着说"，而非模型自作主张排版。
    static func spokenEnumeration(in asr: String) -> Bool {
        let markers = ["第一", "第二", "第三", "首先", "其次", "一是", "二是", "三是",
                       "再一个", "另一个", "还有一个", "一个是"]
        var distinct = 0
        for marker in markers where asr.contains(marker) {
            distinct += 1
            if distinct >= 2 { return true }
        }
        return false
    }

    static func sentenceSegments(in text: String) -> [String] {
        text.split(whereSeparator: { "。！？!?；;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func containsListLine(_ text: String) -> Bool {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first else { continue }
            if first == "-" || first == "•" { return true }
            if first.isNumber {
                let afterDigits = trimmed.drop(while: { $0.isNumber })
                if let punct = afterDigits.first, ".、．)）".contains(punct) { return true }
            }
        }
        return false
    }

    private static func countOccurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    private static func isCJK(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
    }
}

// MARK: - 画像存取

/// 落盘的画像快照：全局段落 + 各场景段落（key 为 SceneCategory.rawValue）。
public struct StyleProfileSnapshot: Codable, Equatable {
    public let globalSection: String?
    public let sceneSections: [String: String]
    public let recordCount: Int
    public let computedAt: Date

    public init(globalSection: String?, sceneSections: [String: String], recordCount: Int, computedAt: Date) {
        self.globalSection = globalSection
        self.sceneSections = sceneSections
        self.recordCount = recordCount
        self.computedAt = computedAt
    }
}

/// 画像文件：与 config.json 同目录的 style_profile.json。
/// 由 App 的自动学习调度器写入；AIPolisher / Omni 在拼 system prompt 时读取。
public enum StyleProfileStore {

    public static func defaultFileURL() -> URL {
        VoicePolishConfig.shared.configFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("style_profile.json")
    }

    public static func load(from url: URL = defaultFileURL()) -> StyleProfileSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StyleProfileSnapshot.self, from: data)
    }

    public static func save(_ snapshot: StyleProfileSnapshot, to url: URL = defaultFileURL()) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func clear(at url: URL = defaultFileURL()) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 按当前前台 App 组装注入段落：全局层 + 对应场景层（other 场景不学也不注入）。
    /// 两层都没有内容时返回 nil。
    public static func promptSection(forAppName appName: String?, from url: URL = defaultFileURL()) -> String? {
        guard let snapshot = load(from: url) else { return nil }
        var parts: [String] = []
        if let global = snapshot.globalSection,
           !global.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(global)
        }
        let scene = SceneCategory.classify(appName: appName)
        if scene != .other, let sceneSection = snapshot.sceneSections[scene.rawValue],
           !sceneSection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(sceneSection)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// 不带场景信息时（如 Omni 路径）只取全局层。
    public static func promptSection(from url: URL = defaultFileURL()) -> String? {
        promptSection(forAppName: nil, from: url)
    }
}
