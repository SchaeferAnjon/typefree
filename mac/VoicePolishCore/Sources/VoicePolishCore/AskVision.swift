import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 问 AI 带屏幕内容时的图片准备与请求组装。都是纯计算，方便单测；
/// 真正的截图在 mac/Sources/ScreenSnapshot.swift（要 ScreenCaptureKit）。
///
/// 尺寸和质量参数照搬 GetNewWord 里逐轮实测过的值：图片 token 直接决定首字延迟，
/// Retina 原图 PNG（300 到 700KB）换成下面这两档 JPEG 后，上传和图片 token 一起省下来。
public enum AskVision {
    /// 整屏上下文图的长边（像素）。只用来看「这是什么界面」，压得比放大图狠。
    public static let overviewLongEdge: CGFloat = 1000
    public static let overviewQuality: CGFloat = 0.75
    /// 指针附近放大图：按原分辨率裁这么大（点），小字才认得出来
    public static let closeUpPointSize = CGSize(width: 900, height: 700)
    /// 放大图的长边上限（像素）。900 点在 2x 屏上正好 1800，超了再压到这个数。
    public static let closeUpLongEdge: CGFloat = 1600
    public static let closeUpQuality: CGFloat = 0.85

    /// 带图提问的整体超时。比纯文字短：带图还慢过这个数，等下去也没意义。
    public static let requestTimeout: TimeInterval = 30
    /// 超过这么久还没出首字就在面板里提示「网络较慢」，不让用户干等
    public static let slowHintAfter: TimeInterval = 8
    /// 带图提问的输出上限。慢的是生成不是上传：压住输出长度才是提速的大头。
    /// 智谱单独放宽：思考内容也算在 max_tokens 里，关思考万一没生效，给 600 会在思考阶段就被截断
    /// （GetNewWord 吃过这个亏）。上限放宽不影响速度，回答长度由提示词管。
    public static func maxTokens(provider: String) -> Int {
        provider == "zhipu" ? 2048 : 600
    }

    // MARK: - 图片尺寸

    /// 按长边上限算缩放系数，本来就小于上限就不放大。
    public static func scale(pixelSize: CGSize, longEdge: CGFloat) -> CGFloat {
        let maxEdge = max(pixelSize.width, pixelSize.height)
        guard maxEdge > 0 else { return 1 }
        return min(1, longEdge / maxEdge)
    }

    /// 以指针为中心的裁剪框（像素坐标，原点左上）。
    /// 贴到屏幕边缘时整体平移回图内而不是缩小，保证放大图始终是同一个尺寸、同一个清晰度；
    /// 整张图比裁剪框还小（小屏）就直接取整张。
    public static func closeUpRect(center: CGPoint,
                                   imagePixelSize: CGSize,
                                   pointSize: CGSize = closeUpPointSize,
                                   scale: CGFloat) -> CGRect {
        let want = CGSize(width: min(pointSize.width * scale, imagePixelSize.width),
                          height: min(pointSize.height * scale, imagePixelSize.height))
        var x = center.x - want.width / 2
        var y = center.y - want.height / 2
        x = min(max(0, x), max(0, imagePixelSize.width - want.width))
        y = min(max(0, y), max(0, imagePixelSize.height - want.height))
        return CGRect(x: x, y: y, width: want.width, height: want.height)
    }

    // MARK: - 视觉模型

    /// 各家的视觉模型候选，头一个是默认：一律先用 flash 档，
    /// 问的是「屏幕上这是什么」，快比强重要。额度类失败（403）时按顺序往后降级。
    /// 候选里只放确认支持图片输入的模型，纯文本模型绝不能混进来——带图请求发给纯文本模型只会报错。
    ///
    /// 依据（2026-09-21 查官方文档）：
    /// - 百炼「视觉理解」页推荐 qwen3.8-max 起步、想省钱换 qwen3.8-flash 或 qwen3.7-plus；
    ///   Qwen3-VL 系列的确切 ID 是 qwen3-vl-plus / qwen3-vl-flash。
    ///   https://help.aliyun.com/zh/model-studio/vision-model/
    /// - 智谱 Coding Plan 套餐只放行 GLM-5.3（纯文本）和 GLM-5.3-Flash（多模态），
    ///   官方 Cline 接入说明写明只有 GLM-5.3-Flash 能勾 Support Images，所以这里只有一个候选。
    ///   https://docs.bigmodel.cn/cn/coding-plan/overview
    /// - 方舟「视觉理解」推荐表里的 Model ID 直接填，不需要接入点 ep-xxx。
    ///   https://www.volcengine.com/docs/82379/1330310
    /// - DeepSeek 的 deepseek-flash 是 2026-09-21 本机实测最快的一档：同一份负载（两张图约 380KB）
    ///   首字 1.16 到 1.39 秒、总 1.4 到 1.6 秒，答案全对；智谱 2.3 到 4.0 秒，千问 3.2 到 4.2 秒。
    ///   https://api-docs.deepseek.com/
    /// - qwen3-vl-flash 实测虽然 3.1 秒但答错（幻觉），所以放在候选表最后。
    public static func visionCandidates(provider: String, override: String? = nil) -> [String] {
        if let override, !override.isEmpty { return [override] }
        switch provider {
        case "deepseek": return [DeepSeekEndpoint.defaultModel]
        case "qwen": return ["qwen3.8-flash", "qwen3.7-flash", "qwen3.8-max", "qwen3-vl-flash"]
        case "zhipu": return [ZhipuEndpoint.defaultModel]
        default: return ["doubao-seed-2-1-turbo-260628", "doubao-seed-2-1-lite-260915", "doubao-seed-2-1-pro-260915"]
        }
    }

    /// 默认视觉模型（候选表的头一个）
    public static func visionModel(provider: String, override: String? = nil) -> String {
        visionCandidates(provider: provider, override: override).first ?? ""
    }

    /// 视觉请求的端点。智谱走 Coding Plan 端点：按量端点 /api/paas/v4 对 Coding Plan 的 Key
    /// 会报 429/1113「余额不足」，那不是没钱，是端点不对。
    public static func visionEndpoint(provider: String) -> URL? {
        switch provider {
        case "deepseek": return DeepSeekEndpoint.chatCompletions
        case "qwen": return qwenChatCompletions
        case "zhipu": return ZhipuEndpoint.chatCompletions
        default: return URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")
        }
    }

    // MARK: - 联网搜索

    /// 千问的 OpenAI 兼容端点。联网走它，见 AskRoute。
    public static let qwenChatCompletions = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")

    /// 联网这一问用哪个模型。2026-09-21 实测 qwen3.8-flash 带图 + enable_search + forced_search
    /// 首字 4.0 秒左右、确实拿到了当天的汇率；qwen3.7-flash 略快但答得啰嗦，作次选。
    public static let searchModel = "qwen3.8-flash"

    /// 这一问走哪条路。
    public enum AskRoute: String, Sendable {
        /// 走用户当前选的提供方
        case direct
        /// 时效问题改走千问 + 联网搜索
        case qwenSearch = "qwen-search"
    }

}

/// 联网路由。
///
/// 三家能自带 Key 的提供方里只有千问能真的联网（DeepSeek 的 API 不认 web_search 工具，
/// 智谱 Coding Plan 的 web_search 工具不报错但实际不搜）。所以做法是：给当前模型带一个
/// web_search 函数工具，让它自己判断这一问要不要查；它一调用就把整问转给千问联网回答。
///
/// 不用关键词表判断，因为关键词表一定会漏：「Claude 现在最强的模型是哪个」里没有任何时效词。
/// 2026-09-21 用 deepseek-flash 实测 12 题全对（6 题该搜的全发起了工具调用，6 题该直答的全直答），
/// 而且带工具不增加延迟：直答首字 0.5 到 1.0 秒，发起工具调用 0.7 到 1.2 秒返回。
public enum AskSearch {
    public static let toolName = "web_search"

    /// 转给千问联网期间在浮窗里显示的状态
    public static let searchingNotice = "正在联网查…"
    /// 千问开始出字后换成这句，留在回答上方：让用户知道这条答案是查过的，不是模型凭记忆说的
    public static let searchedNotice = "已联网查询"

    /// 带给模型的函数工具。只定义一个，调用即转千问，不做「把搜索结果喂回来」的第二轮，
    /// 省一次往返（千问直接出最终答案）。
    public static func tools() -> [[String: Any]] {
        [[
            "type": "function",
            "function": [
                "name": toolName,
                "description": "联网搜索最新信息。答案可能随时间变化、或涉及近两年的事实时调用。",
                "parameters": [
                    "type": "object",
                    "properties": ["query": ["type": "string", "description": "搜索关键词"]],
                    "required": ["query"],
                ],
            ],
        ]]
    }

    /// 带工具时追加到 system prompt 的判定规则。当前时间由 askTimeLine 提供，这里不重复。
    public static let toolPromptSuffix = """

    你的训练知识有截止日期，可能已经过时。凡是答案可能随时间变化的问题（最新的产品/版本/模型、现任职务、价格、汇率、天气、新闻、赛事结果、近两年发生的事），必须调用 web_search，不要凭记忆回答；常识、概念解释、语言、数学、针对用户屏幕内容的问题直接回答。
    """

    /// 用户明说要联网：不用问模型，直接走千问。前缀词留在问题里无妨，搜索引擎不在乎。
    public static let explicitPrefixes = ["联网", "上网查", "上网搜", "搜一下", "查一下", "帮我搜", "帮我查", "搜索一下"]

    /// 转给千问的那一问。搜索词是当前模型看完屏幕后写的，附上它，千问不看图也知道用户指的是什么。
    public static func searchQuestion(_ question: String, query: String?) -> String {
        guard let query, !query.isEmpty, query != question else { return question }
        return "\(question)\n（用户是指着屏幕上的内容问的，助手据此整理出的检索词：\(query)）"
    }

    public static func hasExplicitSearchPrefix(_ question: String) -> Bool {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return explicitPrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// 这家的接口认不认 function 类型的 tools。
    /// deepseek 与 zhipu（Coding Plan 端点 + glm-5.3-flash）2026-09-21 本机实测都认，判断也准；
    /// doubao 手上没有 Key 没法验，拿不准就不带工具，它照常直答。
    public static func supportsFunctionTools(provider: String) -> Bool {
        provider == "deepseek" || provider == "zhipu"
    }

    /// 这一问要不要带工具：当前提供方不是千问（千问自己就能搜）、认 tools、且用户配了千问 Key。
    /// provider 为 nil = 走托管通道，那边服务器自己开了联网，不用带。
    public static func shouldOfferTool(provider: String?, hasQwenKey: Bool) -> Bool {
        guard let provider, provider != "qwen", hasQwenKey else { return false }
        return supportsFunctionTools(provider: provider)
    }
}

/// 流式里 tool_calls 增量的拼接。名字和参数都可能分片到达，也可能和 content 同时出现在一个块里；
/// 同一轮还可能并排发起多个调用（DeepSeek 实测会发两个，index 分别是 0 和 1），所以按 index 分开攒。
public struct ToolCallAccumulator: Equatable, Sendable {
    private var names: [Int: String] = [:]
    private var arguments: [Int: String] = [:]

    public init() {}

    /// 吃一份 choices[0].delta。返回 true = 此刻已经拼出了 target 这个工具名。
    @discardableResult
    public mutating func ingest(delta: [String: Any], lookingFor target: String) -> Bool {
        guard let calls = delta["tool_calls"] as? [[String: Any]] else { return false }
        var hit = false
        for call in calls {
            let index = (call["index"] as? Int) ?? 0
            guard let function = call["function"] as? [String: Any] else { continue }
            if let fragment = function["name"] as? String, !fragment.isEmpty {
                names[index, default: ""] += fragment
            }
            if let fragment = function["arguments"] as? String, !fragment.isEmpty {
                arguments[index, default: ""] += fragment
            }
            if names[index] == target { hit = true }
        }
        return hit
    }

    /// 已经拼完整的工具名（调试用）
    public var completedNames: [String] {
        names.keys.sorted().compactMap { names[$0] }
    }

    /// 某个调用攒到的参数 JSON
    public func argumentsJSON(at index: Int) -> String? { arguments[index] }

    /// 名叫 tool 的那个调用里模型写的搜索词；参数没吐完、不是合法 JSON 时返回 nil
    public func searchQuery(for tool: String) -> String? {
        guard let index = names.keys.sorted().first(where: { names[$0] == tool }),
              let raw = arguments[index], let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = (json["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else { return nil }
        return query
    }
}

extension AskVision {
    // MARK: - 请求组装

    /// 带图时追加到 system prompt 后面的说明。模型认画出来的标记比认坐标数字可靠得多，
    /// 所以只说「红色标记处」，不给它像素坐标。
    /// 后半段是给速度用的：慢的是生成，不是上传，压住输出长度首字才来得快。
    public static let screenPromptSuffix = """

    这次提问附带两张用户屏幕的截图：第一张是整个屏幕（已缩小，用来看全局上下文），第二张是用户指针附近的原分辨率放大图。两张图上都画了一个红色圆环标记，那是用户此刻指着的位置。用户的问题默认是针对标记处的内容提的；标记处看不出所指时，再结合整屏内容理解。不要描述标记本身，也不要提「截图」「图片」这些字眼，直接回答问题。
    先用一两句话把结论说完，需要展开再补两三点，全部加起来控制在 200 字以内。用户明确要求「详细」「展开说」时才可以更长。
    """

    /// 一条带两张图的 user message 的 content 数组（OpenAI 兼容格式）。
    /// 顺序是「整屏 → 放大 → 问题文字」：先给上下文再提问，模型更容易对上。
    /// 键名必须是 image_url，不是 imageUrl：GetNewWord 就因为这个键名写错，图片半年没真正发出去过。
    public static func visionUserContent(question: String,
                                         overviewJPEG: Data,
                                         closeUpJPEG: Data) -> [[String: Any]] {
        [
            imagePart(overviewJPEG),
            imagePart(closeUpJPEG),
            ["type": "text", "text": question],
        ]
    }

    static func imagePart(_ jpeg: Data) -> [String: Any] {
        ["type": "image_url",
         "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]]
    }

    /// 把「别思考」的参数按各家的写法塞进请求体。必须显式带：
    /// GetNewWord 实测默认思考 + 截图是 71 秒还被截断，关掉之后 30 秒。
    ///
    /// 智谱官方文档写 GLM-5.3 系列「强制思考不能关闭」，但 2026-09-21 在 Coding Plan 端点上用
    /// glm-5.3-flash 实测 thinking disabled 是生效的：纯文本 3.9 秒降到 1.1 秒、reasoning 0 字；
    /// 带图 1.8 秒、reasoning 12 字。所以智谱一律照发 disabled，以实测为准。
    public static func applyThinkingSettings(in body: inout [String: Any], provider: String, model: String) {
        switch provider {
        case "qwen":
            body["enable_thinking"] = false
        default:
            body["thinking"] = ["type": "disabled"]
        }
    }

    /// 文档声称关不掉思考的那一族（GLM-5.3 系列；GLM-5.2 / 5.1 / 5-Turbo / 4.7 在 Coding Plan 端点上
    /// 会被自动路由到 5.3）。实测能关，这里只用来给 max_tokens 多留一份余量：
    /// 万一哪天服务端真的不认 disabled 了，思考内容也不至于把回答挤到被截断。
    public static func forcesThinking(model: String) -> Bool {
        let name = model.lowercased()
        return name.hasPrefix("glm-5") || name.hasPrefix("glm-4.7")
    }

    /// 模型真的吐出思考内容时（关思考没生效），面板会先沉默一阵再出字，告诉用户在干什么
    public static let thinkingNotice = "模型在先想一下，马上出答案。"

    /// 日志用：两张图一共多少 KB（只记数字，绝不记图片内容或 base64）
    public static func sizeSummary(overviewJPEG: Data, closeUpJPEG: Data) -> String {
        "overview=\(overviewJPEG.count / 1024)KB closeup=\(closeUpJPEG.count / 1024)KB"
    }
}

/// DeepSeek 端点与默认模型。OpenAI 兼容，图片走 image_url + data URL（2026-09-21 实测可用）。
/// 思考必须显式关（"thinking": {"type": "disabled"}）：GetNewWord 因为默认思考慢到过 31 秒，
/// 带上之后本机实测 reasoning 为 0。官方当前的模型名是 deepseek-flash 和 deepseek-v4-pro，
/// 旧名 deepseek-v4-flash / deepseek-v4-flash-vision-exp 仍接受但已退役。
/// https://api-docs.deepseek.com/
public enum DeepSeekEndpoint {
    public static let configKey = "deepseek_base_url"
    public static let defaultBase = "https://api.deepseek.com"
    /// 润色、问 AI、带图问 AI 都用它：本机实测三家里最快的一档
    public static let defaultModel = "deepseek-flash"
    public static let secretKey = "deepseek_api_key"
    public static let envKey = "DEEPSEEK_API_KEY"
    public static let modelConfigKey = "deepseek_polish_model"
    public static let consoleURL = "https://platform.deepseek.com/api_keys"

    public static var base: String {
        let raw = VoicePolishConfig.shared.string(forKey: configKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (raw?.isEmpty == false) ? raw! : defaultBase
    }

    public static var chatCompletions: URL? {
        URL(string: base + "/chat/completions")
    }
}

/// 智谱端点与默认模型。用户的 Key 多是 Coding Plan 套餐，只能走 /api/coding/paas/v4：
/// 按量端点 /api/paas/v4 对 Coding Plan 的 Key 会报 429/1113「余额不足」，那不是没钱，是端点不对。
/// 按量付费的 Key 在配置里把 zhipu_base_url 改回 payAsYouGoBase。
public enum ZhipuEndpoint {
    public static let configKey = "zhipu_base_url"
    public static let codingPlanBase = "https://open.bigmodel.cn/api/coding/paas/v4"
    public static let payAsYouGoBase = "https://open.bigmodel.cn/api/paas/v4"
    /// 润色、问 AI、带图问 AI 都用它：Coding Plan 套餐里只有 GLM-5.3-Flash 支持图片输入，
    /// 纯文本的 GLM-5.3 不支持，所以干脆一家一个模型，不用在两个之间切来切去。
    public static let defaultModel = "glm-5.3-flash"

    public static var base: String {
        let raw = VoicePolishConfig.shared.string(forKey: configKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (raw?.isEmpty == false) ? raw! : codingPlanBase
    }

    public static var chatCompletions: URL? {
        URL(string: base + "/chat/completions")
    }
}

/// 连续追问和新话题的规则。
public enum AskThreading {
    /// 上一轮问答过去这么久，再提问就算新话题
    public static let staleAfter: TimeInterval = 10 * 60
    public static let newThreadPrefixes = ["新话题", "换个话题", "换一个话题", "重新开始", "新问题"]

    /// 问题以「新话题」之类开头：去掉这几个字和紧跟的标点，并告诉调用方另起话题
    public static func stripNewThreadPrefix(_ question: String) -> (question: String, newThread: Bool) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = newThreadPrefixes.first(where: { trimmed.hasPrefix($0) }) else { return (trimmed, false) }
        let rest = trimmed.dropFirst(prefix.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ，,。.：:、！!").union(.whitespacesAndNewlines))
        return (rest, true)
    }
}
