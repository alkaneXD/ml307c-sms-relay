import AppKit
import Foundation
import Observation
import SMSRelayCore

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let text: String
    let modemID: String?
}

/// Single source of truth for the UI. Services mutate it on the main actor.
@MainActor
@Observable
final class AppModel {
    // Modems (one per physical unit, managed by ModemManager)
    var modems: [Modem] = []

    // Global safeguards / status
    var networkGuardStatus: String?
    var usbResetBusy = false
    var lastError: String?

    // Messages
    var page: MessagePage = .empty
    var pageIndex = 0
    var search = "" { didSet { pageIndex = 0; refreshPage() } }
    var counts = MessageStore.Counts.zero

    // Telegram
    var telegramBot: TelegramBotInfo?
    var telegramStatus: String?
    var telegramBusy = false
    var telegramListening = false
    var chatCandidates: [TelegramChatCandidate] = []

    /// `"app"` or a modem IMEI. Inbox, Log, Settings, and the header all follow this selection.
    var settingsModemID: String = "app" {
        didSet {
            guard oldValue != settingsModemID else { return }
            pageIndex = 0
            refreshPage()
        }
    }

    var selectedModem: Modem? {
        guard settingsModemID != "app" else { return nil }
        return modems.first { $0.id == settingsModemID }
    }

    /// `nil` = unscoped (should not be used by the UI). Empty = no rows. Else this stick's SIM keys.
    var inboxRouteKeys: [String] {
        if settingsModemID == "app" { return [] }
        if let modem = selectedModem { return modem.routeAliases }
        return ["imei:" + settingsModemID]
    }

    // Settings
    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            do { try settingsStore.save(settings) } catch { log("settings save failed: \(error.localizedDescription)") }
            if settings.portPath != oldValue.portPath { modemManager?.rescan() }
            if settings.preventSystemSleep != oldValue.preventSystemSleep { updatePowerAssertion() }
            if settings.pageSize != oldValue.pageSize { refreshPage() }
            if settings.modems != oldValue.modems {
                forwardingService?.kick()
                for (id, s) in settings.modems where s.networkLED != oldValue.modems[id]?.networkLED {
                    modemManager?.applyNetworkLED(id: id)
                }
            }
        }
    }

    var logEntries: [LogEntry] = []
    var keepAliveStatus: String = KeepAlive.statusText

    let store: MessageStore
    let databasePath: String
    let fileLog = FileLog()
    private let settingsStore: SettingsStore
    private let powerAssertion = PowerAssertion()
    var modemManager: ModemManager?
    var forwardingService: ForwardingService?
    var telegramInbound: TelegramInbound?
    var alerter: HealthAlerter?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent(AppInfo.internalName, isDirectory: true)
        databasePath = dir.appendingPathComponent("smsrelay.sqlite").path
        Self.migrateLegacyDatabase(to: databasePath, support: support)
        do {
            let db = try Database(path: databasePath)
            store = try MessageStore(database: db)
        } catch {
            // Without the database nothing can be stored safely; say so and stop (clean exit → launchd won't loop).
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "\(AppInfo.displayName) cannot open its database"
            alert.informativeText = "\(databasePath)\n\n\(error.localizedDescription)"
            alert.runModal()
            exit(0)
        }
        settingsStore = SettingsStore(store: store)
        settings = settingsStore.load()
        refreshPage()
    }

    /// 0.1/0.2 stored data under "Remora"; move it (with the WAL side files) the first time the new name runs.
    private static func migrateLegacyDatabase(to newPath: String, support: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: newPath) else { return }
        let oldDir = support.appendingPathComponent(AppInfo.Legacy.appSupportFolder, isDirectory: true)
        let oldDB = oldDir.appendingPathComponent(AppInfo.Legacy.databaseFile)
        guard fm.fileExists(atPath: oldDB.path) else { return }
        let newDir = URL(fileURLWithPath: newPath).deletingLastPathComponent()
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: oldDB.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.moveItem(at: src, to: URL(fileURLWithPath: newPath + suffix))
        }
        if (try? fm.contentsOfDirectory(atPath: oldDir.path))?.isEmpty ?? false {
            try? fm.removeItem(at: oldDir)
        }
    }

    func start() {
        let manager = ModemManager(app: self)
        let forwarding = ForwardingService(model: self)
        modemManager = manager
        forwardingService = forwarding
        alerter = HealthAlerter(model: self)
        let inbound = TelegramInbound(model: self)
        telegramInbound = inbound
        manager.start()
        forwarding.start()
        inbound.start()
        updatePowerAssertion()
        log("\(AppInfo.displayName) \(AppInfo.version) started\(KeepAlive.isLaunchdManaged ? " (launchd)" : "") · db \(databasePath)")
        if KeepAlive.migrateLegacyAgent() {
            log("migrated launchd supervision from the old app name")
        }
        if KeepAlive.handOverToLaunchdIfNeeded() {
            log("supervision is on — handing over to the launchd-managed copy")
        } else if !settings.keepAliveAutoEnabled, KeepAlive.isAvailable, !KeepAlive.isEnabled,
                  Bundle.main.bundlePath.hasPrefix("/Applications/") {
            // First run from /Applications: this is a forwarder meant to run unattended, so
            // supervision defaults to on. Done once; turning it off in Settings sticks.
            settings.keepAliveAutoEnabled = true
            keepAlive = true
            log("first run from /Applications — enabled run-at-login & crash restart automatically")
        }
    }

    // MARK: - Modem registry (called by ModemManager on the main actor)

    func addModem(_ modem: Modem) {
        guard !modems.contains(where: { $0.id == modem.id }) else { return }
        if settings.modems[modem.id] == nil {
            settings.updateModem(modem.id) { _ in }
        }
        modems.append(modem)
        modems.sort { $0.id < $1.id }
        updatePowerAssertion()
        if settingsModemID == modem.id { refreshPage() }
    }

    func settings(for modem: Modem) -> ModemSettings { settings.modem(modem.id) }

    func settings(forIMEI imei: String) -> ModemSettings { settings.modem(imei) }

    func removeModem(id: String) {
        modems.removeAll { $0.id == id }
        updatePowerAssertion()
    }

    func modem(id: String) -> Modem? { modems.first { $0.id == id } }
    func modem(routeKey: String) -> Modem? { modems.first { $0.matches(routeKey: routeKey) } }

    /// Manual MSISDN when the stick cannot read EF_MSISDN (typical on Air780). Keyed by ICCID.
    func setSIMNumber(_ raw: String, for modem: Modem) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String?
        if trimmed.isEmpty {
            normalized = nil
        } else {
            normalized = PDUEncoder.normalizeNumber(trimmed) ?? trimmed
        }
        modem.sim.number = normalized
        guard let iccid = modem.sim.iccid, !iccid.isEmpty else {
            log("modem …\(modem.id.suffix(6)) SIM number \(normalized ?? "cleared") (session only — no ICCID yet)")
            return
        }
        var s = settings
        if let normalized {
            s.msisdnByICCID[iccid] = normalized
        } else {
            s.msisdnByICCID.removeValue(forKey: iccid)
        }
        settings = s
        log("modem …\(modem.id.suffix(6)) SIM number \(normalized ?? "cleared") for ICCID …\(iccid.suffix(4))")
    }

    /// The modem used for outgoing SMS that aren't a reply (composer, /sms) — prefer one
    /// with a fresh SMS-capable registration, then any network-registered modem.
    var primaryModem: Modem? {
        modems.first { $0.isSMSReady } ?? modems.first { $0.isRegistered } ?? modems.first
    }

    // MARK: - Aggregate status (menu bar / header)

    var anyConnected: Bool { modems.contains { $0.connection.isConnected } }
    var anyRegistered: Bool { modems.contains { $0.isRegistered } }
    var bestSignal: SignalQuality {
        modems.filter { $0.isRegistered }.map(\.signal).max { $0.fraction < $1.fraction } ?? .unknown
    }

    // MARK: - Power

    func updatePowerAssertion() {
        if settings.preventSystemSleep && anyConnected {
            if !powerAssertion.isHeld {
                powerAssertion.hold(reason: "\(AppInfo.displayName) is receiving SMS from the attached modem(s)")
                log("holding power assertion (no idle sleep while a modem is connected)")
            }
        } else if powerAssertion.isHeld {
            powerAssertion.release()
            log("released power assertion")
        }
    }

    var isPreventingSleep: Bool { powerAssertion.isHeld }

    // MARK: - Messages

    func refreshPage() {
        do {
            page = try store.page(index: pageIndex, size: settings.pageSize, search: search,
                                  routeKeys: inboxRouteKeys)
            pageIndex = page.pageIndex
            counts = try store.counts(routeKeys: inboxRouteKeys)
        } catch {
            log("page load failed: \(error.localizedDescription)")
        }
    }

    func nextPage() {
        guard page.hasNext else { return }
        pageIndex += 1
        refreshPage()
    }

    func previousPage() {
        guard page.hasPrevious else { return }
        pageIndex -= 1
        refreshPage()
    }

    /// Store a decoded PDU received by `modem`, forward it if enabled, wake the sender.
    func ingest(pdu: String, status: Int, from modem: Modem) {
        let decoded: SMSDeliver
        do {
            decoded = try PDUDecoder.decode(hex: pdu)
        } catch {
            // Never lose data and never re-list the same slot forever: keep the raw hex.
            log("PDU not decodable (\(error.localizedDescription)) — storing raw")
            decoded = SMSDeliver(smsc: nil, sender: "unknown", protocolID: 0, encoding: .data8bit, timestamp: nil,
                                 timezoneOffset: nil, concat: nil, text: "[raw PDU] \(pdu)", hasUserDataHeader: false)
        }
        let incoming = IncomingSMS(
            pdu: pdu, decoded: decoded, simNumber: modem.routeKey,
            simDisplay: modem.sim.number ?? modem.label
        )
        do {
            switch try store.ingest(incoming, forwardingEnabled: settings(for: modem).forwardingEnabled) {
            case .stored(let msg):
                log("SMS to \(modem.label) from \(msg.sender): \(msg.body.prefix(60))")
                refreshPage()
                forwardingService?.kick()
            case .partStored(let missing):
                log("multipart fragment from \(decoded.sender) on \(modem.label), waiting on \(missing) more")
            case .duplicate:
                break
            }
        } catch {
            log("store failed: \(error.localizedDescription)")
        }
    }

    func forwardNow(_ message: StoredMessage) {
        do {
            try store.requeue(id: message.id)
            refreshPage()
            if message.isOutgoing { modemManager?.kickOutgoing() } else { forwardingService?.kick() }
        } catch { log("requeue failed: \(error.localizedDescription)") }
    }

    /// Queue an SMS from the app itself (composer). `via` selects the sending modem; default = primary.
    func sendSMS(to number: String, text: String, via modem: Modem? = nil) throws {
        guard let normalized = PDUEncoder.normalizeNumber(number) else { throw PDUEncoder.EncodeError.invalidNumber(number) }
        let sender = modem ?? primaryModem
        _ = try store.enqueueOutgoing(to: normalized, body: text, simNumber: sender?.routeKey, telegramRequestID: nil)
        refreshPage()
        modemManager?.kickOutgoing()
    }

    /// First failure of an outgoing SMS: tell the requester it's being retried instead of going silent.
    func notifyOutgoingRetrying(_ message: StoredMessage, error: Error, in delay: TimeInterval) async {
        guard message.telegramRequestID != nil, let tg = telegramTarget(for: message) else { return }
        let client = TelegramClient(token: tg.token)
        let reason = TelegramClient.escapeHTML(error.localizedDescription.replacingOccurrences(of: "AT+CMGS → ", with: ""))
        let html = "⏳ No acknowledgement from the SMS network (\(reason)) — retrying in \(Int(delay)) s. The same stored SMS will be reused, but a carrier-side duplicate is still possible."
        _ = try? await client.sendMessage(chatID: tg.chatID, html: html, replyTo: message.telegramRequestID)
    }

    /// Posts the outcome of an outgoing SMS back to the Telegram message that asked for it.
    func notifyOutgoing(_ message: StoredMessage, result: Result<Int, Error>) async {
        guard let tg = telegramTarget(for: message) else { return }
        let client = TelegramClient(token: tg.token)
        let number = TelegramClient.escapeHTML(message.sender)
        let html: String
        switch result {
        case .success(let parts):
            html = "✅ Sent to <b>\(number)</b>" + (parts > 1 ? " · \(parts) parts" : "")
        case .failure(let error):
            html = "❌ Could not send to <b>\(number)</b>: \(TelegramClient.escapeHTML(error.localizedDescription))"
        }
        do {
            try await client.sendMessage(chatID: tg.chatID, html: html, replyTo: message.telegramRequestID)
        } catch {
            log("telegram ack failed: \(error.localizedDescription)")
        }
    }

    func telegramTarget(for message: StoredMessage) -> (token: String, chatID: String)? {
        if let modem = modem(routeKey: message.simNumber ?? "") {
            let s = settings(for: modem)
            guard s.telegramConfigured else { return nil }
            return (s.telegramBotToken, s.telegramChatID)
        }
        return settings.modems.values.first { $0.telegramConfigured }.map {
            ($0.telegramBotToken, $0.telegramChatID)
        }
    }

    func delete(_ message: StoredMessage) {
        do {
            try store.delete(id: message.id)
            refreshPage()
        } catch { log("delete failed: \(error.localizedDescription)") }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func resetUSB(_ modem: Modem? = nil) async {
        usbResetBusy = true
        defer { usbResetBusy = false }
        await modemManager?.resetUSB(modem, reason: "requested from Diagnostics")
    }

    func recheckNetworkGuard() async {
        await modemManager?.enforceNetworkGuard()
    }

    // MARK: - Telegram helpers

    func testTelegram(imei: String) async {
        let s = settings.modem(imei)
        telegramBusy = true
        defer { telegramBusy = false }
        let client = TelegramClient(token: s.telegramBotToken)
        do {
            let me = try await client.getMe()
            telegramBot = me
            let who = modem(id: imei)?.label ?? "this modem"
            try await client.sendMessage(chatID: s.telegramChatID,
                                         html: "✅ \(AppInfo.displayName) connected. Forwarding SMS for <b>\(TelegramClient.escapeHTML(who))</b>.")
            telegramStatus = "Test message sent via @\(me.username)"
        } catch {
            telegramStatus = "Failed: \(error.localizedDescription)"
        }
        log("telegram test (\(imei.suffix(4))): \(telegramStatus ?? "")")
    }

    func detectChats(imei: String) async {
        let s = settings.modem(imei)
        telegramBusy = true
        defer { telegramBusy = false }
        let client = TelegramClient(token: s.telegramBotToken)
        do {
            let me = try await client.getMe()
            telegramBot = me
            chatCandidates = try await client.recentChats()
            telegramStatus = chatCandidates.isEmpty
                ? "No chats yet — send any message to @\(me.username) first, then retry."
                : "Found \(chatCandidates.count) chat(s)"
        } catch {
            telegramStatus = "Failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Keep alive (launchd)

    var canManageKeepAlive: Bool { KeepAlive.isAvailable }

    var keepAlive: Bool {
        get { KeepAlive.isEnabled }
        set {
            do {
                if newValue {
                    try KeepAlive.enable()
                    log("keep-alive enabled — launchd will supervise the app")
                } else {
                    try KeepAlive.disable()
                    log("keep-alive disabled")
                }
            } catch {
                log("keep-alive: \(error.localizedDescription)")
                lastError = error.localizedDescription
            }
            keepAliveStatus = KeepAlive.statusText
        }
    }

    func refreshKeepAliveStatus() {
        keepAliveStatus = KeepAlive.statusText
    }

    // MARK: - Log

    func log(_ text: String, modemID: String? = nil) {
        logEntries.append(LogEntry(date: Date(), text: text, modemID: modemID))
        if logEntries.count > 300 { logEntries.removeFirst(logEntries.count - 300) }
        fileLog?.write(text)
        #if DEBUG
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        FileHandle.standardError.write(Data("[\(df.string(from: Date()))] \(text)\n".utf8))
        #endif
    }

    var visibleLogEntries: [LogEntry] {
        if settingsModemID == "app" {
            return logEntries.filter { $0.modemID == nil && !Self.logTextIsModemScoped($0.text) }
        }
        let id = settingsModemID
        let tag6 = "…" + id.suffix(6)
        let tag4 = "(" + id.suffix(4) + ")"
        return logEntries.filter { e in
            if e.modemID == id { return true }
            if e.text.contains(tag6) { return true }
            if e.text.contains(tag4) { return true }
            return false
        }
    }

    private static func logTextIsModemScoped(_ text: String) -> Bool {
        text.contains("modem …") || text.contains("USB re-enumerated modem")
    }
}
