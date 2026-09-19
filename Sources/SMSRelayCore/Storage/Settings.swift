import Foundation

/// Per-modem Telegram and radio options. Keyed by IMEI (stable across SIM swaps).
public struct ModemSettings: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var telegramBotToken: String = ""
    public var telegramChatID: String = ""
    public var forwardingEnabled: Bool = false
    public var includeSIMNumber: Bool = true
    public var deleteFromSIM: Bool = true
    public var networkLED: Bool = false
    public var pollIntervalSeconds: Int = 30
    public var healthAlerts: Bool = true
    public var telegramSendEnabled: Bool = true
    public var telegramAllowedUserIDs: String = ""

    public init(id: String) { self.id = id }

    public var telegramConfigured: Bool {
        !telegramBotToken.trimmingCharacters(in: .whitespaces).isEmpty
            && !telegramChatID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var allowedUserIDSet: Set<Int64> {
        Set(telegramAllowedUserIDs.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int64($0) })
    }

    public static func fromLegacy(_ s: Settings) -> ModemSettings {
        var m = ModemSettings(id: "")
        m.telegramBotToken = s.legacyTelegramBotToken
        m.telegramChatID = s.legacyTelegramChatID
        m.forwardingEnabled = s.legacyForwardingEnabled
        m.includeSIMNumber = s.legacyIncludeSIMNumber
        m.deleteFromSIM = s.legacyDeleteFromSIM
        m.networkLED = s.legacyNetworkLED
        m.pollIntervalSeconds = s.legacyPollIntervalSeconds
        m.healthAlerts = s.legacyHealthAlerts
        m.telegramSendEnabled = s.legacyTelegramSendEnabled
        m.telegramAllowedUserIDs = s.legacyTelegramAllowedUserIDs
        return m
    }
}

/// User-editable configuration. Persisted in the SQLite `settings` table so the
/// whole app state lives in one file that is easy to back up or move to the server.
public struct Settings: Equatable, Sendable {
    /// Empty string = auto-detect every ML307 / Air780 on the bus.
    public var portPath: String = ""
    public var keepAliveAutoEnabled: Bool = false
    public var preventSystemSleep: Bool = true
    public var pageSize: Int = 20
    public var modems: [String: ModemSettings] = [:]
    /// MSISDN last seen for an ICCID (ML307 AT+CNUM). Air780 LuatOS often cannot
    /// read EF_MSISDN even when the same SIM reports a number in an ML307.
    public var msisdnByICCID: [String: String] = [:]

    // Legacy global keys, kept so 0.5.x installs migrate into the first modem tab.
    public var legacyTelegramBotToken: String = ""
    public var legacyTelegramChatID: String = ""
    public var legacyForwardingEnabled: Bool = false
    public var legacyIncludeSIMNumber: Bool = true
    public var legacyDeleteFromSIM: Bool = true
    public var legacyNetworkLED: Bool = false
    public var legacyPollIntervalSeconds: Int = 30
    public var legacyHealthAlerts: Bool = true
    public var legacyTelegramSendEnabled: Bool = true
    public var legacyTelegramAllowedUserIDs: String = ""

    public init() {}

    public var anyTelegramConfigured: Bool {
        modems.values.contains { $0.telegramConfigured }
    }

    public var anyForwardingEnabled: Bool {
        modems.values.contains { $0.forwardingEnabled && $0.telegramConfigured }
    }

    public func modem(_ imei: String) -> ModemSettings {
        if var existing = modems[imei] {
            existing.id = imei
            return existing
        }
        var fresh = ModemSettings.fromLegacy(self)
        fresh.id = imei
        return fresh
    }

    public mutating func ensureModem(_ imei: String) -> ModemSettings {
        if modems[imei] == nil {
            modems[imei] = modem(imei)
        }
        return modems[imei]!
    }

    public mutating func updateModem(_ imei: String, _ mutate: (inout ModemSettings) -> Void) {
        var s = ensureModem(imei)
        mutate(&s)
        s.id = imei
        modems[imei] = s
    }
}

public final class SettingsStore: @unchecked Sendable {
    private let store: MessageStore

    public init(store: MessageStore) {
        self.store = store
    }

    public func load() -> Settings {
        var s = Settings()
        s.portPath = (try? store.setting("modem.portPath")) ?? s.portPath
        s.keepAliveAutoEnabled = bool("app.keepAliveAutoEnabled") ?? s.keepAliveAutoEnabled
        s.preventSystemSleep = bool("app.preventSleep") ?? s.preventSystemSleep
        s.pageSize = int("ui.pageSize") ?? s.pageSize

        s.legacyTelegramBotToken = (try? store.setting("telegram.token")) ?? s.legacyTelegramBotToken
        s.legacyTelegramChatID = (try? store.setting("telegram.chatID")) ?? s.legacyTelegramChatID
        s.legacyForwardingEnabled = bool("forwarding.enabled") ?? s.legacyForwardingEnabled
        s.legacyIncludeSIMNumber = bool("forwarding.includeSIMNumber") ?? s.legacyIncludeSIMNumber
        s.legacyDeleteFromSIM = bool("modem.deleteFromSIM") ?? s.legacyDeleteFromSIM
        s.legacyNetworkLED = bool("modem.networkLED") ?? s.legacyNetworkLED
        s.legacyPollIntervalSeconds = int("modem.pollInterval") ?? s.legacyPollIntervalSeconds
        s.legacyHealthAlerts = bool("telegram.healthAlerts") ?? s.legacyHealthAlerts
        s.legacyTelegramSendEnabled = bool("telegram.sendEnabled") ?? s.legacyTelegramSendEnabled
        s.legacyTelegramAllowedUserIDs = (try? store.setting("telegram.allowedUserIDs")) ?? s.legacyTelegramAllowedUserIDs

        if let json = try? store.setting("modems.json"), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: ModemSettings].self, from: data) {
            s.modems = decoded
        }
        if let json = try? store.setting("sim.msisdn.json"), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            s.msisdnByICCID = decoded
        }
        return s
    }

    public func save(_ s: Settings) throws {
        try store.setSetting("modem.portPath", s.portPath.trimmingCharacters(in: .whitespaces))
        try store.setSetting("app.keepAliveAutoEnabled", s.keepAliveAutoEnabled ? "1" : "0")
        try store.setSetting("app.preventSleep", s.preventSystemSleep ? "1" : "0")
        try store.setSetting("ui.pageSize", String(max(5, s.pageSize)))
        let data = try JSONEncoder().encode(s.modems)
        try store.setSetting("modems.json", String(data: data, encoding: .utf8) ?? "{}")
        let numbers = try JSONEncoder().encode(s.msisdnByICCID)
        try store.setSetting("sim.msisdn.json", String(data: numbers, encoding: .utf8) ?? "{}")
        // Keep legacy keys in sync with an empty-id template so older builds still boot.
        let t = ModemSettings.fromLegacy(s)
        let first = s.modems.values.sorted { $0.id < $1.id }.first ?? t
        try store.setSetting("telegram.token", first.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines))
        try store.setSetting("telegram.chatID", first.telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines))
        try store.setSetting("forwarding.enabled", (s.anyForwardingEnabled) ? "1" : "0")
        try store.setSetting("forwarding.includeSIMNumber", first.includeSIMNumber ? "1" : "0")
        try store.setSetting("modem.deleteFromSIM", first.deleteFromSIM ? "1" : "0")
        try store.setSetting("modem.pollInterval", String(max(5, first.pollIntervalSeconds)))
        try store.setSetting("modem.networkLED", first.networkLED ? "1" : "0")
        try store.setSetting("telegram.healthAlerts", first.healthAlerts ? "1" : "0")
        try store.setSetting("telegram.sendEnabled", first.telegramSendEnabled ? "1" : "0")
        try store.setSetting("telegram.allowedUserIDs", first.telegramAllowedUserIDs.trimmingCharacters(in: .whitespaces))
    }

    private func bool(_ key: String) -> Bool? {
        (try? store.setting(key)).flatMap { $0 }.map { $0 == "1" }
    }

    private func int(_ key: String) -> Int? {
        (try? store.setting(key)).flatMap { $0 }.flatMap(Int.init)
    }
}
