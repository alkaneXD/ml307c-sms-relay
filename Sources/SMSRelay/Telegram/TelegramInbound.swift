import Foundation
import SMSRelayCore

/// Listens to each modem's Telegram chat (long polling — no server or webhook needed)
/// and turns replies / commands into outgoing SMS.
///
///   • Reply to a forwarded SMS  → SMS back to that sender via that SIM
///   • /sms +639171234567 text   → SMS via the modem this chat belongs to
///   • /status                   → that modem (and others)
///   • /help
@MainActor
final class TelegramInbound {
    private unowned let model: AppModel
    private var supervisor: Task<Void, Never>?
    private var pollers: [String: Task<Void, Never>] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard supervisor == nil else { return }
        supervisor = Task { await supervise() }
    }

    private func supervise() async {
        while !Task.isCancelled {
            let wanted = Set(model.settings.modems.values
                .filter { $0.telegramConfigured && $0.telegramSendEnabled }
                .map(\.telegramBotToken))
            for token in pollers.keys where !wanted.contains(token) {
                pollers[token]?.cancel()
                pollers[token] = nil
            }
            for token in wanted where pollers[token] == nil {
                let t = token
                pollers[t] = Task { await poll(token: t) }
            }
            model.telegramListening = !pollers.isEmpty
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func offsetKey(_ token: String) -> String {
        "telegram.updateOffset." + String(token.prefix(24))
    }

    private func poll(token: String) async {
        let client = TelegramClient(token: token)
        try? await client.deleteWebhook()
        try? await client.setMyCommands([
            ("status", "Modem, network and SIM status"),
            ("sms", "Send an SMS: /sms +639171234567 your text"),
            ("help", "How to reply to forwarded messages"),
        ])
        var offset = (try? model.store.setting(offsetKey(token))).flatMap { $0 }.flatMap(Int64.init)
        if offset == nil {
            if let last = try? await client.getUpdates(offset: -1, timeout: 0) {
                offset = last.last?.updateID ?? 0
                try? model.store.setSetting(offsetKey(token), String(offset ?? 0))
                model.log("telegram: listening (\(token.prefix(8))…)")
            } else {
                try? await Task.sleep(for: .seconds(5))
            }
        }
        while !Task.isCancelled {
            let stillWanted = model.settings.modems.values.contains {
                $0.telegramBotToken == token && $0.telegramConfigured && $0.telegramSendEnabled
            }
            guard stillWanted else { return }
            do {
                let updates = try await client.getUpdates(offset: (offset ?? 0) + 1, timeout: 30)
                for update in updates {
                    offset = max(offset ?? 0, update.updateID)
                    if let message = update.message {
                        await handle(message, token: token, client: client)
                    }
                }
                if !updates.isEmpty, let offset {
                    try? model.store.setSetting(offsetKey(token), String(offset))
                }
            } catch {
                let conflict = (error as? TelegramError).map { if case .http(409, _) = $0 { return true } else { return false } } ?? false
                model.log("telegram poll failed: \(error.localizedDescription)\(conflict ? " (another poller is using this bot token)" : "")")
                try? await Task.sleep(for: .seconds(conflict ? 30 : 5))
            }
        }
    }

    private func settings(forChat chatID: Int64, token: String) -> (imei: String, settings: ModemSettings)? {
        let chat = String(chatID)
        let hits = model.settings.modems.filter {
            $0.value.telegramBotToken == token
                && $0.value.telegramChatID.trimmingCharacters(in: .whitespaces) == chat
        }
        guard let first = hits.sorted(by: { $0.key < $1.key }).first else { return nil }
        return (first.key, first.value)
    }

    private func handle(_ m: TelegramClient.Message, token: String, client: TelegramClient) async {
        guard let target = settings(forChat: m.chatID, token: token) else { return }
        let ms = target.settings
        let chatID = ms.telegramChatID
        let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        func reply(_ html: String) async {
            _ = try? await client.sendMessage(chatID: chatID, html: html, replyTo: m.messageID)
        }

        if text.hasPrefix("/") {
            let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let command = parts[0].lowercased().split(separator: "@")[0]
            let args = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            switch command {
            case "/status":
                await reply(statusHTML())
            case "/help", "/start":
                await reply(helpHTML())
            case "/sms":
                guard authorized(m, settings: ms) else { await reply(notAllowedHTML(ms)); return }
                let pieces = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard pieces.count == 2, let number = PDUEncoder.normalizeNumber(String(pieces[0])) else {
                    await reply("Usage: <code>/sms +639171234567 your message</code>")
                    return
                }
                let route = model.modem(id: target.imei)?.routeKey
                await enqueue(to: number, text: String(pieces[1]).trimmingCharacters(in: .whitespaces), request: m,
                              routeKey: route, reply: reply)
            default:
                await reply("Unknown command. Try /help.")
            }
            return
        }

        if let replyTo = m.replyToMessageID {
            guard authorized(m, settings: ms) else { await reply(notAllowedHTML(ms)); return }
            guard let original = try? model.store.message(forTelegramMessageID: replyTo, chatID: chatID) else {
                await reply("I can't match that message to an SMS. Reply to a forwarded SMS, or use <code>/sms +63… text</code>.")
                return
            }
            guard let number = PDUEncoder.normalizeNumber(original.sender) else {
                await reply("<b>\(TelegramClient.escapeHTML(original.sender))</b> is an alphanumeric sender — it can't receive replies.")
                return
            }
            await enqueue(to: number, text: text, request: m, routeKey: original.simNumber, reply: reply)
        }
    }

    private func authorized(_ m: TelegramClient.Message, settings: ModemSettings) -> Bool {
        guard settings.telegramSendEnabled else { return false }
        let allowed = settings.allowedUserIDSet
        guard !allowed.isEmpty else { return true }
        return m.fromID.map(allowed.contains) ?? false
    }

    private func enqueue(to number: String, text: String, request: TelegramClient.Message,
                         routeKey: String?, reply: (String) async -> Void) async {
        guard !text.isEmpty else { await reply("Nothing to send — the message is empty."); return }
        do {
            _ = try model.store.enqueueOutgoing(to: number, body: text, simNumber: routeKey, telegramRequestID: request.messageID)
            model.refreshPage()
            model.modemManager?.kickOutgoing()
            let via = model.modem(routeKey: routeKey ?? "")
            model.log("telegram: \(request.fromName) queued SMS to \(number) via \(via?.label ?? "primary") (\(text.count) chars)")
            let ready = via?.isSMSReady ?? model.modems.contains { $0.isSMSReady }
            if !ready {
                await reply("⏳ Modem is offline — queued for <b>\(TelegramClient.escapeHTML(number))</b>, will send when it's back.")
            }
        } catch {
            await reply("❌ Could not queue: \(TelegramClient.escapeHTML(error.localizedDescription))")
        }
    }

    private func notAllowedHTML(_ ms: ModemSettings) -> String {
        ms.telegramSendEnabled
            ? "You're not on the allowed-sender list."
            : "Sending SMS from Telegram is turned off in \(AppInfo.displayName) settings."
    }

    private func helpHTML() -> String {
        """
        <b>\(AppInfo.displayName)</b> forwards SMS from this SIM to this chat.
        • <b>Reply</b> to a forwarded SMS → it's sent back to that number via the SIM.
        • <code>/sms +639171234567 text</code> → SMS to any number.
        • <code>/status</code> → modem, network and SIM status.
        Long texts are split into multiple SMS automatically; unicode/emoji are supported.
        """
    }

    private func statusHTML() -> String {
        func esc(_ s: String) -> String { TelegramClient.escapeHTML(s) }
        var lines = ["📡 <b>\(AppInfo.shortName) status</b>"]
        if model.modems.isEmpty {
            lines.append("⚠️ No modem detected.")
        }
        for modem in model.modems {
            let icon: String
            switch modem.connection {
            case .connected: icon = modem.isRegistered ? "🟢" : "🟡"
            case .connecting, .searching: icon = "🟡"
            case .disconnected: icon = "🔴"
            }
            var line = "\(icon) <b>\(esc(modem.label))</b>"
            if modem.isRegistered {
                line += " — \(esc(modem.operatorName)) · \(modem.accessTechnologyName) · \(modem.signal.level.label)"
            } else if modem.connection.isConnected {
                line += " — \(esc(modem.registration?.statusText ?? "registering…"))"
            } else if case .disconnected(let reason) = modem.connection {
                line += " — \(esc(reason))"
            }
            if let used = modem.storageUsed, let total = modem.storageTotal { line += " · SIM \(used)/\(total)" }
            lines.append(line)
        }
        let c = model.counts
        let outgoing = (try? model.store.dueOutgoing(limit: 100).count) ?? 0
        lines.append("")
        lines.append("Messages: \(c.total) received · \(c.pending) waiting to forward · \(outgoing) SMS queued")
        return lines.joined(separator: "\n")
    }
}
