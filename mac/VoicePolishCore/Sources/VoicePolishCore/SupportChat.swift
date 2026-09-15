import Foundation

/// 反馈对话（设置窗侧栏「反馈」页）：用户不登录，凭设备标识 + 服务器首次发的随机凭证认人。
/// 消息在本机存一份（`support.json`），打开页面或定时去服务器拉新回复；未读数给侧栏画角标。
/// 服务器只收 App 自己转码过的 JPEG/PNG 截图和 m4a 录音，这里只负责打包、发送、缓存。
public struct SupportMessage: Codable, Equatable {
    public enum Role: String, Codable { case user, admin }
    public var id: Int
    public var role: Role
    public var text: String
    public var hasImage: Bool
    public var hasAudio: Bool
    public var createdAt: String          // ISO8601 / "YYYY-MM-DD HH:MM:SS"（UTC）
    public var localImageFile: String?    // 自己发的截图在本机的缓存文件名（服务器不回传图）

    public init(id: Int, role: Role, text: String, hasImage: Bool = false, hasAudio: Bool = false,
                createdAt: String, localImageFile: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.hasImage = hasImage; self.hasAudio = hasAudio
        self.createdAt = createdAt; self.localImageFile = localImageFile
    }
}

public enum SupportChatError: Error, Equatable {
    case empty
    case tooLarge
    case blocked
    case network(String)

    public var userMessage: String {
        switch self {
        case .empty: return "写点内容或附上截图再发"
        case .tooLarge: return "附件太大了"
        case .blocked: return "这台设备已被停用反馈"
        case .network(let s): return "发送失败：\(s)"
        }
    }
}

public final class SupportChatService {
    public static let shared = SupportChatService()

    /// 消息有变化（发出、收到回复、未读数变）时发，主线程
    public static let didChangeNotification = Notification.Name("SupportChatDidChange")

    public static let maxImageBytes = 1_500_000
    public static let maxAudioBytes = 1_900_000
    public static let maxTextChars = 4000
    public static let maxLogChars = 12_000
    /// 拉新回复的最短间隔：后台定时器用
    public static let pollInterval: TimeInterval = 5 * 60

    private let defaults: UserDefaults
    private let session: URLSession
    private let storeDir: URL
    private let apiBaseOverride: String?
    private let kSecret = "support.secret"
    private let kLastSeen = "support.lastSeenId"
    private let queue = DispatchQueue(label: "support.chat.store")

    public private(set) var messages: [SupportMessage] = []
    private var syncing = false

    public init(defaults: UserDefaults = .standard,
                storeDir: URL? = nil,
                apiBase: String? = nil,
                session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        self.apiBaseOverride = apiBase
        self.storeDir = storeDir ?? VoicePolishConfig.shared.configDirectoryURL.appendingPathComponent("support", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.storeDir, withIntermediateDirectories: true)
        messages = loadMessages()
    }

    // MARK: - 状态

    /// 有没有开始过对话（服务器发过凭证）
    public var hasThread: Bool { (defaults.string(forKey: kSecret) ?? "").isEmpty == false }

    /// owner 回复里还没看过的条数（侧栏角标）
    public var unreadCount: Int {
        let seen = defaults.integer(forKey: kLastSeen)
        return messages.filter { $0.role == .admin && $0.id > seen }.count
    }

    /// 用户打开反馈页：把当前所有回复记为已看
    public func markAllSeen() {
        let maxId = messages.map(\.id).max() ?? 0
        guard maxId > defaults.integer(forKey: kLastSeen) else { return }
        defaults.set(maxId, forKey: kLastSeen)
        notify()
    }

    public func imageURL(for message: SupportMessage) -> URL? {
        guard let f = message.localImageFile else { return nil }
        let url = storeDir.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 发送

    public struct Outgoing {
        public var text: String
        public var imageJPEG: Data?        // App 已转码过的 JPEG（去掉了原文件的一切附加内容）
        public var audioM4A: Data?
        public var asrText: String?
        public var polishedText: String?
        public var recentApp: String?
        public var log: String?
        public var deviceName: String
        public var appVersion: String

        public init(text: String, imageJPEG: Data? = nil, audioM4A: Data? = nil,
                    asrText: String? = nil, polishedText: String? = nil,
                    recentApp: String? = nil, log: String? = nil,
                    deviceName: String, appVersion: String) {
            self.text = text; self.imageJPEG = imageJPEG; self.audioM4A = audioM4A
            self.asrText = asrText; self.polishedText = polishedText
            self.recentApp = recentApp; self.log = log
            self.deviceName = deviceName; self.appVersion = appVersion
        }
    }

    /// 纯函数：拼请求体。空内容返回 nil；超大附件直接丢掉（服务器也会拒）。
    public static func makePayload(_ out: Outgoing, deviceID: String, secret: String?, osVersion: String) -> [String: Any]? {
        let text = String(out.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTextChars))
        let image = out.imageJPEG.flatMap { $0.count <= maxImageBytes ? $0 : nil }
        let audio = out.audioM4A.flatMap { $0.count <= maxAudioBytes ? $0 : nil }
        guard !text.isEmpty || image != nil || audio != nil else { return nil }
        var p: [String: Any] = [
            "device_id": deviceID,
            "text": text,
            "app_version": out.appVersion,
            "os_version": osVersion,
            "device_name": out.deviceName,
        ]
        if let secret, !secret.isEmpty { p["secret"] = secret }
        if let image { p["image_b64"] = image.base64EncodedString() }
        if let audio { p["audio_b64"] = audio.base64EncodedString() }
        if let a = out.asrText, !a.isEmpty { p["asr_text"] = String(a.prefix(10_000)) }
        if let o = out.polishedText, !o.isEmpty { p["polished_text"] = String(o.prefix(10_000)) }
        if let r = out.recentApp, !r.isEmpty { p["recent_app"] = String(r.prefix(128)) }
        if let l = out.log, !l.isEmpty { p["log"] = String(l.suffix(maxLogChars)) }
        return p
    }

    public func send(_ out: Outgoing, completion: @escaping (Result<SupportMessage, SupportChatError>) -> Void) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let deviceID = LicenseManager.shared.deviceID()
        guard let payload = Self.makePayload(out, deviceID: deviceID, secret: defaults.string(forKey: kSecret),
                                             osVersion: "\(os.majorVersion).\(os.minorVersion)") else {
            DispatchQueue.main.async { completion(.failure(.empty)) }
            return
        }
        guard let url = URL(string: apiBase + "/support/send") else {
            DispatchQueue.main.async { completion(.failure(.network("地址错误"))) }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = (payload["image_b64"] != nil || payload["audio_b64"] != nil) ? 90 : 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { completion(.failure(.network(error.localizedDescription))) }
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard code == 200, let json, let id = json["id"] as? Int else {
                let err: SupportChatError
                switch json?["code"] as? String {
                case "blocked": err = .blocked
                case "body_too_large", "bad_image": err = .tooLarge
                case "daily_cap": err = .network("今天发得够多了，明天再来")
                case "rate_limited": err = .network("发得太快了，稍等一下")
                default: err = .network(code == 0 ? "网络不通" : "服务器返回 \(code)")
                }
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }
            if let secret = json["secret"] as? String, !secret.isEmpty {
                self.defaults.set(secret, forKey: self.kSecret)
            }
            var localFile: String?
            if let image = out.imageJPEG {
                localFile = "img-\(id).jpg"
                try? image.write(to: self.storeDir.appendingPathComponent(localFile!), options: .atomic)
            }
            let msg = SupportMessage(id: id, role: .user, text: payload["text"] as? String ?? "",
                                     hasImage: out.imageJPEG != nil, hasAudio: out.audioM4A != nil,
                                     createdAt: json["created_at"] as? String ?? ISO8601DateFormatter().string(from: Date()),
                                     localImageFile: localFile)
            DispatchQueue.main.async {
                self.append([msg])
                completion(.success(msg))
            }
        }.resume()
    }

    // MARK: - 拉新回复

    /// 去服务器拿 id 比本地最大值更新的消息（两边的都拿，别的设备上自己发的也会同步过来）。没开始过对话直接返回。
    public func sync(completion: ((Bool) -> Void)? = nil) {
        guard hasThread, !syncing, let secret = defaults.string(forKey: kSecret),
              let url = URL(string: apiBase + "/support/sync") else {
            DispatchQueue.main.async { completion?(false) }
            return
        }
        syncing = true
        let after = messages.map(\.id).max() ?? 0
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_id": LicenseManager.shared.deviceID(), "secret": secret, "after_id": after,
        ])
        session.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let list = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["messages"] as? [[String: Any]]
            let incoming: [SupportMessage] = (code == 200 ? list ?? [] : []).compactMap { m in
                guard let id = m["id"] as? Int, let roleRaw = m["role"] as? String,
                      let role = SupportMessage.Role(rawValue: roleRaw) else { return nil }
                return SupportMessage(id: id, role: role, text: m["text"] as? String ?? "",
                                      hasImage: m["has_image"] as? Bool ?? false,
                                      hasAudio: m["has_audio"] as? Bool ?? false,
                                      createdAt: m["created_at"] as? String ?? "")
            }
            DispatchQueue.main.async {
                self.syncing = false
                if !incoming.isEmpty { self.append(incoming) }
                completion?(code == 200)
            }
        }.resume()
    }

    // MARK: - 本机缓存

    private var apiBase: String {
        apiBaseOverride ?? defaults.string(forKey: "license.apiBase") ?? FeedbackService.defaultAPIBase
    }

    private var storeURL: URL { storeDir.appendingPathComponent("support.json") }

    private func loadMessages() -> [SupportMessage] {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([SupportMessage].self, from: data) else { return [] }
        return list.sorted { $0.id < $1.id }
    }

    private func append(_ new: [SupportMessage]) {
        var byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for m in new { byId[m.id] = m }
        messages = byId.values.sorted { $0.id < $1.id }
        let snapshot = messages
        let url = storeURL
        queue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
