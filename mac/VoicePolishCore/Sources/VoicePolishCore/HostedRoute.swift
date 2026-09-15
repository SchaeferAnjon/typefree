import Foundation

/// 识别 / 润色 / 问 AI 走哪条通道。
/// 优先级：有效会员且「优先走会员」> 自己的 Key > 有效会员 > 7 天试用。
/// 「优先走会员」由用户在模型页决定（memberFirst）：新开的会员默认走会员（他们要的就是免配置）；
/// 创世用户（老买断赠的一年会员）默认继续用自己的 Key——有人就是为了隐私才自己配 Key 的，不能替他改。
/// 已激活的老码（老买断/赠送码）不走试用；自己编译的开源版没有托管服务器地址（hostedAvailable=false）→ 一律 none。
public enum HostedRoute: Equatable {
    case member   // 年付会员：/member/*（X-Member-Token）
    case trial    // 免费试用：/trial/*（X-Trial-Token）
    case none     // 没有托管通道

    /// 会员期间是否优先走会员服务（忽略已填的 Key）。config 里没写时按创世与否取默认。
    public static let memberFirstConfigKey = "member_channel_first"
    public static var memberFirst: Bool {
        VoicePolishConfig.shared.bool(forKey: memberFirstConfigKey, defaultValue: !LicenseManager.shared.isGenesis)
    }

    /// 纯函数，便于测试。
    public static func decide(ownKeyConfigured: Bool, hostedAvailable: Bool, isActivated: Bool,
                              hasActiveMembership: Bool, isInTrial: Bool, memberFirst: Bool = false) -> HostedRoute {
        if !hostedAvailable { return .none }
        if hasActiveMembership && (memberFirst || !ownKeyConfigured) { return .member }
        if ownKeyConfigured { return .none }
        if !isActivated && isInTrial { return .trial }
        return .none
    }

    /// 按当前全局状态判定。
    public static func current(ownKeyConfigured: Bool) -> HostedRoute {
        decide(ownKeyConfigured: ownKeyConfigured,
               hostedAvailable: TrialManager.shared.isTrialAvailable,
               isActivated: LicenseManager.shared.isActivated,
               hasActiveMembership: LicenseManager.shared.hasActiveMembership(),
               isInTrial: TrialManager.shared.isInTrial,
               memberFirst: memberFirst)
    }
}
