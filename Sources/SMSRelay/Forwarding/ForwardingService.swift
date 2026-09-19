import Foundation
import SMSRelayCore

/// Drains the forwarding queue to Telegram with exponential backoff.
@MainActor
final class ForwardingService {
    private unowned let model: AppModel
    private var loopTask: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?

    private let idleInterval: Duration = .seconds(20)
    /// Permanent errors (bad token, bot blocked, unknown chat) stop after a few tries so the
    /// user can fix the config; transient ones (network down, 5xx, 429) retry forever, capped at 30 min.
    private let maxPermanentAttempts = 3
    /// Seconds to wait after the n-th failure.
    private let backoff: [TimeInterval] = [30, 60, 120, 300, 600, 900, 1800]

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { await run() }
    }

    /// Wake the loop immediately (new message, settings changed, manual retry).
    func kick() {
        sleeper?.cancel()
    }

    private func run() async {
        while !Task.isCancelled {
            await processDue()
            let wait: Duration = pausedUntil.map { until in
                max(.seconds(1), .seconds(Int(until.timeIntervalSinceNow.rounded(.up))))
            } ?? idleInterval
            let s = Task<Void, Never> { try? await Task.sleep(for: wait) }
            sleeper = s
            await s.value
        }
    }

    private var pausedUntil: Date?

    private func processDue() async {
        if let until = pausedUntil {
            guard Date() >= until else { return }
            pausedUntil = nil
        }

        let due: [StoredMessage]
        do { due = try model.store.dueForForwarding(limit: 10) } catch {
            model.log("queue read failed: \(error.localizedDescription)")
            return
        }
        guard !due.isEmpty else { return }

        for msg in due {
            guard let modem = model.modem(routeKey: msg.simNumber ?? "") else { continue }
            let ms = model.settings(for: modem)
            guard ms.forwardingEnabled, ms.telegramConfigured else { continue }
            let operatorName = PLMN.name(for: modem.operatorCode)
            let html = TelegramClient.format(message: msg, includeSIMNumber: ms.includeSIMNumber, operatorName: operatorName)
            let client = TelegramClient(token: ms.telegramBotToken)
            do {
                let ids = try await client.sendMessage(chatID: ms.telegramChatID, html: html)
                try model.store.markForwarded(id: msg.id)
                try? model.store.recordTelegramRefs(ids, chatID: ms.telegramChatID, messageID: msg.id)
                model.telegramStatus = nil
                model.log("forwarded #\(msg.id) from \(msg.sender) via \(modem.label)")
            } catch TelegramError.rateLimited(let retryAfter) {
                let until = Date().addingTimeInterval(TimeInterval(retryAfter) + 1)
                pausedUntil = until
                try? model.store.defer_(id: msg.id, until: until)
                model.telegramStatus = "Telegram rate limit — resuming in \(retryAfter)s"
                model.log("telegram 429 — pausing forwards for \(retryAfter)s")
                break
            } catch {
                let attempts = msg.forwardAttempts + 1
                let permanent = (error as? TelegramError)?.isPermanent ?? false
                let gaveUp = permanent && attempts >= maxPermanentAttempts
                let delay = backoff[min(attempts - 1, backoff.count - 1)]
                _ = try? model.store.markFailed(id: msg.id, error: error.localizedDescription,
                                                nextAttempt: gaveUp ? nil : Date().addingTimeInterval(delay), gaveUp: gaveUp)
                model.telegramStatus = "Forwarding error: \(error.localizedDescription)"
                model.log("forward #\(msg.id) failed (attempt \(attempts)\(gaveUp ? ", giving up" : "")): \(error.localizedDescription)")
                if permanent { break }
                if case .transport? = error as? TelegramError { break }
            }
            try? await Task.sleep(for: TelegramClient.pacingInterval(forChat: ms.telegramChatID))
        }
        model.refreshPage()
    }
}
