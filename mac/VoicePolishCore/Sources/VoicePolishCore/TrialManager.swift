import Foundation
import CryptoKit

/// 试用期管理：对接 /trial/start 端点，缓存试用状态，供 UX 路由判断。
///
/// - `refreshFromServer`：POST /trial/start，成功后写入 UserDefaults 缓存；
///   服务器明确返回 `{expired:true}` 则标记过期并清除 token。
/// - 网络失败时**保持现有缓存不动**（不因断网踢出试用）。
/// - `isInTrial`：本地缓存的快速判断，服务器才是权威。
/// - 设备指纹复用 `LicenseManager.shared.deviceID()`，与激活系统保持一致。
public final class TrialManager {
    public static let shared = TrialManager()

    /// 试用服务器地址与证书指纹不写在源码里：由 build.sh 在构建时从不进仓库的 `local.build.env`
    /// 注入 Info.plist（VPTrialAPIBase / VPTrialCertSHA256）。开源仓库里没有这两个值，
    /// 自己编译出来的版本就没有试用通道、只能自带 Key；官网下载的签名版照常有 7 天试用。
    /// （2026-09-14 Ray 拍板：试用地址不进公开仓库）
    static var configuredAPIBase: String? { infoPlistValue("VPTrialAPIBase") }
    static var configuredCertSHA256: String? { infoPlistValue("VPTrialCertSHA256") }

    private static func infoPlistValue(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 没注入时 Xcode 会把 $(VAR) 展开成空串；万一原样留下也当作没有
        return (v.isEmpty || v.hasPrefix("$(")) ? nil : v
    }

    private let defaults: UserDefaults
    private let session: URLSession
    /// nil = 这个构建没有试用通道（开源自编译版）
    private let apiBase: String?
    private var flushWorkItem: DispatchWorkItem?

    // UserDefaults 键（全部以 "trial." 为前缀）
    private let kToken        = "trial.token"
    private let kDaysLeft     = "trial.daysLeft"
    private let kUsedToday    = "trial.usedToday"
    private let kDailyLimit   = "trial.dailyLimit"
    private let kExpired      = "trial.expired"
    private let kLastRefresh  = "trial.lastRefreshAt"

    // 自带 key（付费/BYOK）用户活跃自报：识别/润色走自己通道、不经服务器，
    // 在 App Group 共享区累加「字数+次数」增量，握手(/trial/start)时上报、成功后扣减。仅数字、绝不含内容。
    private static let kSelfChars = "trial.selfUsage.chars"
    private static let kSelfReqs  = "trial.selfUsage.requests"
    private static var sharedSuite: UserDefaults? { UserDefaults(suiteName: ProcessingMode.appGroupSuiteName) }

    /// `apiBase` 可经 UserDefaults `trial.apiBase` 覆盖（本地联调用，指向 localhost）。
    /// 默认 `session` 为固定了服务器自签证书的会话（TrialPinningDelegate）；测试可注入普通 session。
    public init(defaults: UserDefaults = .standard,
                session: URLSession? = nil,
                apiBase: String? = nil) {
        self.defaults = defaults
        self.session = session ?? Self.makePinnedSession()
        self.apiBase = apiBase
            ?? defaults.string(forKey: "trial.apiBase")
            ?? Self.configuredAPIBase
    }

    /// 这个构建有没有试用通道。没有时 isInTrial 恒为 false、refreshFromServer 直接返回，不发任何网络请求。
    public var isTrialAvailable: Bool { apiBase != nil }

    /// 固定自签证书的会话：试用代理走 IP + 自签证书，普通会话会拒，需在 delegate 里校验证书指纹后放行。
    private static func makePinnedSession() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: TrialPinningDelegate.shared, delegateQueue: nil)
    }

    // MARK: - 状态查询（从缓存读，不联网）

    /// 上次刷新时服务器返回的试用 token。
    public var trialToken: String? {
        let v = defaults.string(forKey: kToken)
        return (v?.isEmpty == false) ? v : nil
    }

    /// 剩余试用天数（来自上次服务器响应的缓存）。
    public var daysLeft: Int { defaults.integer(forKey: kDaysLeft) }

    /// 今日已用次数（来自上次服务器响应的缓存）。
    public var usedToday: Int { defaults.integer(forKey: kUsedToday) }

    /// 每日上限（缺省 1500，来自服务器）。
    public var dailyLimit: Int {
        let v = defaults.integer(forKey: kDailyLimit)
        return v > 0 ? v : 1500
    }

    /// 处于可用试用期：有非空 token 且未被标记为过期。
    /// 服务器才是权威，此标志仅供客户端 UX / 路由快速判断。
    public var isInTrial: Bool {
        guard isTrialAvailable, let token = trialToken, !token.isEmpty else { return false }
        return !defaults.bool(forKey: kExpired)
    }

    /// 试用已结束（服务器明确返回过期）。区别于"试用还没拉到"。
    public var trialExpired: Bool { defaults.bool(forKey: kExpired) }

    // MARK: - 刷新（联网）

    /// 向服务器拉取 / 刷新试用状态（POST /trial/start）。
    ///
    /// - 成功 → 缓存 token / daysLeft / usedToday / dailyLimit / lastRefreshAt，清除 expired 标记。
    /// - `{expired:true}` → 设置 expired=true，清除 token。
    /// - 网络失败 → 保持现有缓存，沉默返回 `completion(false)`。
    public func refreshFromServer(completion: ((Bool) -> Void)? = nil) {
        guard isTrialAvailable else {
            DispatchQueue.main.async { completion?(false) }
            return
        }
        let deviceID = LicenseManager.shared.deviceID()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        // 携带自带 key 自报用量增量（没有就 0；服务器只对 >0 记账，且绝不进熔断预算）。
        let suite = Self.sharedSuite
        let selfChars = suite?.integer(forKey: Self.kSelfChars) ?? 0
        let selfReqs  = suite?.integer(forKey: Self.kSelfReqs) ?? 0
        let body: [String: Any] = ["device_id": deviceID,
                    "app_version": appVersion,
                    "os_version": "\(os.majorVersion).\(os.minorVersion)",
                    "usage": ["chars": selfChars, "requests": selfReqs]]
        post(path: "/trial/start", body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                // 网络失败：保持缓存，不踢出试用；自报增量也保留，等下次再报。
                DispatchQueue.main.async { completion?(false) }
            case .success(let json):
                // 上报成功 → 扣掉已报的增量（扣减而非清零，避免吞掉这期间新增的用量）。
                if (selfChars > 0 || selfReqs > 0), let s = Self.sharedSuite {
                    s.set(max(0, s.integer(forKey: Self.kSelfChars) - selfChars), forKey: Self.kSelfChars)
                    s.set(max(0, s.integer(forKey: Self.kSelfReqs) - selfReqs), forKey: Self.kSelfReqs)
                }
                let parsed = Self.parseTrialStart(json)
                self.applyParsed(parsed)
                DispatchQueue.main.async { completion?(parsed.token != nil || parsed.expired) }
            }
        }
    }

    /// 记一次「自带 key」识别/润色产出（chars 字）。累加到共享区，并安排一次延迟握手上报。
    /// 代理通道的用量由服务器直接记账，不走这里（避免重复计数）。
    public func recordSelfKeyUsage(chars: Int) {
        guard chars > 0, let s = Self.sharedSuite else { return }
        s.set(s.integer(forKey: Self.kSelfChars) + chars, forKey: Self.kSelfChars)
        s.set(s.integer(forKey: Self.kSelfReqs) + 1, forKey: Self.kSelfReqs)
        scheduleUsageFlush()
    }

    /// 去抖延迟上报：把一连串识别（含同一句的识别+润色）合并成一次握手上报，让后台「今日」及时又不刷屏。
    private func scheduleUsageFlush() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.flushWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refreshFromServer() }
            self.flushWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }

    // MARK: - 纯函数：解析 /trial/start 响应（便于单测，不依赖网络）

    /// /trial/start 响应解析结果。
    public struct ParsedTrial {
        public let token: String?
        public let daysLeft: Int
        public let dailyLimit: Int
        public let usedToday: Int
        public let expired: Bool
    }

    /// 解析 /trial/start 返回的 JSON 字典。
    ///
    /// - `{expired:true}` → `ParsedTrial(token:nil, ..., expired:true)`
    /// - 正常 → 映射 4 个字段（`daily_limit` 缺失时默认 1500）；`expired:false`
    /// - 缺少 token 且不是 expired → `token:nil, expired:false`（视为"无法启动"）
    public static func parseTrialStart(_ json: [String: Any]) -> ParsedTrial {
        // 服务器明确告知过期
        if let exp = json["expired"] as? Bool, exp {
            return ParsedTrial(token: nil, daysLeft: 0, dailyLimit: 1500, usedToday: 0, expired: true)
        }
        // 正常成功响应
        let token      = json["trial_token"] as? String
        let daysLeft   = json["days_left"]   as? Int ?? 0
        let dailyLimit = json["daily_limit"] as? Int ?? 1500
        let usedToday  = json["used_today"]  as? Int ?? 0
        return ParsedTrial(
            token:      (token?.isEmpty == false) ? token : nil,
            daysLeft:   daysLeft,
            dailyLimit: dailyLimit,
            usedToday:  usedToday,
            expired:    false
        )
    }

    // MARK: - 内部

    private func applyParsed(_ p: ParsedTrial) {
        if p.expired {
            defaults.removeObject(forKey: kToken)
            defaults.set(true, forKey: kExpired)
        } else {
            defaults.set(p.token ?? "", forKey: kToken)
            defaults.set(p.daysLeft,   forKey: kDaysLeft)
            defaults.set(p.usedToday,  forKey: kUsedToday)
            defaults.set(p.dailyLimit, forKey: kDailyLimit)
            defaults.set(false,        forKey: kExpired)
        }
        defaults.set(Date().timeIntervalSince1970, forKey: kLastRefresh)
    }

    // MARK: - 试用鉴权 POST（供识别/润色代理调用）

    /// 带试用 token 的 POST。401(bad_trial_token，token 24h 过期)时自动 refreshFromServer 后重试一次。
    /// 回调给出原始 (Data?, HTTPURLResponse?, Error?)，由调用方解析（识别/润色各自的响应格式不同）。
    public func trialPost(path: String, jsonBody: [String: Any], completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        sendTrialPost(path: path, jsonBody: jsonBody, attempt: 1, completion: completion)
    }

    /// trialPost 的内部实现：attempt 用于限制 401 刷新重试只发生一次。
    private func sendTrialPost(path: String, jsonBody: [String: Any], attempt: Int,
                              completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        guard let base = apiBase, let url = URL(string: base + path) else {
            completion(nil, nil, URLError(.badURL))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(trialToken ?? "", forHTTPHeaderField: "X-Trial-Token")
        req.timeoutInterval = 30   // 识别上传可能有几 MB，放宽超时
        req.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)

        // TrialManager 是共享单例，self 不会被释放，强持有 self 安全。
        session.dataTask(with: req) { data, response, error in
            let http = response as? HTTPURLResponse
            // 401 且 token 过期 → 刷新一次后重试（仅第一次）
            if attempt == 1, http?.statusCode == 401,
               let data = data,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               (json["code"] as? String) == "bad_trial_token" {
                self.refreshFromServer { _ in
                    self.sendTrialPost(path: path, jsonBody: jsonBody, attempt: 2, completion: completion)
                }
                return
            }
            completion(data, http, error)
        }.resume()
    }

    /// 会员托管通道 POST（/member/*，X-Member-Token）。401 bad_member_token（令牌过期或已换新）时
    /// 找激活服务换新令牌后重试一次。
    public func memberPost(path: String, jsonBody: [String: Any], timeout: TimeInterval = 60,
                           completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        sendMemberPost(path: path, jsonBody: jsonBody, timeout: timeout, attempt: 1, completion: completion)
    }

    private func sendMemberPost(path: String, jsonBody: [String: Any], timeout: TimeInterval, attempt: Int,
                                completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        guard let base = apiBase, let url = URL(string: base + path) else {
            completion(nil, nil, URLError(.badURL))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(LicenseManager.shared.memberToken() ?? "", forHTTPHeaderField: "X-Member-Token")
        req.timeoutInterval = timeout
        req.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)

        session.dataTask(with: req) { data, response, error in
            let http = response as? HTTPURLResponse
            if attempt == 1, http?.statusCode == 401,
               let data = data,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               (json["code"] as? String) == "bad_member_token" {
                LicenseManager.shared.revalidateNow { ok in
                    guard ok else { completion(data, http, error); return }
                    self.sendMemberPost(path: path, jsonBody: jsonBody, timeout: timeout, attempt: 2, completion: completion)
                }
                return
            }
            completion(data, http, error)
        }.resume()
    }

    /// 按通道发 POST：endpoint 传不带前缀的端点名（"asr" / "polish"）。
    /// timeout 只对会员生效（会员识别走 2.0 异步接口，长录音要多等）；试用沿用 trialPost 的固定超时。
    public func hostedPost(route: HostedRoute, endpoint: String, jsonBody: [String: Any], timeout: TimeInterval = 60,
                           completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        switch route {
        case .member: memberPost(path: "/member/\(endpoint)", jsonBody: jsonBody, timeout: timeout, completion: completion)
        case .trial:  trialPost(path: "/trial/\(endpoint)", jsonBody: jsonBody, completion: completion)
        case .none:   completion(nil, nil, URLError(.userAuthenticationRequired))
        }
    }

    private func post(path: String,
                      body: [String: Any],
                      completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let base = apiBase, let url = URL(string: base + path) else {
            completion(.failure(URLError(.badURL)))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            completion(.success(json))
        }.resume()
    }
}

/// 固定服务器自签证书：试用代理走「IP + 自签证书」（不挂域名/不备案），普通 TLS 校验会拒。
/// 这里只对试用服务器那台 IP 做证书指纹比对，匹配才信任——既能用自签证书，又能防中间人。
/// 证书 10 年有效，只有轮换证书才需要更新 `pinnedCertSHA256`。
final class TrialPinningDelegate: NSObject, URLSessionDelegate {
    static let shared = TrialPinningDelegate()

    /// 服务器证书 DER 的 SHA-256（base64，来自 `openssl x509 -outform der | openssl dgst -sha256 -binary | base64`）
    /// 与服务器主机名一样由构建时注入（见 TrialManager.configuredAPIBase）；没注入就谁也不信任。
    private static let pinnedCertSHA256: String? = TrialManager.configuredCertSHA256
    private static let pinnedHost: String? = TrialManager.configuredAPIBase.flatMap { URL(string: $0)?.host }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        // 只接管试用服务器那台 IP 的服务器信任校验；其余一律走系统默认。
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let host = Self.pinnedHost, space.host == host,
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = Data(SHA256.hash(data: der)).base64EncodedString()
        if let pinned = Self.pinnedCertSHA256, fingerprint == pinned {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
