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
    /// 智谱 GLM-5.3 系列强制思考、关不掉（官方文档原话「强制思考不能关闭」），思考内容也算在
    /// max_tokens 里，给 600 会在思考阶段就被截断（GetNewWord 吃过这个亏），所以单独放宽。
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
    public static func visionCandidates(provider: String, override: String? = nil) -> [String] {
        if let override, !override.isEmpty { return [override] }
        switch provider {
        case "qwen": return ["qwen3.8-flash", "qwen3.7-flash", "qwen3-vl-plus", "qwen3.8-max"]
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
        case "qwen": return URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        case "zhipu": return ZhipuEndpoint.chatCompletions
        default: return URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")
        }
    }

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

    /// 把「别思考那么久」的参数按各家的写法塞进请求体。必须显式带：
    /// GetNewWord 实测默认思考 + 截图是 71 秒还被截断，处理之后 30 秒。
    ///
    /// 智谱 GLM-5.3 系列是特例：官方文档写明强制思考、thinking.type 只接受 enabled，
    /// 关不掉，能调的只有 reasoning_effort（low / high / max，默认 max）。所以这一族改成压强度，
    /// 不去发一个官方说不支持的值。其余智谱模型照旧 thinking disabled。
    /// https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode
    public static func applyThinkingSettings(in body: inout [String: Any], provider: String, model: String) {
        switch provider {
        case "qwen":
            body["enable_thinking"] = false
        case "zhipu":
            if forcesThinking(model: model) {
                body["reasoning_effort"] = "low"
            } else {
                body["thinking"] = ["type": "disabled"]
            }
        default:
            body["thinking"] = ["type": "disabled"]
        }
    }

    /// 智谱 GLM-5.3 系列（含 flash / flashx）强制思考。GLM-5.2 / 5.1 / 5-Turbo / 4.7 在
    /// Coding Plan 端点上会被自动路由到 5.3 系列，所以那些名字也按强制思考处理。
    public static func forcesThinking(model: String) -> Bool {
        let name = model.lowercased()
        return name.hasPrefix("glm-5") || name.hasPrefix("glm-4.7")
    }

    /// 思考关不掉的模型上，面板会先沉默一阵再出字，提前告诉用户在干什么
    public static let thinkingNotice = "模型在先想一下，马上出答案。"

    /// 日志用：两张图一共多少 KB（只记数字，绝不记图片内容或 base64）
    public static func sizeSummary(overviewJPEG: Data, closeUpJPEG: Data) -> String {
        "overview=\(overviewJPEG.count / 1024)KB closeup=\(closeUpJPEG.count / 1024)KB"
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
