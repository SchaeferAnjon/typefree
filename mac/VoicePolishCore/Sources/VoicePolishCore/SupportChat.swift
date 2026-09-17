import Foundation

/// 反馈工单（设置窗侧栏「反馈」页）：用户不登录，凭设备标识 + 服务器首次发的随机凭证认人。
/// 2026-09-17 起按工单组织：一台设备可以有多个工单，每个工单一段对话；开发者在后台结束后只能看、不能再回。
/// 工单和消息在本机各存一份（`support-tickets.json` / `support.json`），打开页面或定时去服务器拉；未读按工单算，侧栏角标是总数。
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
    public var ticketId: Int?             // 工单上线前缓存的老消息没有，下次同步补上

    public init(id: Int, role: Role, text: String, hasImage: Bool = false, hasAudio: Bool = false,
                createdAt: String, localImageFile: String? = nil, ticketId: Int? = nil) {
        self.id = id; self.role = role; self.text = text; self.hasImage = hasImage; self.hasAudio = hasAudio
        self.createdAt = createdAt; self.localImageFile = localImageFile; self.ticketId = ticketId
    }
}

public struct SupportTicket: Codable, Equatable {
    public enum Status: String, Codable { case open, closed }
    public enum Category: String, Codable, CaseIterable {
        case issue, idea, other
        public var label: String {
            switch self {
            case .issue: return "使用问题"
            case .idea: return "功能建议"
            case .other: return "其他"
            }
        }
    }

    public var id: Int
    public var no: Int                    // 给人看的编号（服务器给，#1001 起）
    public var category: Category
    public var title: String
    public var status: Status
    public var createdAt: String
    public var closedAt: String?

    public init(id: Int, no: Int, category: Category, title: String, status: Status, createdAt: String, closedAt: String? = nil) {
        self.id = id; self.no = no; self.category = category; self.title = title
        self.status = status; self.createdAt = createdAt; self.closedAt = closedAt
    }

    /// 服务器 JSON → 工单；未知的类型/状态按「其他」「处理中」兜底，缺关键字段返回 nil
    public init?(json t: [String: Any]) {
        guard let id = t["id"] as? Int else { return nil }
        self.id = id
        no = t["no"] as? Int ?? id + 1000
        category = Category(rawValue: t["category"] as? String ?? "") ?? .other
        title = t["title"] as? String ?? ""
        status = Status(rawValue: t["status"] as? String ?? "") ?? .open
        createdAt = t["created_at"] as? String ?? ""
        closedAt = t["closed_at"] as? String
    }
}

public enum SupportChatError: Error, Equatable {
    case empty
    case tooLarge
    case blocked
    case ticketClosed
    case network(String)

    public var userMessage: String {
        switch self {
        case .empty: return "写点内容或附上截图再发"
        case .tooLarge: return "附件太大了"
        case .blocked: return "这台设备已被停用反馈"
        case .ticketClosed: return "这个工单已结束，有新问题请提交新工单"
        case .network(let s): return "发送失败：\(s)"
        }
    }
}

public final class SupportChatService {
    public static let shared = SupportChatService()

    /// 工单或消息有变化（发出、收到回复、状态变、未读数变）时发，主线程
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
    private let kLastSeen = "support.lastSeenId"          // 工单上线前的「全部已读到哪条」，作为各工单已读的下限
    private let kSeenByTicket = "support.seenByTicket"    // [工单 id: 已读到的消息 id]
    private let queue = DispatchQueue(label: "support.chat.store")

    public private(set) var messages: [SupportMessage] = []
    public private(set) var tickets: [SupportTicket] = []
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
        tickets = loadTickets()
    }

    // MARK: - 状态

    /// 有没有开始过对话（服务器发过凭证）
    public var hasThread: Bool { (defaults.string(forKey: kSecret) ?? "").isEmpty == false }

    /// 列表顺序：处理中的在前，同状态里新的在前
    public var sortedTickets: [SupportTicket] {
        tickets.sorted { a, b in
            if a.status != b.status { return a.status == .open }
            return a.id > b.id
        }
    }

    public func ticket(id: Int) -> SupportTicket? { tickets.first { $0.id == id } }

    public func messages(inTicket id: Int) -> [SupportMessage] {
        messages.filter { $0.ticketId == id }
    }

    /// 某个工单里开发者的回复还没看过的条数
    public func unreadCount(ticket id: Int) -> Int {
        let seen = max(defaults.integer(forKey: kLastSeen), seenByTicket[String(id)] ?? 0)
        return messages.filter { $0.ticketId == id && $0.role == .admin && $0.id > seen }.count
    }

    /// 侧栏角标：所有工单未读之和（还没同步到工单归属的老消息按老规则算）
    public var unreadCount: Int {
        let floor = defaults.integer(forKey: kLastSeen)
        let orphan = messages.filter { $0.ticketId == nil && $0.role == .admin && $0.id > floor }.count
        return orphan + tickets.reduce(0) { $0 + unreadCount(ticket: $1.id) }
    }

    /// 打开某个工单：把它里面的回复记为已看
    public func markTicketSeen(_ id: Int) {
        guard let maxId = messages(inTicket: id).map(\.id).max(), maxId > (seenByTicket[String(id)] ?? 0) else { return }
        var map = seenByTicket
        map[String(id)] = maxId
        defaults.set(map, forKey: kSeenByTicket)
        notify()
    }

    /// 全部记为已看（老接口，测试和兜底用）
    public func markAllSeen() {
        let maxId = messages.map(\.id).max() ?? 0
        guard maxId > defaults.integer(forKey: kLastSeen) else { return }
        defaults.set(maxId, forKey: kLastSeen)
        notify()
    }

    private var seenByTicket: [String: Int] {
        defaults.dictionary(forKey: kSeenByTicket) as? [String: Int] ?? [:]
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
    /// ticketId：发进哪个工单；category：开新工单时的类型（两者不会同时给）。
    public static func makePayload(_ out: Outgoing, deviceID: String, secret: String?, osVersion: String,
                                   ticketId: Int? = nil, category: SupportTicket.Category? = nil) -> [String: Any]? {
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
        if let ticketId { p["ticket_id"] = ticketId }
        if let category { p["category"] = category.rawValue }
        if let image { p["image_b64"] = image.base64EncodedString() }
        if let audio { p["audio_b64"] = audio.base64EncodedString() }
        if let a = out.asrText, !a.isEmpty { p["asr_text"] = String(a.prefix(10_000)) }
        if let o = out.polishedText, !o.isEmpty { p["polished_text"] = String(o.prefix(10_000)) }
        if let r = out.recentApp, !r.isEmpty { p["recent_app"] = String(r.prefix(128)) }
        if let l = out.log, !l.isEmpty { p["log"] = String(l.suffix(maxLogChars)) }
        return p
    }

    /// 开新工单：out.text 是问题描述（必填）。新设备的第一张工单服务器不收附件（attachmentsDropped=true），调用方再补发一条。
    public func createTicket(category: SupportTicket.Category, _ out: Outgoing,
                             completion: @escaping (Result<(ticket: SupportTicket, attachmentsDropped: Bool), SupportChatError>) -> Void) {
        guard !out.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DispatchQueue.main.async { completion(.failure(.network("先描述一下遇到的问题"))) }
            return
        }
        post(path: "/support/tickets/create", out: out, ticketId: nil, category: category) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let (json, msg)):
                guard let t = (json["ticket"] as? [String: Any]).flatMap(SupportTicket.init(json:)) else {
                    completion(.failure(.network("服务器返回格式不对")))
                    return
                }
                self.upsertTickets([t])
                self.append([msg])
                completion(.success((t, json["attachments_dropped"] as? Bool ?? false)))
            }
        }
    }

    /// 往某个处理中的工单里发消息
    public func send(_ out: Outgoing, ticketId: Int, completion: @escaping (Result<SupportMessage, SupportChatError>) -> Void) {
        post(path: "/support/send", out: out, ticketId: ticketId, category: nil) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                if e == .ticketClosed { self.sync() }   // 工单在别处被结束了：拉一下，让页面变成只读
                completion(.failure(e))
            case .success(let (_, msg)):
                self.append([msg])
                completion(.success(msg))
            }
        }
    }

    private func post(path: String, out: Outgoing, ticketId: Int?, category: SupportTicket.Category?,
                      completion: @escaping (Result<([String: Any], SupportMessage), SupportChatError>) -> Void) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let deviceID = LicenseManager.shared.deviceID()
        guard let payload = Self.makePayload(out, deviceID: deviceID, secret: defaults.string(forKey: kSecret),
                                             osVersion: "\(os.majorVersion).\(os.minorVersion)",
                                             ticketId: ticketId, category: category) else {
            DispatchQueue.main.async { completion(.failure(.empty)) }
            return
        }
        guard let url = URL(string: apiBase + path) else {
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
                DispatchQueue.main.async { completion(.failure(Self.classify(code: code, json: json))) }
                return
            }
            if let secret = json["secret"] as? String, !secret.isEmpty {
                self.defaults.set(secret, forKey: self.kSecret)
            }
            let dropped = json["attachments_dropped"] as? Bool ?? false
            var localFile: String?
            if let image = out.imageJPEG, !dropped {
                localFile = "img-\(id).jpg"
                try? image.write(to: self.storeDir.appendingPathComponent(localFile!), options: .atomic)
            }
            let msg = SupportMessage(id: id, role: .user, text: payload["text"] as? String ?? "",
                                     hasImage: out.imageJPEG != nil && !dropped, hasAudio: out.audioM4A != nil && !dropped,
                                     createdAt: json["created_at"] as? String ?? ISO8601DateFormatter().string(from: Date()),
                                     localImageFile: localFile,
                                     ticketId: json["ticket_id"] as? Int ?? ticketId)
            DispatchQueue.main.async { completion(.success((json, msg))) }
        }.resume()
    }

    /// 纯函数：服务器错误 → 给用户看的错误。服务器的中文提示优先。
    public static func classify(code: Int, json: [String: Any]?) -> SupportChatError {
        switch json?["code"] as? String {
        case "blocked": return .blocked
        case "body_too_large", "bad_image": return .tooLarge
        case "ticket_closed": return .ticketClosed
        default:
            if let msg = json?["error"] as? String, !msg.isEmpty, code >= 400, code < 500 { return .network(msg) }
            return .network(code == 0 ? "网络不通" : "服务器返回 \(code)")
        }
    }

    // MARK: - 拉新回复

    /// 去服务器拿新消息和全部工单（状态随时会变）。没开始过对话直接返回。
    /// 本机还有没归属工单的老消息（工单上线前缓存的）时，从头拉一遍把归属补上。
    public func sync(completion: ((Bool) -> Void)? = nil) {
        guard hasThread, !syncing, let secret = defaults.string(forKey: kSecret),
              let url = URL(string: apiBase + "/support/sync") else {
            DispatchQueue.main.async { completion?(false) }
            return
        }
        syncing = true
        let after = messages.contains { $0.ticketId == nil } ? 0 : (messages.map(\.id).max() ?? 0)
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
            let root = code == 200 ? data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
            let incoming = (root?["messages"] as? [[String: Any]] ?? []).compactMap(Self.parseMessage)
            let ticketList = (root?["tickets"] as? [[String: Any]])?.compactMap(SupportTicket.init(json:))
            DispatchQueue.main.async {
                self.syncing = false
                if let ticketList { self.replaceTickets(ticketList) }
                if !incoming.isEmpty { self.append(incoming) }
                completion?(code == 200)
            }
        }.resume()
    }

    static func parseMessage(_ m: [String: Any]) -> SupportMessage? {
        guard let id = m["id"] as? Int, let roleRaw = m["role"] as? String,
              let role = SupportMessage.Role(rawValue: roleRaw) else { return nil }
        return SupportMessage(id: id, role: role, text: m["text"] as? String ?? "",
                              hasImage: m["has_image"] as? Bool ?? false,
                              hasAudio: m["has_audio"] as? Bool ?? false,
                              createdAt: m["created_at"] as? String ?? "",
                              ticketId: m["ticket_id"] as? Int)
    }

    // MARK: - 本机缓存

    private var apiBase: String {
        apiBaseOverride ?? defaults.string(forKey: "license.apiBase") ?? FeedbackService.defaultAPIBase
    }

    private var storeURL: URL { storeDir.appendingPathComponent("support.json") }
    private var ticketsURL: URL { storeDir.appendingPathComponent("support-tickets.json") }

    private func loadMessages() -> [SupportMessage] {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([SupportMessage].self, from: data) else { return [] }
        return list.sorted { $0.id < $1.id }
    }

    private func loadTickets() -> [SupportTicket] {
        guard let data = try? Data(contentsOf: ticketsURL),
              let list = try? JSONDecoder().decode([SupportTicket].self, from: data) else { return [] }
        return list
    }

    /// 合并消息：同 id 用新的，但保留本机截图缓存（服务器不回传图）
    func append(_ new: [SupportMessage]) {
        var byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for var m in new {
            if m.localImageFile == nil { m.localImageFile = byId[m.id]?.localImageFile }
            byId[m.id] = m
        }
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

    func replaceTickets(_ list: [SupportTicket]) {
        guard list != tickets else { return }
        tickets = list
        saveTickets()
        notify()
    }

    private func upsertTickets(_ list: [SupportTicket]) {
        var byId = Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, $0) })
        for t in list { byId[t.id] = t }
        tickets = Array(byId.values)
        saveTickets()
        notify()
    }

    private func saveTickets() {
        let snapshot = tickets
        let url = ticketsURL
        queue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
