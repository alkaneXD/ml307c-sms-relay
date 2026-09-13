import Foundation
import SMSRelayCore

/// Listens to the Telegram chat (long polling — no server or webhook needed) and turns
/// replies / commands into outgoing SMS.
///
///   • Reply to a forwarded SMS  → SMS back to that sender
///   • /sms +639171234567 text   → SMS to any number
///   • /status                   → modem, network, SIM and queue summary
///   • /help
@MainActor
final class TelegramInbound {
    private unowned let model: AppModel
    private var task: Task<Void, Never>?
    private var offset: Int64?
    private var preparedToken: String?
    private var warnedChat: Int64?

    private static let offsetKey = "telegram.updateOffset"

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard task == nil else { return }
        offset = (try? model.store.setting(Self.offsetKey)).flatMap { $0 }.flatMap(Int64.init)
        task = Task { await run() }
    }

    // MARK: - Poll loop

    private func run() async {
        while !Task.isCancelled {
            let settings = model.settings
            // Telegram allows exactly one getUpdates consumer per bot token. Only poll when this
            // machine is meant to act on chat input, so a second Mac with the same bot (send off)
            // does not steal updates from the one with the modem.
            guard settings.telegramConfigured, settings.telegramSendEnabled else {
                model.telegramListening = false
                try? await Task.sleep(for: .seconds(10))
                continue
            }
            let client = TelegramClient(token: settings.telegramBotToken)

            if preparedToken != settings.telegramBotToken {
                try? await client.deleteWebhook()
                try? await client.setMyCommands([
                    ("status", "Modem, network and SIM status"),
                    ("sms", "Send an SMS: /sms +639171234567 your text"),
                    ("help", "How to reply to forwarded messages"),
                ])
                preparedToken = settings.telegramBotToken
            }

            // First run: skip the chat's history so old replies are not replayed as SMS.
            if offset == nil {
                if let last = try? await client.getUpdates(offset: -1, timeout: 0) {
                    offset = last.last?.updateID ?? 0
                    persistOffset()
                    model.log("telegram: listening for replies and commands")
                } else {
                    try? await Task.sleep(for: .seconds(5))
                }
                continue
            }

            do {
                let updates = try await client.getUpdates(offset: (offset ?? 0) + 1, timeout: 30)
                model.telegramListening = true
                for update in updates {
                    offset = max(offset ?? 0, update.updateID)
                    if let message = update.message {
                        await handle(message, client: client)
                    }
                }
                if !updates.isEmpty { persistOffset() }
            } catch {
                model.telegramListening = false
                let conflict = (error as? TelegramError).map { if case .http(409, _) = $0 { return true } else { return false } } ?? false
                model.log("telegram poll failed: \(error.localizedDescription)\(conflict ? " (another poller is using this bot token)" : "")")
                try? await Task.sleep(for: .seconds(conflict ? 30 : 5))
            }
        }
    }

    private func persistOffset() {
        if let offset { try? model.store.setSetting(Self.offsetKey, String(offset)) }
    }

    // MARK: - Handling

    private func handle(_ m: TelegramClient.Message, client: TelegramClient) async {
        let settings = model.settings
        guard String(m.chatID) == settings.telegramChatID.trimmingCharacters(in: .whitespaces) else {
            if warnedChat != m.chatID {
                warnedChat = m.chatID
                model.log("telegram: ignoring message from chat \(m.chatID) (\(m.chatType)) — not the configured chat")
            }
            return
        }
        let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        func reply(_ html: String) async {
            _ = try? await client.sendMessage(chatID: settings.telegramChatID, html: html, replyTo: m.messageID)
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
                guard authorized(m, settings: settings) else { await reply(notAllowedHTML()); return }
                let pieces = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard pieces.count == 2, let number = PDUEncoder.normalizeNumber(String(pieces[0])) else {
                    await reply("Usage: <code>/sms +639171234567 your message</code>")
                    return
                }
                // /sms goes out via the primary modem's SIM.
                await enqueue(to: number, text: String(pieces[1]).trimmingCharacters(in: .whitespaces), request: m,
                              routeKey: model.primaryModem?.routeKey, reply: reply)
            default:
                await reply("Unknown command. Try /help.")
            }
            return
        }

        if let replyTo = m.replyToMessageID {
            guard authorized(m, settings: settings) else { await reply(notAllowedHTML()); return }
            guard let original = try? model.store.message(forTelegramMessageID: replyTo, chatID: settings.telegramChatID) else {
                await reply("I can't match that message to an SMS. Reply to a forwarded SMS, or use <code>/sms +63… text</code>.")
                return
            }
            guard let number = PDUEncoder.normalizeNumber(original.sender) else {
                await reply("<b>\(TelegramClient.escapeHTML(original.sender))</b> is an alphanumeric sender — it can't receive replies.")
                return
            }
            // Route the reply back through the SIM that received the original message, so the
            // recipient sees it from the right number.
            await enqueue(to: number, text: text, request: m, routeKey: original.simNumber, reply: reply)
        }
        // Plain chat messages that aren't replies are ignored.
    }

    private func authorized(_ m: TelegramClient.Message, settings: Settings) -> Bool {
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
            // If the target modem isn't ready, let the requester know it's queued.
            let ready = via?.isRegistered ?? model.modems.contains { $0.isRegistered }
            if !ready {
                await reply("⏳ Modem is offline — queued for <b>\(TelegramClient.escapeHTML(number))</b>, will send when it's back.")
            }
        } catch {
            await reply("❌ Could not queue: \(TelegramClient.escapeHTML(error.localizedDescription))")
        }
    }

    // MARK: - Texts

    private func notAllowedHTML() -> String {
        model.settings.telegramSendEnabled
            ? "You're not on the allowed-sender list."
            : "Sending SMS from Telegram is turned off in \(AppInfo.displayName) settings."
    }

    private func helpHTML() -> String {
        """
        <b>\(AppInfo.displayName)</b> forwards SMS from the SIM to this chat.
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
