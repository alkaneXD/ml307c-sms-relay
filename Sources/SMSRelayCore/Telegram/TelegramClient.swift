import Foundation

public enum TelegramError: Error, LocalizedError, Sendable, Equatable {
    case notConfigured
    case http(Int, String)
    case api(String)
    case transport(String)
    /// HTTP 429 — Telegram asks us to wait `retryAfter` seconds.
    case rateLimited(retryAfter: Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Telegram bot token / chat ID not set"
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .api(let desc): return desc
        case .transport(let msg): return msg
        case .rateLimited(let s): return "Telegram rate limit — retry after \(s)s"
        }
    }

    /// Errors that will not fix themselves with a retry (bad token, blocked bot, bad chat).
    public var isPermanent: Bool {
        switch self {
        case .notConfigured: return true
        case .http(let code, _): return code == 400 || code == 401 || code == 403 || code == 404
        case .api, .transport, .rateLimited: return false
        }
    }
}

public struct TelegramBotInfo: Sendable, Equatable {
    public let id: Int64
    public let username: String
    public let firstName: String
}

public struct TelegramChatCandidate: Sendable, Equatable, Identifiable {
    public var id: Int64 { chatID }
    public let chatID: Int64
    public let title: String
    public let type: String
}

/// Thin Bot API client — only the calls the forwarder needs.
public struct TelegramClient: Sendable {
    public let token: String
    private let session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    /// Telegram caps a message at 4096 characters; long multipart SMS are sent as numbered chunks.
    public static let maxMessageLength = 4000

    /// Sends (chunking if needed) and returns the Telegram message IDs, so replies can be mapped back.
    @discardableResult
    public func sendMessage(chatID: String, html: String, replyTo: Int64? = nil) async throws -> [Int64] {
        var ids: [Int64] = []
        for chunk in Self.chunks(html) {
            var params: [String: Any] = [
                "chat_id": chatID,
                "text": chunk,
                "parse_mode": "HTML",
                "disable_web_page_preview": true,
            ]
            if let replyTo {
                params["reply_parameters"] = ["message_id": replyTo, "allow_sending_without_reply": true]
            }
            let result = try await call("sendMessage", params)
            if let id = (result["message_id"] as? NSNumber)?.int64Value { ids.append(id) }
        }
        return ids
    }

    // MARK: - Inbound (long polling)

    public struct Update: Sendable, Equatable {
        public let updateID: Int64
        public let message: Message?
    }

    public struct Message: Sendable, Equatable {
        public let messageID: Int64
        public let chatID: Int64
        public let chatType: String
        public let fromID: Int64?
        public let fromName: String
        public let text: String
        public let replyToMessageID: Int64?
        public let date: Date
    }

    /// Long-polls for new updates. `timeout` is the server-side wait (seconds); the HTTP request
    /// is allowed a bit longer. Pass `offset` = last seen update_id + 1 to acknowledge.
    public func getUpdates(offset: Int64?, timeout: Int = 30) async throws -> [Update] {
        var params: [String: Any] = ["timeout": timeout, "allowed_updates": ["message"]]
        if let offset { params["offset"] = offset }
        let raw = try await callArray("getUpdates", params, requestTimeout: TimeInterval(timeout + 15))
        return raw.compactMap { u in
            guard let id = (u["update_id"] as? NSNumber)?.int64Value else { return nil }
            var msg: Message? = nil
            if let m = u["message"] as? [String: Any],
               let mid = (m["message_id"] as? NSNumber)?.int64Value,
               let chat = m["chat"] as? [String: Any],
               let cid = (chat["id"] as? NSNumber)?.int64Value {
                let from = m["from"] as? [String: Any]
                let name = [from?["first_name"] as? String, from?["last_name"] as? String].compactMap { $0 }.joined(separator: " ")
                msg = Message(
                    messageID: mid, chatID: cid, chatType: chat["type"] as? String ?? "",
                    fromID: (from?["id"] as? NSNumber)?.int64Value, fromName: name,
                    text: (m["text"] as? String) ?? (m["caption"] as? String) ?? "",
                    replyToMessageID: ((m["reply_to_message"] as? [String: Any])?["message_id"] as? NSNumber)?.int64Value,
                    date: Date(timeIntervalSince1970: (m["date"] as? NSNumber)?.doubleValue ?? 0)
                )
            }
            return Update(updateID: id, message: msg)
        }
    }

    /// getUpdates and webhooks are mutually exclusive; make sure polling can work.
    public func deleteWebhook() async throws {
        _ = try await request("deleteWebhook", ["drop_pending_updates": false])
    }

    public func setMyCommands(_ commands: [(command: String, description: String)]) async throws {
        _ = try await request("setMyCommands", [
            "commands": commands.map { ["command": $0.command, "description": $0.description] },
        ])
    }

    /// Splits on line boundaries where possible and never inside an HTML entity/tag.
    public static func chunks(_ text: String) -> [String] {
        guard text.count > maxMessageLength else { return [text] }
        var out: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.count <= maxMessageLength {
                out.append(String(rest))
                break
            }
            let hardEnd = rest.index(rest.startIndex, offsetBy: maxMessageLength)
            var cut = rest[..<hardEnd].lastIndex(of: "\n") ?? rest[..<hardEnd].lastIndex(of: " ") ?? hardEnd
            if cut == rest.startIndex { cut = hardEnd }
            // Back off if we'd split a tag or entity.
            let piece = rest[..<cut]
            if let lt = piece.lastIndex(of: "<"), piece[lt...].firstIndex(of: ">") == nil { cut = lt }
            if let amp = piece.lastIndex(of: "&"), piece[amp...].firstIndex(of: ";") == nil, amp > rest.startIndex { cut = amp }
            out.append(String(rest[..<cut]))
            rest = rest[cut...].drop { $0 == "\n" || $0 == " " }
        }
        return out.enumerated().map { i, s in out.count > 1 ? "\(s)\n<i>(\(i + 1)/\(out.count))</i>" : s }
    }

    public func getMe() async throws -> TelegramBotInfo {
        let result = try await call("getMe", [:])
        guard let id = (result["id"] as? NSNumber)?.int64Value else { throw TelegramError.api("malformed getMe") }
        return TelegramBotInfo(
            id: id,
            username: result["username"] as? String ?? "",
            firstName: result["first_name"] as? String ?? ""
        )
    }

    /// Lists chats that have recently messaged the bot — lets the user pick a chat ID
    /// without hunting for it. Requires no webhook to be configured on the bot.
    public func recentChats() async throws -> [TelegramChatCandidate] {
        let result = try await callArray("getUpdates", ["limit": 50, "timeout": 0])
        var seen: [Int64: TelegramChatCandidate] = [:]
        for update in result {
            let msg = (update["message"] ?? update["channel_post"] ?? update["my_chat_member"]) as? [String: Any]
            guard let chat = msg?["chat"] as? [String: Any],
                  let id = (chat["id"] as? NSNumber)?.int64Value else { continue }
            let type = chat["type"] as? String ?? ""
            let title = chat["title"] as? String
                ?? [chat["first_name"] as? String, chat["last_name"] as? String].compactMap { $0 }.joined(separator: " ")
            let username = (chat["username"] as? String).map { " (@\($0))" } ?? ""
            seen[id] = TelegramChatCandidate(chatID: id, title: title + username, type: type)
        }
        return seen.values.sorted { $0.chatID < $1.chatID }
    }

    // MARK: - transport

    private func request(_ method: String, _ params: [String: Any], requestTimeout: TimeInterval = 20) async throws -> Any {
        guard !token.isEmpty else { throw TelegramError.notConfigured }
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw TelegramError.transport("bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = requestTimeout
        req.httpBody = try JSONSerialization.data(withJSONObject: params)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw TelegramError.transport(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let json, json["ok"] as? Bool == true, let result = json["result"] {
            return result
        }
        let desc = json?["description"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self)
        if http?.statusCode == 429 || (json?["error_code"] as? Int) == 429 {
            let retry = ((json?["parameters"] as? [String: Any])?["retry_after"] as? NSNumber)?.intValue ?? 30
            throw TelegramError.rateLimited(retryAfter: max(1, retry))
        }
        if let code = http?.statusCode, code != 200 { throw TelegramError.http(code, desc) }
        throw TelegramError.api(desc)
    }

    /// Telegram's documented sending limits: ~1 msg/s per private chat, 20 msg/min into groups.
    public static func pacingInterval(forChat chatID: String) -> Duration {
        chatID.hasPrefix("-") ? .seconds(3) : .seconds(1)
    }

    private func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let r = try await request(method, params)
        return r as? [String: Any] ?? [:]
    }

    private func callArray(_ method: String, _ params: [String: Any], requestTimeout: TimeInterval = 20) async throws -> [[String: Any]] {
        let r = try await request(method, params, requestTimeout: requestTimeout)
        return r as? [[String: Any]] ?? []
    }

    // MARK: - formatting

    public static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The forwarded message body. Kept plain so it renders well on phones.
    public static func format(message: StoredMessage, includeSIMNumber: Bool, operatorName: String?) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = .current
        var lines: [String] = []
        lines.append("📩 <b>\(escapeHTML(message.sender))</b>")
        var meta: [String] = [df.string(from: message.displayDate)]
        if includeSIMNumber, let sim = message.simDisplay ?? message.simNumber, !sim.isEmpty {
            meta.append("→ \(escapeHTML(sim))" + (operatorName.map { " (\(escapeHTML($0)))" } ?? ""))
        }
        if message.partCount > 1 { meta.append("\(message.partCount) parts") }
        lines.append("<i>\(meta.joined(separator: " · "))</i>")
        lines.append("")
        lines.append(escapeHTML(message.body))
        return lines.joined(separator: "\n")
    }
}
