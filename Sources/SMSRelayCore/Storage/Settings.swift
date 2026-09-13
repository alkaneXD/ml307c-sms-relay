import Foundation

/// User-editable configuration. Persisted in the SQLite `settings` table so the
/// whole app state lives in one file that is easy to back up or move to the server.
public struct Settings: Equatable, Sendable {
    public var telegramBotToken: String = ""
    public var telegramChatID: String = ""
    public var forwardingEnabled: Bool = false
    public var includeSIMNumber: Bool = true
    /// Remove messages from SIM/ME storage once safely in SQLite (keeps the 40-slot SIM from filling up).
    public var deleteFromSIM: Bool = true
    /// Empty string = auto-detect the first port that identifies as an ML307.
    public var portPath: String = ""
    /// Fallback `AT+CMGL` sweep interval, in case a +CMTI URC is missed.
    public var pollIntervalSeconds: Int = 30
    /// The module's NETLIGHT pin (blinking green on the dongle). Re-applied on every connect.
    /// Off by default: a headless forwarder has no one to blink at.
    public var networkLED: Bool = false
    /// Set once the app has auto-enabled launchd supervision, so a user who turns it off stays off.
    public var keepAliveAutoEnabled: Bool = false
    /// Hold a power assertion so the Mac never idle-sleeps while the modem is attached.
    public var preventSystemSleep: Bool = true
    /// Telegram messages when the modem drops out / recovers or loses network registration.
    public var healthAlerts: Bool = true
    /// Let the Telegram chat send SMS through the SIM (reply to a forwarded message, or /sms).
    public var telegramSendEnabled: Bool = true
    /// Optional comma-separated Telegram user IDs allowed to send; empty = anyone in the chat.
    public var telegramAllowedUserIDs: String = ""
    public var pageSize: Int = 20

    public var allowedUserIDSet: Set<Int64> {
        Set(telegramAllowedUserIDs.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int64($0) })
    }

    public init() {}

    public var telegramConfigured: Bool {
        !telegramBotToken.trimmingCharacters(in: .whitespaces).isEmpty
            && !telegramChatID.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

public final class SettingsStore: @unchecked Sendable {
    private let store: MessageStore

    public init(store: MessageStore) {
        self.store = store
    }

    public func load() -> Settings {
        var s = Settings()
        s.telegramBotToken = (try? store.setting("telegram.token")) ?? s.telegramBotToken
        s.telegramChatID = (try? store.setting("telegram.chatID")) ?? s.telegramChatID
        s.forwardingEnabled = bool("forwarding.enabled") ?? s.forwardingEnabled
        s.includeSIMNumber = bool("forwarding.includeSIMNumber") ?? s.includeSIMNumber
        s.deleteFromSIM = bool("modem.deleteFromSIM") ?? s.deleteFromSIM
        s.portPath = (try? store.setting("modem.portPath")) ?? s.portPath
        s.pollIntervalSeconds = int("modem.pollInterval") ?? s.pollIntervalSeconds
        s.networkLED = bool("modem.networkLED") ?? s.networkLED
        s.keepAliveAutoEnabled = bool("app.keepAliveAutoEnabled") ?? s.keepAliveAutoEnabled
        s.preventSystemSleep = bool("app.preventSleep") ?? s.preventSystemSleep
        s.healthAlerts = bool("telegram.healthAlerts") ?? s.healthAlerts
        s.telegramSendEnabled = bool("telegram.sendEnabled") ?? s.telegramSendEnabled
        s.telegramAllowedUserIDs = (try? store.setting("telegram.allowedUserIDs")) ?? s.telegramAllowedUserIDs
        s.pageSize = int("ui.pageSize") ?? s.pageSize
        return s
    }

    public func save(_ s: Settings) throws {
        try store.setSetting("telegram.token", s.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines))
        try store.setSetting("telegram.chatID", s.telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines))
        try store.setSetting("forwarding.enabled", s.forwardingEnabled ? "1" : "0")
        try store.setSetting("forwarding.includeSIMNumber", s.includeSIMNumber ? "1" : "0")
        try store.setSetting("modem.deleteFromSIM", s.deleteFromSIM ? "1" : "0")
        try store.setSetting("modem.portPath", s.portPath.trimmingCharacters(in: .whitespaces))
        try store.setSetting("modem.pollInterval", String(max(5, s.pollIntervalSeconds)))
        try store.setSetting("modem.networkLED", s.networkLED ? "1" : "0")
        try store.setSetting("app.keepAliveAutoEnabled", s.keepAliveAutoEnabled ? "1" : "0")
        try store.setSetting("app.preventSleep", s.preventSystemSleep ? "1" : "0")
        try store.setSetting("telegram.healthAlerts", s.healthAlerts ? "1" : "0")
        try store.setSetting("telegram.sendEnabled", s.telegramSendEnabled ? "1" : "0")
        try store.setSetting("telegram.allowedUserIDs", s.telegramAllowedUserIDs.trimmingCharacters(in: .whitespaces))
        try store.setSetting("ui.pageSize", String(max(5, s.pageSize)))
    }

    private func bool(_ key: String) -> Bool? {
        (try? store.setting(key)).flatMap { $0 }.map { $0 == "1" }
    }

    private func int(_ key: String) -> Int? {
        (try? store.setting(key)).flatMap { $0 }.flatMap(Int.init)
    }
}
