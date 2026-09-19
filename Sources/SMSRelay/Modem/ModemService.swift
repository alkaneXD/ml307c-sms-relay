import Foundation
import SMSRelayCore

enum ModemError: Error, LocalizedError {
    case disconnected
    case identityChanged
    case outgoingClaimLost
    case deliveryFailed(status: UInt8)

    var errorDescription: String? {
        switch self {
        case .disconnected: return "Modem disconnected"
        case .identityChanged: return "Port now belongs to a different modem"
        case .outgoingClaimLost: return "Outgoing SMS queue lease was lost"
        case .deliveryFailed(let status): return "SMS network reported delivery failure (status \(status))"
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
    private let outgoingClaimOwner: String

    private var runTask: Task<Void, Never>?
    private var channel: ATChannel?
    private var currentMemory = "SM"
    private(set) var hasEnded = false

    private var silentPortsSince: Date?
    private var lastUSBReset: Date?
    private var unregisteredSince: Date?
    private var lastRadioKick: Date?
    private var lastAttachRequest: Date?
    private var lastNoSignalBlink: Date?
    private var disconnectedSince: Date?
    private var downAlertSent = false
    private var registrationAlertSent = false
    private var busyRounds = 0
    private var outgoingSleeper: Task<Void, Never>?
    private var supportsCIREG = false
    private var supportsCASIMS = false
    private var smsMessageService = 0
    private var statusReportsEnabled = false
    private var loggedTPMRRewrite = false

    private let heartbeatInterval: Duration = .seconds(10)
    private let stalePartAge: TimeInterval = 10 * 60
    private let zombieTimeout: TimeInterval = 45
    private let usbResetCooldown: TimeInterval = 120
    private let attachTimeout: TimeInterval = 30
    private let attachCooldown: TimeInterval = 120
    private let registrationTimeout: TimeInterval = 5 * 60
    private let radioKickCooldown: TimeInterval = 10 * 60
    private let downAlertDelay: TimeInterval = 90
    private let fastSMSRetryDelay: Duration = .seconds(3)
    private let noSignalBlinkGrace: TimeInterval = 15
    private let noSignalBlinkCooldown: TimeInterval = 30
    private let noSignalBlinkOn: Duration = .milliseconds(100)
    private let noSignalBlinkOff: Duration = .milliseconds(80)

    var port: String { modem.port }

    private func log(_ text: String) {
        app.log(text, modemID: modem.id)
    }

    init(app: AppModel, modem: Modem) {
        self.app = app
        self.modem = modem
        outgoingClaimOwner = "\(modem.id)|\(UUID().uuidString)"
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
                log("USB re-enumerated modem …\(modem.id.suffix(6)) — \(reason)")
            } else {
                log("USB reset: could not locate device for \(modem.portShortName)")
            }
        } catch {
            log("USB reset failed: \(error.localizedDescription)")
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
                log("modem …\(modem.id.suffix(6)) connected on \(modem.portShortName)")
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
                log("port \(modem.portShortName) now reports a different modem — releasing")
                await ch.close()
                break
            } catch {
                modem.lastError = error.localizedDescription
                log("modem …\(modem.id.suffix(6)) connection lost: \(error.localizedDescription)")
            }

            await ch.close()
            channel = nil
            modem.reconnects += 1
            setConnection(.disconnected(reason: modem.lastError ?? "Disconnected"))
            modem.signal = .unknown
            modem.epsRegistration = nil
            modem.csRegistration = nil
            modem.imsRegistered = nil
            modem.imsSMSAvailable = nil
            modem.imsSMSConfigured = nil
            modem.registrationUpdatedAt = nil
            modem.smsReadySince = nil
            unregisteredSince = nil
            lastNoSignalBlink = nil
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
            log("\(modem.portShortName) is busy — waiting (\(busyRounds)/5)")
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
        let first = try? await ch.send("AT", timeout: .seconds(2))
        let ok = first?.isOK == true ? first : try? await ch.send("AT", timeout: .seconds(2))
        guard let ok, ok.isOK else {
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
        if modem.isRegistered {
            if registrationAlertSent {
                app.alerter?.send(.registrationBack, modem, "✅ Network registration restored (\(modem.operatorName)).", force: true)
                registrationAlertSent = false
            }
            unregisteredSince = nil
            lastAttachRequest = nil
            lastNoSignalBlink = nil
            return
        }
        let since = unregisteredSince ?? Date()
        unregisteredSince = since
        let elapsed = Date().timeIntervalSince(since)

        if elapsed >= attachTimeout, lastAttachRequest.map({ Date().timeIntervalSince($0) >= attachCooldown }) ?? true {
            lastAttachRequest = Date()
            log("modem …\(modem.id.suffix(6)) not registered for \(Int(elapsed))s — requesting attach (AT+CGATT=1)")
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
        log("modem …\(modem.id.suffix(6)) no registration for \(Int(elapsed))s — toggling radio")
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
        log("modem …\(modem.id.suffix(6)) port present but silent for \(Int(Date().timeIntervalSince(since)))s — resetting USB")
        await resetUSBDevice(reason: "modem unresponsive")
    }

    // MARK: - Configuration

    private func configure(_ ch: ATChannel) async throws {
        try await ch.sendOK("ATE0")
        try await ch.sendOK("AT+CMEE=2")

        if let cfun = try? await ch.send("AT+CFUN?"), cfun.value(for: "+CFUN:") != "1" {
            log("modem …\(modem.id.suffix(6)) radio was off — turning on")
            _ = try? await ch.send("AT+CFUN=1", timeout: .seconds(15))
        }

        let pin = try await ch.send("AT+CPIN?")
        modem.sim.status = pin.value(for: "+CPIN:") ?? (pin.isOK ? "Unknown" : pin.final)

        let ati = try? await ch.send("ATI")
        modem.info.model = atIdentity(try? await ch.send("AT+CGMM"), prefixes: ["+CGMM:", "+GMM:"])
            ?? atiField(ati, name: "Model")
        modem.info.firmware = atIdentity(try? await ch.send("AT+CGMR"), prefixes: ["+CGMR:", "+GMR:"])
            ?? atiField(ati, name: "Revision")
        modem.info.imei = modem.id
        if app.settingsModemID == modem.id { app.refreshPage() }

        if modem.sim.isReady {
            let previousIMSI = modem.sim.imsi
            let previousICCID = modem.sim.iccid
            var imsi = (try? await ch.send("AT+CIMI"))?.informationText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var iccid = (try? await ch.send("AT+MCCID"))?.value(for: "+MCCID:").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if iccid?.isEmpty ?? true {
                iccid = (try? await ch.send("AT+CCID"))?.informationText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if iccid?.isEmpty ?? true, let iccidResp = try? await ch.send("AT+ICCID") {
                let tagged = iccidResp.value(for: "+ICCID:")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let raw = iccidResp.informationText.trimmingCharacters(in: .whitespacesAndNewlines)
                iccid = (tagged?.isEmpty == false ? tagged : nil) ?? (raw.isEmpty ? nil : raw)
            }
            var number = (try? await ch.send("AT+CNUM"))?.value(for: "+CNUM:")
                .flatMap(ATParsers.cnum)
            let smsc = (try? await ch.send("AT+CSCA?"))?.value(for: "+CSCA:")
                .map { ATParsers.fields($0).first ?? $0 }

            let identityChanged =
                (previousICCID != nil && iccid != nil && previousICCID != iccid)
                || (previousIMSI != nil && imsi?.isEmpty == false && previousIMSI != imsi)
            if identityChanged {
                log("modem …\(modem.id.suffix(6)) SIM identity changed; clearing old SMS route")
            } else {
                // If one immutable SIM identifier still matches, retain the other through a
                // transient query failure so canonical ICCID/IMSI routes remain aliases.
                if iccid?.isEmpty ?? true, let imsi, imsi == previousIMSI {
                    iccid = previousICCID
                }
                if imsi?.isEmpty ?? true, let iccid, iccid == previousICCID {
                    imsi = previousIMSI
                }
            }
            if let iccid, !iccid.isEmpty {
                if let number, !number.isEmpty {
                    if app.settings.msisdnByICCID[iccid] != number {
                        var s = app.settings
                        s.msisdnByICCID[iccid] = number
                        app.settings = s
                    }
                } else if let cached = app.settings.msisdnByICCID[iccid], !cached.isEmpty {
                    number = cached
                    log("modem …\(modem.id.suffix(6)) MSISDN not in CNUM; using last value for this ICCID")
                } else if !identityChanged, let existing = modem.sim.number, !existing.isEmpty {
                    number = existing
                    var s = app.settings
                    s.msisdnByICCID[iccid] = existing
                    app.settings = s
                }
            }
            // Number is ICCID-keyed. A SIM swap (new ICCID) must not keep the previous MSISDN.
            modem.sim.imsi = imsi?.isEmpty == false ? imsi : nil
            modem.sim.iccid = iccid?.isEmpty == false ? iccid : nil
            modem.sim.number = number
            modem.sim.smsc = smsc
            if modem.sim.iccid == nil, modem.sim.imsi == nil {
                modem.beginUnverifiedSIMSession()
                log("modem …\(modem.id.suffix(6)) SIM identity unavailable; retries are limited to this connection")
            }
        }

        try await ch.sendOK("AT+CMGF=0")
        try await selectMemory(ch, "SM")
        if (try? await ch.send("AT+CSMS=0", timeout: .seconds(3)))?.isOK == true {
            smsMessageService = 0
        } else if let value = (try? await ch.send("AT+CSMS?", timeout: .seconds(3)))?.value(for: "+CSMS:"),
                  let service = ATParsers.fields(value).first.flatMap(Int.init) {
            smsMessageService = service
        }
        if (try? await ch.send("AT+CNMI=2,1,0,1,0"))?.isOK == true {
            statusReportsEnabled = true
        } else {
            statusReportsEnabled = false
            try await ch.sendOK("AT+CNMI=2,1,0,0,0")
            log("modem …\(modem.id.suffix(6)) does not support direct SMS status reports")
        }
        _ = try? await ch.send("AT+CREG=2")
        _ = try? await ch.send("AT+CEREG=2")
        await probeSMSAvailability(ch)
        _ = try? await ch.send("AT+MLPMCFG=\"sleepmode\",0,0")

        await disableModemData(ch)
        await applyNetworkLED(ch)
    }

    /// Newer ML307 firmware may expose IMS registration/SMS availability. Probe once so
    /// unsupported commands do not add errors and latency to every heartbeat.
    private func probeSMSAvailability(_ ch: ATChannel) async {
        if let r = try? await ch.send("AT+CIREG?", timeout: .seconds(2)), r.isOK,
           let value = r.value(for: "+CIREG:") {
            supportsCIREG = true
            applyIMSRegistration(value, isURC: false)
            if (try? await ch.send("AT+CIREG=2", timeout: .seconds(2)))?.isOK != true {
                _ = try? await ch.send("AT+CIREG=1", timeout: .seconds(2))
            }
        }
        if let r = try? await ch.send("AT+CASIMS?", timeout: .seconds(2)), r.isOK,
           let value = r.value(for: "+CASIMS:"),
           let configured = ATParsers.fields(value).first.flatMap(Int.init) {
            supportsCASIMS = true
            modem.imsSMSConfigured = configured == 1
        }
        log("modem …\(modem.id.suffix(6)) SMS status: CIREG \(supportsCIREG ? "supported" : "unavailable"), CASIMS \(supportsCASIMS ? "supported" : "unavailable")")
    }

    private func applyIMSRegistration(_ value: String, isURC: Bool) {
        let fields = ATParsers.fields(value)
        let statusIndex = isURC ? 0 : 1
        guard fields.indices.contains(statusIndex), let status = Int(fields[statusIndex]) else { return }
        modem.imsRegistered = status == 1
        let capabilityIndex = statusIndex + 1
        if fields.indices.contains(capabilityIndex),
           let capabilities = Int(fields[capabilityIndex], radix: 16) {
            modem.imsSMSAvailable = status == 1 && (capabilities & 0x04) != 0
        } else {
            modem.imsSMSAvailable = nil
        }
    }

    private func applyNetworkLED(_ ch: ATChannel) async {
        let on = app.settings(for: modem).networkLED ? 1 : 0
        if let r = try? await ch.send("AT+MLED=0,\(on)"), r.isOK { return }
        if let r = try? await ch.send("AT+CNETLIGHT=\(on)"), r.isOK { return }
        log("network LED not controllable")
    }

    func applyNetworkLED() {
        guard let ch = channel else { return }
        Task { await applyNetworkLED(ch) }
    }

    /// CSQ 99 and not camped — the HDMI/port-power failure mode. Skip the first
    /// seconds after connect so a normal attach is not strobed.
    private func blinkNoSignalIfNeeded(_ ch: ATChannel) async {
        guard modem.connection.isConnected, !modem.isRegistered,
              modem.signal.rssiIndex == nil else { return }
        guard let since = modem.connection.connectedSince,
              Date().timeIntervalSince(since) >= noSignalBlinkGrace else { return }
        if let last = lastNoSignalBlink, Date().timeIntervalSince(last) < noSignalBlinkCooldown { return }
        lastNoSignalBlink = Date()
        log("modem …\(modem.id.suffix(6)) no signal — blinking NET LED 5×")
        for _ in 0..<5 {
            _ = try? await ch.send("AT+MLED=0,1", timeout: .seconds(1))
            _ = try? await ch.send("AT+CNETLIGHT=1", timeout: .seconds(1))
            try? await Task.sleep(for: noSignalBlinkOn)
            _ = try? await ch.send("AT+MLED=0,0", timeout: .seconds(1))
            _ = try? await ch.send("AT+CNETLIGHT=0", timeout: .seconds(1))
            try? await Task.sleep(for: noSignalBlinkOff)
        }
        await applyNetworkLED(ch)
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
            log("modem …\(modem.id.suffix(6)) data session was active — disconnected")
        }

        if auto == true {
            let r = try? await ch.send("AT+MDIALUPCFG=\"auto\",0")
            if r?.isOK == true {
                modem.modemAutoDial = false
                log("modem …\(modem.id.suffix(6)) disabled host auto-dialup (persistent)")
            }
        }
        if autoconn == false {
            _ = try? await ch.send("AT+MUECONFIG=\"autoconn\",1")
            log("modem …\(modem.id.suffix(6)) re-enabled auto-attach (autoconn=1)")
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
        let wasSMSReady = modem.isSMSReady
        let epsValue = (try? await ch.send("AT+CEREG?"))?.value(for: "+CEREG:")
        let eps = epsValue.flatMap { ATParsers.registration($0, isURC: false) }
        modem.epsRegistration = eps
        let csValue = (try? await ch.send("AT+CREG?"))?.value(for: "+CREG:")
        let cs = csValue.flatMap { ATParsers.registration($0, isURC: false) }
        modem.csRegistration = cs
        if supportsCIREG,
           let v = (try? await ch.send("AT+CIREG?", timeout: .seconds(2)))?.value(for: "+CIREG:") {
            applyIMSRegistration(v, isURC: false)
        }
        if supportsCASIMS,
           let v = (try? await ch.send("AT+CASIMS?", timeout: .seconds(2)))?.value(for: "+CASIMS:"),
           let state = ATParsers.fields(v).first.flatMap(Int.init) {
            modem.imsSMSConfigured = state == 1
        }
        modem.registrationUpdatedAt = (eps != nil || cs != nil) ? Date() : nil
        updateSMSReadySince(wasReady: wasSMSReady)
        if let v = (try? await ch.send("AT+COPS?"))?.value(for: "+COPS:"), let cops = ATParsers.cops(v) {
            modem.operatorCode = cops.operatorCode
            modem.accessTechnology = cops.accessTechnology
        }
        if modem.sim.number == nil, modem.sim.isReady {
            if let n = (try? await ch.send("AT+CNUM"))?.value(for: "+CNUM:").flatMap(ATParsers.cnum) {
                modem.sim.number = n
                if let iccid = modem.sim.iccid, !iccid.isEmpty {
                    var s = app.settings
                    s.msisdnByICCID[iccid] = n
                    app.settings = s
                }
            } else if let iccid = modem.sim.iccid, let cached = app.settings.msisdnByICCID[iccid], !cached.isEmpty {
                modem.sim.number = cached
            }
        }
    }

    private func heartbeatLoop(_ ch: ATChannel) async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: heartbeatInterval)
            guard FileManager.default.fileExists(atPath: modem.port) else { throw ModemError.disconnected }
            do {
                try await refreshStatus(ch)
                await registrationWatchdog(ch)
                await blinkNoSignalIfNeeded(ch)
            } catch ATError.portClosed {
                throw ModemError.disconnected
            } catch {
                modem.consecutiveHeartbeatMisses += 1
                log("modem …\(modem.id.suffix(6)) heartbeat miss #\(modem.consecutiveHeartbeatMisses): \(error.localizedDescription)")
                if modem.consecutiveHeartbeatMisses >= 3 { throw ModemError.disconnected }
            }
        }
    }

    // MARK: - URCs

    private func consumeURCs(_ ch: ATChannel) async throws {
        var awaitingStatusReportPDU = false
        for await line in ch.urcs {
            if awaitingStatusReportPDU {
                awaitingStatusReportPDU = false
                await handleStatusReport(pdu: line, on: ch)
            } else if line.hasPrefix("+CDS:") {
                // In PDU mode the +CDS header is followed by the raw status-report PDU.
                awaitingStatusReportPDU = true
            } else if line.hasPrefix("+CMTI:") {
                if let (mem, idx) = ATParsers.cmti(String(line.dropFirst(6))) {
                    await readAndStore(ch, memory: mem, index: idx)
                }
            } else if line.hasPrefix("+CEREG:") || line.hasPrefix("+CREG:") {
                let body = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                if let reg = ATParsers.registration(body, isURC: true) {
                    let wasSMSReady = modem.isSMSReady
                    if line.hasPrefix("+CEREG:") {
                        modem.epsRegistration = reg
                    } else {
                        modem.csRegistration = reg
                    }
                    modem.registrationUpdatedAt = Date()
                    updateSMSReadySince(wasReady: wasSMSReady)
                    let domain = line.hasPrefix("+CEREG:") ? "EPS" : "CS"
                    log("modem …\(modem.id.suffix(6)) \(domain) registration → \(reg.statusText) \(ATParsers.accessTechnologyName(reg.accessTechnology))")
                }
            } else if line.hasPrefix("+CIREGU:") || line.hasPrefix("+CIREG:") {
                let body = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                applyIMSRegistration(body, isURC: line.hasPrefix("+CIREGU:"))
            } else if line.hasPrefix("+CPIN:") {
                let wasReady = modem.sim.isReady
                modem.sim.status = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if !modem.sim.isReady {
                    modem.sim.number = nil
                    modem.sim.iccid = nil
                    modem.sim.imsi = nil
                    modem.sim.smsc = nil
                } else if !wasReady {
                    // Re-run identity and routing setup before any send on a newly-ready SIM.
                    await ch.close()
                    throw ModemError.disconnected
                }
            } else {
                log("URC [\(modem.label)] \(line)")
            }
        }
        throw ModemError.disconnected
    }

    private func handleStatusReport(pdu: String, on ch: ATChannel) async {
        defer {
            if smsMessageService == 1 {
                Task { await ch.acknowledgeNewMessage() }
            }
        }
        do {
            let report = try PDUDecoder.decodeStatusReport(hex: pdu)
            var identities = modem.routeAliases + [modem.id]
            if let iccid = modem.sim.iccid { identities.append(iccid) }
            identities = identities.reduce(into: []) {
                if !$0.contains($1) { $0.append($1) }
            }
            var matched: OutgoingStatusReportMatch?
            for identity in identities where matched == nil {
                matched = try app.store.recordOutgoingStatusReport(
                    simIdentity: identity, messageReference: report.messageReference,
                    recipient: report.recipient,
                    serviceCentreTimestamp: report.serviceCentreTimestamp,
                    status: Int(report.status), at: Date()
                )
            }
            guard let match = matched else {
                log("unmatched SMS status report MR \(report.messageReference) to \(report.recipient)")
                return
            }

            let outcome = report.isDelivered
                ? "delivered"
                : report.isComplete ? "complete, status \(report.status)" : "pending, status \(report.status)"
            log("SMS status #\(match.messageID) part \(match.sequence) MR \(report.messageReference): \(outcome)")

            // A report can be the only positive evidence after CMGS timed out. Finalize a
            // fully-reported message even if its queue row had already reached gave_up.
            if match.allPartsSubmitted,
               let message = try app.store.message(id: match.messageID) {
                let count = try app.store.outgoingParts(messageID: match.messageID).count
                if try app.store.markOutgoingSent(id: match.messageID, parts: count) {
                    app.refreshPage()
                    if report.status >= 0x40 {
                        await app.notifyOutgoing(
                            message, result: .failure(ModemError.deliveryFailed(status: report.status))
                        )
                    } else {
                        await app.notifyOutgoing(message, result: .success(count))
                    }
                }
            } else if try app.store.reviveOutgoingAfterStatusReport(messageID: match.messageID) {
                log("SMS status #\(match.messageID) resolved a timed-out part; resuming remaining parts")
            }
            kickOutgoing()
        } catch {
            log("invalid SMS status report: \(error.localizedDescription)")
        }
    }

    private func updateSMSReadySince(wasReady: Bool) {
        if modem.isSMSReady {
            if !wasReady || modem.smsReadySince == nil { modem.smsReadySince = Date() }
        } else {
            modem.smsReadySince = nil
        }
    }

    // MARK: - Reading / storing

    private func ensurePDUMode(_ ch: ATChannel) async throws {
        try await ch.sendOK("AT+CMGF=0")
    }

    private func claimNotifications(_ ch: ATChannel) async {
        let ds = statusReportsEnabled ? 1 : 0
        _ = try? await ch.send("AT+CNMI=2,1,0,\(ds),0")
    }

    private func readAndStore(_ ch: ATChannel, memory: String, index: Int) async {
        do {
            try await ensurePDUMode(ch)
            if memory != currentMemory { try await selectMemory(ch, memory) }
            let r = try await ch.send("AT+CMGR=\(index)", timeout: .seconds(8))
            guard r.isOK else {
                log("CMGR \(index) failed: \(r.final)")
                return
            }
            let entries = ATParsers.pduEntries(from: r, listing: false)
            for entry in entries {
                app.ingest(pdu: entry.pdu, status: entry.status, from: modem)
            }
            if app.settings(for: modem).deleteFromSIM, !entries.isEmpty {
                _ = try? await ch.send("AT+CMGD=\(index)")
            }
            if memory != "SM" { try await selectMemory(ch, "SM") } else { await updateStorage(ch) }
        } catch {
            log("read \(memory)/\(index) failed: \(error.localizedDescription)")
        }
    }

    private func sweepStoredMessages(_ ch: ATChannel) async throws {
        await claimNotifications(ch)
        for mem in ["SM", "ME"] {
            try await ensurePDUMode(ch)
            do { try await selectMemory(ch, mem) } catch { continue }
            let r = try await ch.send("AT+CMGL=4", timeout: .seconds(20))
            guard r.isOK else {
                log("CMGL on \(mem) failed: \(r.final)")
                continue
            }
            for entry in ATParsers.pduEntries(from: r, listing: true) {
                guard entry.status == 0 || entry.status == 1 else { continue }
                app.ingest(pdu: entry.pdu, status: entry.status, from: modem)
                if app.settings(for: modem).deleteFromSIM, let idx = entry.index {
                    _ = try? await ch.send("AT+CMGD=\(idx)")
                }
            }
        }
        try await selectMemory(ch, "SM")
    }

    private func sweepLoop(_ ch: ATChannel) async throws {
        while !Task.isCancelled {
            let interval = max(5, app.settings(for: modem).pollIntervalSeconds)
            try await Task.sleep(for: .seconds(interval))
            try await sweepStoredMessages(ch)
            let flushed = try app.store.flushStaleParts(olderThan: stalePartAge, forwardingEnabled: app.settings(for: modem).forwardingEnabled)
            if !flushed.isEmpty {
                log("flushed \(flushed.count) incomplete multipart message(s)")
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
        guard modem.canSendSMS else { return }  // wait for fresh, settled SMS registration
        // The primary modem also picks up messages with no explicit route (composer / older rows).
        let isPrimary = app.primaryModem?.id == modem.id
        guard let due = try? app.store.dueOutgoing(
            routeKeys: modem.routeAliases, limit: 5, includeUntargeted: isPrimary
        ), !due.isEmpty else { return }
        for msg in due {
            guard (try? app.store.claimOutgoing(id: msg.id, owner: outgoingClaimOwner)) == true else {
                continue
            }
            defer { try? app.store.releaseOutgoingClaim(id: msg.id, owner: outgoingClaimOwner) }
            if msg.simNumber != modem.routeKey {
                guard (try? app.store.bindOutgoingRoute(
                    id: msg.id, routeKey: modem.routeKey,
                    acceptedRouteKeys: modem.routeAliases, owner: outgoingClaimOwner
                )) == true else { continue }
            }
            do {
                let parts = try await sendSMS(ch, message: msg)
                if try app.store.markOutgoingSent(id: msg.id, parts: parts) {
                    log("modem …\(modem.id.suffix(6)) sent SMS to \(msg.sender) (\(parts) part\(parts == 1 ? "" : "s"))")
                    await app.notifyOutgoing(msg, result: .success(parts))
                }
            } catch is CancellationError {
                return
            } catch {
                let attempts = msg.forwardAttempts + 1
                let permanent = error is PDUEncoder.EncodeError || Self.isPermanentSendError(error)
                let gaveUp = permanent || attempts >= 5
                let delay: TimeInterval = Self.isNetworkTimeout(error) ? 20 : 60
                let recorded = (try? app.store.markFailed(
                    id: msg.id, error: error.localizedDescription,
                    nextAttempt: gaveUp ? nil : Date().addingTimeInterval(delay), gaveUp: gaveUp
                )) ?? false
                guard recorded else { continue } // a concurrent +CDS already finalized it
                log("send to \(msg.sender) failed (attempt \(attempts)\(gaveUp ? ", giving up" : "")): \(error.localizedDescription)")
                if gaveUp {
                    await app.notifyOutgoing(msg, result: .failure(error))
                } else if attempts == 1 {
                    await app.notifyOutgoingRetrying(msg, error: error, in: delay)
                }
                if Self.requiresChannelReconnect(error) {
                    app.refreshPage()
                    return
                }
            }
            app.refreshPage()
        }
    }

    private func sendSMS(_ ch: ATChannel, message: StoredMessage) async throws -> Int {
        let simIdentity = modem.routeKey
        let parts = try app.store.prepareOutgoingParts(
            messageID: message.id, to: message.sender, body: message.body, simIdentity: simIdentity
        )
        try await ensurePDUMode(ch)
        for part in parts where part.needsSubmission {
            try await submit(part: part, for: message, on: ch)
        }
        return parts.count
    }

    private func submit(part initialPart: OutgoingPart, for message: StoredMessage,
                        on ch: ATChannel) async throws {
        var permitFastRetry = initialPart.attempts == 0
        while true {
            guard try app.store.renewOutgoingClaim(
                id: message.id, owner: outgoingClaimOwner
            ) else {
                throw ModemError.outgoingClaimLost
            }
            let part = try app.store.beginOutgoingPartAttempt(
                messageID: message.id, sequence: initialPart.sequence
            )
            guard part.needsSubmission else { return }
            let isAmbiguousRetry = part.state == .transmitting || part.state == .ambiguous
            let pdu = isAmbiguousRetry
                ? try PDUEncoder.settingRejectDuplicates(in: part.pdu)
                : part.pdu

            do {
                let store = app.store
                let messageID = message.id
                let sequence = part.sequence
                let exchange = try await ch.sendWithPrompt(
                    "AT+CMGS=\(part.tpduLength)", payload: Data(pdu.utf8),
                    beforePayload: {
                        guard try store.markOutgoingPartTransmitting(
                            messageID: messageID, sequence: sequence
                        ) else { throw CancellationError() }
                    },
                    promptTimeout: .seconds(10), timeout: .seconds(60)
                )
                let response = exchange.response
                guard response.isOK else {
                    throw ATError.failure(command: "AT+CMGS", result: response.final)
                }
                let modemReference = response.value(for: "+CMGS:").flatMap {
                    Int(ATParsers.fields($0).first ?? $0)
                }
                try app.store.markOutgoingPartSubmitted(
                    messageID: message.id, sequence: part.sequence, modemReference: modemReference
                )
                if let modemReference, modemReference != Int(part.messageReference), !loggedTPMRRewrite {
                    loggedTPMRRewrite = true
                    log(
                        "warning: modem rewrote SMS TP-MR \(part.messageReference) as \(modemReference); "
                        + "network-level duplicate suppression may be weaker"
                    )
                }
                log(
                    "SMS submit #\(message.id) part \(part.sequence)/\(part.total) MR \(part.messageReference) "
                    + "attempt \(part.attempts) accepted · prompt \(Self.ms(exchange.promptLatency)) ms, "
                    + "network \(Self.ms(exchange.finalLatency)) ms · \(smsNetworkSnapshot)"
                )
                return
            } catch {
                if error is CancellationError { throw error }
                if Self.requiresChannelReconnect(error) {
                    // After Ctrl-Z, a local timeout has an unknown outcome and late final
                    // lines can corrupt the next command. Reopening is the only safe resync.
                    await ch.close()
                }
                let code = Self.cmsErrorCode(error)

                // After an explicit 331/332, TP-FCS 197 on the RD=1 retry is strong
                // evidence that the SMSC retained the earlier submit.
                if isAmbiguousRetry, code == 197 {
                    try app.store.markOutgoingPartSubmitted(
                        messageID: message.id, sequence: part.sequence, modemReference: nil
                    )
                    log(
                        "SMS submit #\(message.id) part \(part.sequence)/\(part.total) MR \(part.messageReference) "
                        + "already accepted; SMSC suppressed duplicate · \(smsNetworkSnapshot)"
                    )
                    return
                }

                if code == 331 || code == 332 {
                    try? app.store.markOutgoingPartAmbiguous(
                        messageID: message.id, sequence: part.sequence, error: error.localizedDescription
                    )
                    log(
                        "SMS submit #\(message.id) part \(part.sequence)/\(part.total) MR \(part.messageReference) "
                        + "attempt \(part.attempts) ambiguous (+CMS \(code ?? -1)) · \(smsNetworkSnapshot)"
                    )
                }

                // The first explicit network timeout often leaves LTE SMS signalling warm.
                // Retry quickly with the same TP-MR and TP-RD=1; a +CDS arriving during
                // the pause can mark the part accepted and cancel this retransmission.
                if code == 332, permitFastRetry {
                    permitFastRetry = false
                    try await Task.sleep(for: fastSMSRetryDelay)
                    _ = try? await refreshStatus(ch)
                    let current = try app.store.outgoingParts(messageID: message.id)
                        .first { $0.sequence == part.sequence }
                    if current?.needsSubmission == false { return }
                    guard modem.canSendSMS else { throw error }
                    continue
                }
                throw error
            }
        }
    }

    private var smsNetworkSnapshot: String {
        let eps = modem.epsRegistration?.statusText ?? "unknown"
        let cs = modem.csRegistration?.statusText ?? "unknown"
        let ims = modem.imsSMSAvailable.map { $0 ? "available" : "unavailable" } ?? "unknown"
        return "EPS \(eps), CS \(cs), IMS \(ims), signal \(modem.signal.primaryDBmText)"
    }

    private static func ms(_ interval: TimeInterval) -> Int {
        Int((interval * 1000).rounded())
    }

    private static func cmsErrorCode(_ error: Error) -> Int? {
        (error as? ATError)?.cmsErrorCode
    }

    private static func isPermanentSendError(_ error: Error) -> Bool {
        guard let code = cmsErrorCode(error) else { return false }
        return (301...305).contains(code) || code == 21
    }

    private static func isNetworkTimeout(_ error: Error) -> Bool {
        guard let code = cmsErrorCode(error) else { return false }
        return code == 331 || code == 332
    }

    private static func requiresChannelReconnect(_ error: Error) -> Bool {
        switch error {
        case ATError.timeout(_), ATError.portClosed, ATError.writeFailed(_):
            return true
        default:
            return false
        }
    }

    /// CGMM/CGMR may be a bare line (ML307, our Air780 shim) or `+CGMR: "…"`.
    private func atIdentity(_ r: ATResponse?, prefixes: [String]) -> String? {
        guard let r else { return nil }
        for p in prefixes {
            if let v = r.value(for: p) {
                let s = Self.stripIdent(v)
                if !s.isEmpty { return s }
            }
        }
        let s = Self.stripIdent(r.informationText)
        return s.isEmpty ? nil : s
    }

    private func atiField(_ r: ATResponse?, name: String) -> String? {
        guard let r else { return nil }
        let prefix = name.lowercased() + ":"
        for line in r.lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.lowercased().hasPrefix(prefix) else { continue }
            let s = Self.stripIdent(String(t.dropFirst(prefix.count)))
            if !s.isEmpty { return s }
        }
        return nil
    }

    private static func stripIdent(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
    }
}

/// Last 6 of the IMEI, for compact log tags.
private func modem_suffix(_ imei: String) -> String { String(imei.suffix(6)) }
