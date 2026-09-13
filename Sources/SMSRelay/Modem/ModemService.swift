import Foundation
import SMSRelayCore

enum ModemError: Error, LocalizedError {
    case disconnected
    case identityChanged

    var errorDescription: String? {
        switch self {
        case .disconnected: return "Modem disconnected"
        case .identityChanged: return "Port now belongs to a different modem"
        }
    }
}

/// Owns one modem's connection for as long as its port exists: connect → configure → drain
/// stored SMS → live (URCs + heartbeat + sweep + outgoing) → reconnect. When the port disappears
/// it ends and `ModemManager` reaps it. All state is written into its `Modem`.
@MainActor
final class ModemService {
    private unowned let app: AppModel
    let modem: Modem

    private var runTask: Task<Void, Never>?
    private var channel: ATChannel?
    private var currentMemory = "SM"
    private(set) var hasEnded = false

    private var silentPortsSince: Date?
    private var lastUSBReset: Date?
    private var unregisteredSince: Date?
    private var lastRadioKick: Date?
    private var lastAttachRequest: Date?
    private var disconnectedSince: Date?
    private var downAlertSent = false
    private var registrationAlertSent = false
    private var busyRounds = 0
    private var outgoingSleeper: Task<Void, Never>?

    private let heartbeatInterval: Duration = .seconds(10)
    private let stalePartAge: TimeInterval = 10 * 60
    private let zombieTimeout: TimeInterval = 45
    private let usbResetCooldown: TimeInterval = 120
    private let attachTimeout: TimeInterval = 30
    private let attachCooldown: TimeInterval = 120
    private let registrationTimeout: TimeInterval = 5 * 60
    private let radioKickCooldown: TimeInterval = 10 * 60
    private let downAlertDelay: TimeInterval = 90

    var port: String { modem.port }

    init(app: AppModel, modem: Modem) {
        self.app = app
        self.modem = modem
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { await runLoop() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        let ch = channel
        Task { await ch?.close() }
    }

    func kickOutgoing() { outgoingSleeper?.cancel() }

    /// Software unplug/replug of just this modem's USB device.
    func resetUSBDevice(reason: String) async {
        let ch = channel
        await ch?.close()
        lastUSBReset = Date()
        silentPortsSince = nil
        do {
            let path = modem.port
            let ok = try await Task.detached { try USBReset.reenumerateDevice(forCalloutPath: path) }.value
            if ok {
                modem.usbResets += 1
                app.log("USB re-enumerated modem …\(modem.id.suffix(6)) — \(reason)")
            } else {
                app.log("USB reset: could not locate device for \(modem.portShortName)")
            }
        } catch {
            app.log("USB reset failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Main loop

    private func runLoop() async {
        while !Task.isCancelled {
            guard FileManager.default.fileExists(atPath: modem.port) else { break }
            setConnection(.connecting(modem.port))
            modem.consecutiveHeartbeatMisses = 0

            guard let ch = await openControl() else {
                await detectZombie()
                guard FileManager.default.fileExists(atPath: modem.port) else { break }
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            channel = ch
            silentPortsSince = nil

            do {
                try await verifyIdentity(ch)
                try await configure(ch)
                setConnection(.connected(port: modem.port, since: Date()))
                modem.lastError = nil
                app.log("modem …\(modem.id.suffix(6)) connected on \(modem.portShortName)")
                if downAlertSent {
                    let mins = disconnectedSince.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
                    app.alerter?.send(.modemUp, modem, "✅ Modem is back after \(mins) min.", force: true)
                    downAlertSent = false
                }
                disconnectedSince = nil
                try await refreshStatus(ch)
                try await sweepStoredMessages(ch)

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.consumeURCs(ch) }
                    group.addTask { try await self.heartbeatLoop(ch) }
                    group.addTask { try await self.sweepLoop(ch) }
                    group.addTask { try await self.outgoingLoop(ch) }
                    try await group.next()
                    group.cancelAll()
                }
            } catch ModemError.identityChanged {
                app.log("port \(modem.portShortName) now reports a different modem — releasing")
                await ch.close()
                break
            } catch {
                modem.lastError = error.localizedDescription
                app.log("modem …\(modem.id.suffix(6)) connection lost: \(error.localizedDescription)")
            }

            await ch.close()
            channel = nil
            modem.reconnects += 1
            setConnection(.disconnected(reason: modem.lastError ?? "Disconnected"))
            modem.signal = .unknown
            modem.registration = nil
            unregisteredSince = nil
            if disconnectedSince == nil { disconnectedSince = Date() }
            checkDownAlert()
            guard FileManager.default.fileExists(atPath: modem.port) else { break }
            try? await Task.sleep(for: .seconds(2))
        }
        hasEnded = true
        setConnection(.disconnected(reason: "removed"))
    }

    private func setConnection(_ state: ConnectionState) {
        modem.connection = state
        app.updatePowerAssertion()
    }

    private func openControl() async -> ATChannel? {
        let ch: ATChannel
        do {
            ch = try ATChannel(path: modem.port)
        } catch SerialError.open(_, let errno_) where errno_ == EBUSY && busyRounds < 5 {
            busyRounds += 1
            app.log("\(modem.portShortName) is busy — waiting (\(busyRounds)/5)")
            return nil
        } catch {
            return nil
        }
        busyRounds = 0
        await ch.start()
        #if DEBUG
        await ch.setLogger { line in
            FileHandle.standardError.write(Data("    [\(modem_suffix(self.modem.id))] \(line)\n".utf8))
        }
        #endif
        await ch.abortPrompt()
        _ = try? await ch.send("AT", timeout: .milliseconds(800))
        guard let ok = try? await ch.send("AT", timeout: .seconds(1)), ok.isOK else {
            await ch.close()
            return nil
        }
        return ch
    }

    private func verifyIdentity(_ ch: ATChannel) async throws {
        _ = try? await ch.send("ATE0", timeout: .seconds(1))
        guard let imei = (try? await ch.send("AT+CGSN", timeout: .seconds(2)))?.informationText
            .trimmingCharacters(in: .whitespacesAndNewlines), !imei.isEmpty else { return }
        if imei != modem.id { throw ModemError.identityChanged }
    }

    // MARK: - Watchdogs

    private func checkDownAlert() {
        if disconnectedSince == nil { disconnectedSince = Date() }
        guard !downAlertSent, let since = disconnectedSince, Date().timeIntervalSince(since) >= downAlertDelay else { return }
        downAlertSent = true
        app.alerter?.send(.modemDown, modem, "⚠️ Modem disconnected — no SMS can be received. \(modem.lastError ?? "")")
    }

    private func registrationWatchdog(_ ch: ATChannel) async {
        guard let reg = modem.registration else { return }
        if reg.isRegistered {
            if registrationAlertSent {
                app.alerter?.send(.registrationBack, modem, "✅ Network registration restored (\(modem.operatorName)).", force: true)
                registrationAlertSent = false
            }
            unregisteredSince = nil
            lastAttachRequest = nil
            return
        }
        let since = unregisteredSince ?? Date()
        unregisteredSince = since
        let elapsed = Date().timeIntervalSince(since)

        if elapsed >= attachTimeout, lastAttachRequest.map({ Date().timeIntervalSince($0) >= attachCooldown }) ?? true {
            lastAttachRequest = Date()
            app.log("modem …\(modem.id.suffix(6)) not registered for \(Int(elapsed))s — requesting attach (AT+CGATT=1)")
            _ = try? await ch.send("AT+CGATT=1", timeout: .seconds(30))
            return
        }
        guard elapsed >= registrationTimeout else { return }
        if !registrationAlertSent {
            registrationAlertSent = true
            app.alerter?.send(.registrationLost, modem, "⚠️ Modem has had no network for \(Int(elapsed / 60)) min (\(reg.statusText)). Kicking the radio.")
        }
        if let last = lastRadioKick, Date().timeIntervalSince(last) < radioKickCooldown { return }
        lastRadioKick = Date()
        app.log("modem …\(modem.id.suffix(6)) no registration for \(Int(elapsed))s — toggling radio")
        _ = try? await ch.send("AT+CFUN=4", timeout: .seconds(15))
        try? await Task.sleep(for: .seconds(3))
        _ = try? await ch.send("AT+CFUN=1", timeout: .seconds(15))
    }

    private func detectZombie() async {
        guard FileManager.default.fileExists(atPath: modem.port) else {
            silentPortsSince = nil
            return
        }
        let since = silentPortsSince ?? Date()
        silentPortsSince = since
        guard Date().timeIntervalSince(since) >= zombieTimeout else { return }
        if let last = lastUSBReset, Date().timeIntervalSince(last) < usbResetCooldown { return }
        app.log("modem …\(modem.id.suffix(6)) port present but silent for \(Int(Date().timeIntervalSince(since)))s — resetting USB")
        await resetUSBDevice(reason: "modem unresponsive")
    }

    // MARK: - Configuration

    private func configure(_ ch: ATChannel) async throws {
        try await ch.sendOK("ATE0")
        try await ch.sendOK("AT+CMEE=2")

        if let cfun = try? await ch.send("AT+CFUN?"), cfun.value(for: "+CFUN:") != "1" {
            app.log("modem …\(modem.id.suffix(6)) radio was off — turning on")
            _ = try? await ch.send("AT+CFUN=1", timeout: .seconds(15))
        }

        let pin = try await ch.send("AT+CPIN?")
        modem.sim.status = pin.value(for: "+CPIN:") ?? (pin.isOK ? "Unknown" : pin.final)

        modem.info.model = (try? await ch.send("AT+CGMM"))?.informationText
        modem.info.firmware = (try? await ch.send("AT+CGMR"))?.informationText
        modem.info.imei = modem.id

        if modem.sim.isReady {
            modem.sim.imsi = (try? await ch.send("AT+CIMI"))?.informationText
            modem.sim.iccid = (try? await ch.send("AT+MCCID"))?.value(for: "+MCCID:")
            modem.sim.number = (try? await ch.send("AT+CNUM"))?.value(for: "+CNUM:").flatMap(ATParsers.cnum)
            modem.sim.smsc = (try? await ch.send("AT+CSCA?"))?.value(for: "+CSCA:").map { ATParsers.fields($0).first ?? $0 }
        }

        try await ch.sendOK("AT+CMGF=0")
        try await selectMemory(ch, "SM")
        try await ch.sendOK("AT+CNMI=2,1,0,0,0")
        _ = try? await ch.send("AT+CREG=2")
        _ = try? await ch.send("AT+CEREG=2")
        _ = try? await ch.send("AT+MLPMCFG=\"sleepmode\",0,0")

        await disableModemData(ch)
        await applyNetworkLED(ch)
    }

    private func applyNetworkLED(_ ch: ATChannel) async {
        let on = app.settings.networkLED
        if let r = try? await ch.send("AT+MLED=0,\(on ? 1 : 0)"), !r.isOK {
            app.log("network LED not controllable: \(r.final)")
        }
    }

    func applyNetworkLED() {
        guard let ch = channel else { return }
        Task { await applyNetworkLED(ch) }
    }

    /// Keep the modem off the Mac's internet: disable host ECM auto-dialup; keep the module's
    /// own auto-attach ON (autoconn=0 stops the LTE attach on this firmware).
    private func disableModemData(_ ch: ATChannel) async {
        func flag(_ resp: ATResponse?, _ prefix: String) -> Bool? {
            guard let v = resp?.value(for: prefix) else { return nil }
            let f = ATParsers.fields(v)
            return f.count >= 2 ? (Int(f[1]).map { $0 != 0 }) : nil
        }

        let auto = flag(try? await ch.send("AT+MDIALUPCFG=\"auto\""), "+MDIALUPCFG:")
        let autoconn = flag(try? await ch.send("AT+MUECONFIG=\"autoconn\""), "+MUECONFIG:")
        modem.modemAutoDial = auto

        if let dial = try? await ch.send("AT+MDIALUP?"), dial.values(for: "+MDIALUP:").contains(where: { ATParsers.fields($0).count > 2 }) {
            _ = try? await ch.send("AT+MDIALUP=1,0", timeout: .seconds(10))
            app.log("modem …\(modem.id.suffix(6)) data session was active — disconnected")
        }

        if auto == true {
            let r = try? await ch.send("AT+MDIALUPCFG=\"auto\",0")
            if r?.isOK == true {
                modem.modemAutoDial = false
                app.log("modem …\(modem.id.suffix(6)) disabled host auto-dialup (persistent)")
            }
        }
        if autoconn == false {
            _ = try? await ch.send("AT+MUECONFIG=\"autoconn\",1")
            app.log("modem …\(modem.id.suffix(6)) re-enabled auto-attach (autoconn=1)")
        }
    }

    private func selectMemory(_ ch: ATChannel, _ mem: String) async throws {
        let r = try await ch.sendOK("AT+CPMS=\"\(mem)\",\"\(mem)\",\"\(mem)\"")
        currentMemory = mem
        if mem == "SM", let v = r.value(for: "+CPMS:"), let usage = ATParsers.cpms(v) {
            modem.storageUsed = usage.used
            modem.storageTotal = usage.total
        }
    }

    // MARK: - Status / heartbeat

    private func refreshStatus(_ ch: ATChannel) async throws {
        let started = Date()
        let csq = try await ch.send("AT+CSQ", timeout: .seconds(4))
        guard csq.isOK else { throw ATError.failure(command: "AT+CSQ", result: csq.final) }
        modem.heartbeatRTT = Date().timeIntervalSince(started)
        modem.lastHeartbeat = Date()
        modem.consecutiveHeartbeatMisses = 0

        let cesq = (try? await ch.send("AT+CESQ"))?.value(for: "+CESQ:").flatMap(ATParsers.cesq)
        if let v = csq.value(for: "+CSQ:"), let parsed = ATParsers.csq(v) {
            modem.signal = SignalQuality(csq: parsed.rssi, cesq: cesq)
        }
        if let v = (try? await ch.send("AT+CEREG?"))?.value(for: "+CEREG:"),
           let reg = ATParsers.registration(v, isURC: false) {
            modem.registration = reg
        } else if let v = (try? await ch.send("AT+CREG?"))?.value(for: "+CREG:"),
                  let reg = ATParsers.registration(v, isURC: false) {
            modem.registration = reg
        }
        if let v = (try? await ch.send("AT+COPS?"))?.value(for: "+COPS:"), let cops = ATParsers.cops(v) {
            modem.operatorCode = cops.operatorCode
            modem.accessTechnology = cops.accessTechnology
        }
        if modem.sim.number == nil, modem.sim.isReady {
            modem.sim.number = (try? await ch.send("AT+CNUM"))?.value(for: "+CNUM:").flatMap(ATParsers.cnum)
        }
    }

    private func heartbeatLoop(_ ch: ATChannel) async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: heartbeatInterval)
            guard FileManager.default.fileExists(atPath: modem.port) else { throw ModemError.disconnected }
            do {
                try await refreshStatus(ch)
                await registrationWatchdog(ch)
            } catch ATError.portClosed {
                throw ModemError.disconnected
            } catch {
                modem.consecutiveHeartbeatMisses += 1
                app.log("modem …\(modem.id.suffix(6)) heartbeat miss #\(modem.consecutiveHeartbeatMisses): \(error.localizedDescription)")
                if modem.consecutiveHeartbeatMisses >= 3 { throw ModemError.disconnected }
            }
        }
    }

    // MARK: - URCs

    private func consumeURCs(_ ch: ATChannel) async throws {
        for await line in ch.urcs {
            if line.hasPrefix("+CMTI:") {
                if let (mem, idx) = ATParsers.cmti(String(line.dropFirst(6))) {
                    await readAndStore(ch, memory: mem, index: idx)
                }
            } else if line.hasPrefix("+CEREG:") || line.hasPrefix("+CREG:") {
                let body = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                if let reg = ATParsers.registration(body, isURC: true) {
                    modem.registration = reg
                    app.log("modem …\(modem.id.suffix(6)) registration → \(reg.statusText) \(ATParsers.accessTechnologyName(reg.accessTechnology))")
                }
            } else if line.hasPrefix("+CPIN:") {
                modem.sim.status = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else {
                app.log("URC [\(modem.label)] \(line)")
            }
        }
        throw ModemError.disconnected
    }

    // MARK: - Reading / storing

    private func ensurePDUMode(_ ch: ATChannel) async throws {
        try await ch.sendOK("AT+CMGF=0")
    }

    private func claimNotifications(_ ch: ATChannel) async {
        _ = try? await ch.send("AT+CNMI=2,1,0,0,0")
    }

    private func readAndStore(_ ch: ATChannel, memory: String, index: Int) async {
        do {
            try await ensurePDUMode(ch)
            if memory != currentMemory { try await selectMemory(ch, memory) }
            let r = try await ch.send("AT+CMGR=\(index)", timeout: .seconds(8))
            guard r.isOK else {
                app.log("CMGR \(index) failed: \(r.final)")
                return
            }
            let entries = ATParsers.pduEntries(from: r, listing: false)
            for entry in entries {
                app.ingest(pdu: entry.pdu, status: entry.status, from: modem)
            }
            if app.settings.deleteFromSIM, !entries.isEmpty {
                _ = try? await ch.send("AT+CMGD=\(index)")
            }
            if memory != "SM" { try await selectMemory(ch, "SM") } else { await updateStorage(ch) }
        } catch {
            app.log("read \(memory)/\(index) failed: \(error.localizedDescription)")
        }
    }

    private func sweepStoredMessages(_ ch: ATChannel) async throws {
        await claimNotifications(ch)
        for mem in ["SM", "ME"] {
            try await ensurePDUMode(ch)
            do { try await selectMemory(ch, mem) } catch { continue }
            let r = try await ch.send("AT+CMGL=4", timeout: .seconds(20))
            guard r.isOK else {
                app.log("CMGL on \(mem) failed: \(r.final)")
                continue
            }
            for entry in ATParsers.pduEntries(from: r, listing: true) {
                guard entry.status == 0 || entry.status == 1 else { continue }
                app.ingest(pdu: entry.pdu, status: entry.status, from: modem)
                if app.settings.deleteFromSIM, let idx = entry.index {
                    _ = try? await ch.send("AT+CMGD=\(idx)")
                }
            }
        }
        try await selectMemory(ch, "SM")
    }

    private func sweepLoop(_ ch: ATChannel) async throws {
        while !Task.isCancelled {
            let interval = max(5, app.settings.pollIntervalSeconds)
            try await Task.sleep(for: .seconds(interval))
            try await sweepStoredMessages(ch)
            let flushed = try app.store.flushStaleParts(olderThan: stalePartAge, forwardingEnabled: app.settings.forwardingEnabled)
            if !flushed.isEmpty {
                app.log("flushed \(flushed.count) incomplete multipart message(s)")
                app.refreshPage()
                app.forwardingService?.kick()
            }
        }
    }

    private func updateStorage(_ ch: ATChannel) async {
        if let v = (try? await ch.send("AT+CPMS?"))?.value(for: "+CPMS:"), let usage = ATParsers.cpms(v) {
            modem.storageUsed = usage.used
            modem.storageTotal = usage.total
        }
    }

    // MARK: - Outgoing SMS

    private func outgoingLoop(_ ch: ATChannel) async throws {
        while !Task.isCancelled {
            await processOutgoing(ch)
            let s = Task<Void, Never> { try? await Task.sleep(for: .seconds(5)) }
            outgoingSleeper = s
            await s.value
            try Task.checkCancellation()
        }
    }

    private func processOutgoing(_ ch: ATChannel) async {
        guard modem.isRegistered else { return }  // wait for the network
        // The primary modem also picks up messages with no explicit route (composer / older rows).
        let isPrimary = app.primaryModem?.id == modem.id
        guard let due = try? app.store.dueOutgoing(routeKey: modem.routeKey, limit: 5, includeUntargeted: isPrimary), !due.isEmpty else { return }
        for msg in due {
            do {
                let parts = try await sendSMS(ch, to: msg.sender, text: msg.body)
                try app.store.markOutgoingSent(id: msg.id, parts: parts)
                app.log("modem …\(modem.id.suffix(6)) sent SMS to \(msg.sender) (\(parts) part\(parts == 1 ? "" : "s"))")
                await app.notifyOutgoing(msg, result: .success(parts))
            } catch {
                let attempts = msg.forwardAttempts + 1
                let permanent = error is PDUEncoder.EncodeError || Self.isPermanentSendError(error)
                let gaveUp = permanent || attempts >= 5
                let delay: TimeInterval = Self.isNetworkTimeout(error) ? 20 : 60
                try? app.store.markFailed(id: msg.id, error: error.localizedDescription,
                                          nextAttempt: gaveUp ? nil : Date().addingTimeInterval(delay), gaveUp: gaveUp)
                app.log("send to \(msg.sender) failed (attempt \(attempts)\(gaveUp ? ", giving up" : "")): \(error.localizedDescription)")
                if gaveUp {
                    await app.notifyOutgoing(msg, result: .failure(error))
                } else if attempts == 1 {
                    await app.notifyOutgoingRetrying(msg, error: error, in: delay)
                }
            }
            app.refreshPage()
        }
    }

    private func sendSMS(_ ch: ATChannel, to number: String, text: String) async throws -> Int {
        let parts = try PDUEncoder.encodeSubmit(to: number, text: text)
        try await ensurePDUMode(ch)
        for part in parts {
            do {
                let r = try await ch.sendWithPrompt("AT+CMGS=\(part.tpduLength)", payload: Data(part.hex.utf8),
                                                    promptTimeout: .seconds(10), timeout: .seconds(60))
                guard r.isOK else { throw ATError.failure(command: "AT+CMGS", result: r.final) }
            } catch {
                await ch.abortPrompt()
                throw error
            }
        }
        return parts.count
    }

    private static func cmsErrorCode(_ error: Error) -> Int? {
        guard case ATError.failure(_, let result) = error, result.hasPrefix("+CMS ERROR") else { return nil }
        return Int(result.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    private static func isPermanentSendError(_ error: Error) -> Bool {
        guard let code = cmsErrorCode(error) else { return false }
        return (301...305).contains(code) || code == 21
    }

    private static func isNetworkTimeout(_ error: Error) -> Bool {
        guard let code = cmsErrorCode(error) else { return false }
        return code == 331 || code == 332
    }
}

/// Last 6 of the IMEI, for compact log tags.
private func modem_suffix(_ imei: String) -> String { String(imei.suffix(6)) }
