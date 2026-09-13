import Foundation
import SMSRelayCore

/// Sends operational alerts to the Telegram chat, rate-limited per (topic, modem) so a
/// flapping modem cannot flood the chat.
@MainActor
final class HealthAlerter {
    enum Topic: String { case modemDown, modemUp, registrationLost, registrationBack, simProblem }

    private unowned let model: AppModel
    private var lastSent: [String: Date] = [:]   // "topic|modemID" → time
    private let minInterval: TimeInterval = 10 * 60

    init(model: AppModel) {
        self.model = model
    }

    func send(_ topic: Topic, _ modem: Modem, _ text: String, force: Bool = false) {
        let settings = model.settings
        guard settings.healthAlerts, settings.telegramConfigured else { return }
        let key = "\(topic.rawValue)|\(modem.id)"
        if !force, let last = lastSent[key], Date().timeIntervalSince(last) < minInterval { return }
        lastSent[key] = Date()
        let client = TelegramClient(token: settings.telegramBotToken)
        let host = Host.current().localizedName ?? "Mac"
        let html = "\(text)\n<i>\(AppInfo.shortName) · \(TelegramClient.escapeHTML(modem.label)) · \(host)</i>"
        Task {
            do {
                try await client.sendMessage(chatID: settings.telegramChatID, html: html)
            } catch {
                model.log("health alert failed: \(error.localizedDescription)")
            }
        }
    }
}
