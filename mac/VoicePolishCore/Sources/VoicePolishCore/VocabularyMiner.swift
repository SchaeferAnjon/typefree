import Foundation

/// 从历史成稿里自动挖掘个人词汇（第一版只挖拉丁字母词：英文单词/产品名/技术术语）。
/// 中文专名的自动提取误学风险高，先不做；中文词仍走手动词库和纠错学习。
/// 全部为纯函数：输入历史文本与已有词表，输出应新增的词；读文件与写词库由调用方负责。
public enum VocabularyMiner {

    public struct Options {
        /// 至少出现在多少条不同记录里
        public var minRecords: Int
        /// 且跨多少个不同日期（防止一次长对话刷屏就入库）
        public var minDays: Int
        public var minLength: Int
        public var maxLength: Int

        public init(minRecords: Int = 3, minDays: Int = 2, minLength: Int = 2, maxLength: Int = 24) {
            self.minRecords = minRecords
            self.minDays = minDays
            self.minLength = minLength
            self.maxLength = maxLength
        }
    }

    /// 一条历史成稿：文本 + 日期（'YYYY-MM-DD'，取记录时间前 10 位）。
    public struct Sample {
        public let text: String
        public let day: String

        public init(text: String, day: String) {
            self.text = text
            self.day = day
        }
    }

    /// 常见英文词不学——它们不是"个人词汇"，学了只会挤占词表预算。
    static let stopwords: Set<String> = [
        // 功能词/代词/介词
        "the", "and", "for", "you", "your", "yours", "not", "but", "with", "this", "that", "these", "those",
        "have", "has", "had", "was", "were", "are", "is", "be", "been", "being", "will", "would", "can", "could",
        "should", "shall", "may", "might", "must", "do", "does", "did", "done", "doing", "get", "got", "go", "went",
        "from", "into", "onto", "about", "after", "before", "between", "during", "under", "over", "through",
        "all", "any", "some", "each", "every", "both", "few", "more", "most", "other", "same", "such",
        "than", "then", "them", "they", "their", "there", "here", "where", "when", "what", "which", "who", "whom",
        "why", "how", "our", "ours", "out", "off", "own", "she", "her", "his", "him", "its", "it's", "one", "two",
        "very", "just", "only", "also", "too", "now", "new", "old", "way", "well", "even", "still", "yet",
        "because", "while", "until", "unless", "though", "although", "however", "maybe", "perhaps",
        // 高频普通词
        "like", "make", "made", "want", "need", "know", "think", "thought", "see", "saw", "look", "come", "came",
        "take", "took", "give", "gave", "find", "found", "tell", "told", "say", "said", "use", "used", "using",
        "work", "working", "time", "day", "week", "month", "year", "today", "tomorrow", "yesterday",
        "good", "great", "nice", "bad", "right", "wrong", "true", "false", "big", "small", "long", "short",
        "high", "low", "first", "last", "next", "back", "down", "let", "lets", "let's", "please", "thanks",
        "thank", "sorry", "yes", "yeah", "yep", "okay", "hello", "bye",
        // 泛用数字/单位类
        "am", "pm", "vs", "etc", "eg", "ie",
    ]

    /// 挖出应新增的词（已按重要度排序、截断到 remainingCapacity）。
    /// - Parameters:
    ///   - samples: 历史成稿（顺序无关，日期用于跨日门槛）。
    ///   - existingLowercased: 已有词的小写集合（内置+自定义+词库正写与误写），命中不再学。
    ///   - dismissedLowercased: 用户删除过的自动词（小写），永不再学。
    ///   - remainingCapacity: 词库里自动词还能装几个。
    public static func newWords(from samples: [Sample],
                                existingLowercased: Set<String>,
                                dismissedLowercased: Set<String> = [],
                                remainingCapacity: Int = 60,
                                options: Options = Options()) -> [String] {
        guard remainingCapacity > 0 else { return [] }

        struct Stat {
            var forms: [String: Int] = [:]
            var records = 0
            var days: Set<String> = []
            var lastDay = ""
        }
        var stats: [String: Stat] = [:]   // key = 小写

        for sample in samples {
            let tokens = latinTokens(in: sample.text, minLength: options.minLength, maxLength: options.maxLength)
            guard !tokens.isEmpty else { continue }

            var seenInRecord = Set<String>()
            for token in tokens {
                let key = token.lowercased()
                if stopwords.contains(key) { continue }
                if existingLowercased.contains(key) { continue }
                if dismissedLowercased.contains(key) { continue }

                var stat = stats[key] ?? Stat()
                stat.forms[token, default: 0] += 1
                if !seenInRecord.contains(key) {
                    stat.records += 1
                    seenInRecord.insert(key)
                }
                stat.days.insert(sample.day)
                if sample.day > stat.lastDay { stat.lastDay = sample.day }
                stats[key] = stat
            }
        }

        struct Candidate {
            let word: String
            let records: Int
            let dayCount: Int
            let lastDay: String
        }

        let candidates: [Candidate] = stats.compactMap { _, stat in
            guard stat.records >= options.minRecords, stat.days.count >= options.minDays else { return nil }
            return Candidate(word: canonicalForm(of: stat.forms),
                             records: stat.records,
                             dayCount: stat.days.count,
                             lastDay: stat.lastDay)
        }

        return candidates
            .sorted { a, b in
                if a.dayCount != b.dayCount { return a.dayCount > b.dayCount }
                if a.records != b.records { return a.records > b.records }
                if a.lastDay != b.lastDay { return a.lastDay > b.lastDay }
                return a.word < b.word
            }
            .prefix(remainingCapacity)
            .map(\.word)
    }

    /// 多数写法为准；平票时偏好带大写的写法（多为产品名正写），再平取字典序，保证确定性。
    static func canonicalForm(of forms: [String: Int]) -> String {
        forms.max { a, b in
            if a.value != b.value { return a.value < b.value }
            let aHasUpper = a.key.contains(where: \.isUppercase)
            let bHasUpper = b.key.contains(where: \.isUppercase)
            if aHasUpper != bHasUpper { return !aHasUpper && bHasUpper }
            return a.key > b.key
        }?.key ?? ""
    }

    /// 提取拉丁字母词：以字母开头，可含数字与词内 `.-+#`（如 GPT-4、Node.js、C++、C#），
    /// 去掉首尾连接符；必须含字母。
    static func latinTokens(in text: String, minLength: Int, maxLength: Int) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flush() {
            defer { current = "" }
            var word = current
            // 只裁尾部悬挂的句点/连字符（"end." "Swift-"）；保留 + 和 #（C++、C#）
            while let last = word.last, last == "." || last == "-" { word.removeLast() }
            while let first = word.first, !first.isLetter { word.removeFirst() }
            guard word.count >= minLength, word.count <= maxLength else { return }
            guard let first = word.first, first.isASCII, first.isLetter else { return }
            guard word.contains(where: { $0.isLetter }) else { return }
            tokens.append(word)
        }

        for char in text {
            let isTokenChar = char.isASCII && (char.isLetter || char.isNumber || char == "." || char == "-" || char == "+" || char == "#")
            if isTokenChar {
                current.append(char)
            } else if !current.isEmpty {
                flush()
            }
        }
        if !current.isEmpty { flush() }
        return tokens
    }
}
