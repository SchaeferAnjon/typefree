import Foundation

/// 判断「用户把 old 改成 new」像不像在纠正语音识别的听错，供纠错自动学习把关（2026-09-11）。
/// 听错的特点是读音相近（玉米→域名、徐翔→徐相、OpenWrt→OpenWiki）；读音不像的多半是在改内容
/// （周四→周三、共5→共4、测试一下→要求后续变更），学成全局替换会把以后正确的字改错。
public enum MishearingCheck {

    /// 意义不同的同音字：换它们是用户在选意思（他→她、的→得），不是纠正听错，不学
    static let meaningfulHomophones: [Set<Character>] = [
        ["他", "她", "它", "牠"], ["的", "得", "地"], ["在", "再"], ["那", "哪"],
        ["做", "作"], ["已", "以"], ["像", "象"], ["须", "需"], ["即", "既"],
    ]

    /// 声母里容易听混的几组（平翘舌、n/l、f/h、r/l）
    static let similarInitials: [Set<String>] = [["zh", "z"], ["ch", "c"], ["sh", "s"], ["n", "l"], ["f", "h"], ["r", "l"]]

    static let initials = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r", "z", "c", "s", "y", "w"]

    /// 英文/拼音串之间允许的最大差异比例（编辑距离 ÷ 较长者长度）
    static let maxLatinDifference = 0.5

    public static func isLikelyMishearing(old: String, new: String) -> Bool {
        // 阿拉伯数字变了是在改内容（汉字数字照读音比：说五→说无 是听错）
        func digits(_ s: String) -> String { s.filter { ("0"..."9").contains($0) || ("０"..."９").contains($0) } }
        guard digits(old) == digits(new) else { return false }
        let a = units(of: old), b = units(of: new)
        guard !a.isEmpty, !b.isEmpty, a != b else { return false }

        if a.allSatisfy(\.isHan), b.allSatisfy(\.isHan) {
            // 纯中文：字数相同、逐字读音相近；只有一个字的同音替换做成全局规则太危险，不学
            guard a.count == b.count, a.count >= 2 else { return false }
            var changed = false
            for (x, y) in zip(a, b) where x.char != y.char {
                changed = true
                if meaningfulHomophones.contains(where: { $0.contains(x.char) && $0.contains(y.char) }) { return false }
                guard syllablesSoundAlike(x.sound, y.sound) else { return false }
            }
            return changed
        }

        // 带英文：拼成拼音/字母串比差异
        let s = a.map(\.sound).joined(), t = b.map(\.sound).joined()
        guard s != t else { return false }
        let distance = Double(editDistance(Array(s), Array(t)))
        return distance / Double(max(s.count, t.count)) <= maxLatinDifference
    }

    // MARK: - 细节

    struct Unit: Equatable {
        let char: Character   // 汉字本身；英文段为段首字符（只用于判断是否汉字）
        let sound: String     // 汉字 = 无声调拼音；英文段 = 小写字母数字
        let isHan: Bool
    }

    /// 汉字逐字转拼音，连续的英文字母/数字合成一段，空格和标点忽略
    static func units(of text: String) -> [Unit] {
        var result: [Unit] = []
        var latin = ""
        func flushLatin() {
            if let first = latin.first { result.append(Unit(char: first, sound: latin.lowercased(), isHan: false)) }
            latin = ""
        }
        for ch in text {
            if isHan(ch) {
                flushLatin()
                result.append(Unit(char: ch, sound: pinyin(of: ch), isHan: true))
            } else if ch.isASCII && (ch.isLetter || ch.isNumber) {
                latin.append(ch)
            } else {
                flushLatin()
            }
        }
        flushLatin()
        return result
    }

    static func isHan(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let v = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    static func pinyin(of ch: Character) -> String {
        let s = NSMutableString(string: String(ch))
        CFStringTransform(s, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(s, nil, kCFStringTransformStripDiacritics, false)
        return (s as String).lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// 同音算像；否则声母相同或属于易混组，且韵母去掉鼻音尾（n/ng）后相同（mi≈ming、chen≈cheng、an≈ang）
    static func syllablesSoundAlike(_ x: String, _ y: String) -> Bool {
        if x == y { return true }
        let (ix, fx) = split(x), (iy, fy) = split(y)
        let initialsOK = ix == iy || similarInitials.contains { $0.contains(ix) && $0.contains(iy) }
        return initialsOK && finalCore(fx) == finalCore(fy)
    }

    static func split(_ syllable: String) -> (initial: String, final: String) {
        for i in initials where syllable.hasPrefix(i) && syllable.count > i.count {
            return (i, String(syllable.dropFirst(i.count)))
        }
        return ("", syllable)
    }

    static func finalCore(_ final: String) -> String {
        if final.hasSuffix("ng") { return String(final.dropLast(2)) }
        if final.hasSuffix("n") { return String(final.dropLast()) }
        return final
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[b.count]
    }
}
