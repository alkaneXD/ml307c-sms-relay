import Foundation
import Observation
import SMSRelayCore

struct SIMInfo: Equatable {
    var status: String = "Unknown"
    var number: String?
    var iccid: String?
    var imsi: String?
    var smsc: String?
    var isReady: Bool { status == "READY" }
}

struct ModemInfo: Equatable {
    var model: String?
    var firmware: String?
    var imei: String?
    var port: String?
}

enum ConnectionState: Equatable {
    case searching
    case connecting(String)
    case connected(port: String, since: Date)
    case disconnected(reason: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var connectedSince: Date? {
        if case .connected(_, let since) = self { return since }
        return nil
    }
}

/// One physical modem: its live state plus the identity that lets us re-attach to the same
/// unit across reconnects. Identity is the IMEI (hardware), so a SIM swap keeps the same modem
/// and unplug/replug of a different unit is recognised as different.
@MainActor
@Observable
final class Modem: Identifiable {
    /// Stable identity — the modem's IMEI.
    let id: String
    /// Control serial port currently in use (e.g. /dev/cu.usbmodem…123).
    var port: String
    private var unverifiedSIMSessionID = UUID().uuidString

    var connection: ConnectionState = .connecting("")
    var lastHeartbeat: Date?
    var heartbeatRTT: TimeInterval?
    var consecutiveHeartbeatMisses = 0
    var reconnects = 0
    var usbResets = 0
    var lastError: String?

    var info = ModemInfo()
    var sim = SIMInfo()
    /// Registration domains are intentionally separate: EPS registration alone does not prove
    /// that the carrier's CS/SGs or IMS SMS path is ready.
    var epsRegistration: ATParsers.Registration?
    var csRegistration: ATParsers.Registration?
    var imsRegistered: Bool?
    /// IMS capability bit reported by CIREG <ext_info>, not merely the local CASIMS setting.
    var imsSMSAvailable: Bool?
    /// CASIMS is a local UE/application setting. It is diagnostic only and not proof that
    /// the carrier's IMS SMS path is registered.
    var imsSMSConfigured: Bool?
    var registrationUpdatedAt: Date?
    var smsReadySince: Date?
    var operatorCode: String?
    var accessTechnology: Int?
    var signal: SignalQuality = .unknown
    var storageUsed: Int?
    var storageTotal: Int?
    var modemAutoDial: Bool?

    init(id: String, port: String) {
        self.id = id
        self.port = port
        info.imei = id
        info.port = port
    }

    // MARK: - Derived

    /// "Stable" = connected for a minute, no missed heartbeats, and a fresh heartbeat.
    var isStable: Bool {
        guard let since = connection.connectedSince, let hb = lastHeartbeat else { return false }
        return Date().timeIntervalSince(since) >= 60
            && consecutiveHeartbeatMisses == 0
            && Date().timeIntervalSince(hb) < 45
    }

    /// Kept as the display-facing registration value; operational code uses the explicit
    /// EPS/CS/IMS fields above.
    var registration: ATParsers.Registration? {
        if epsRegistration?.isRegistered == true { return epsRegistration }
        if csRegistration?.isRegistered == true { return csRegistration }
        return epsRegistration ?? csRegistration
    }

    var isRegistered: Bool {
        epsRegistration?.isRegistered == true || csRegistration?.isRegistered == true
    }

    /// A fresh best-effort indication that an SMS transport may be available. ML307 firmware
    /// does not expose IMS status consistently, so EPS registration remains a valid fallback
    /// for SMS-over-NAS while CS and IMS are tracked independently for diagnosis.
    var isSMSReady: Bool {
        guard connection.isConnected, sim.isReady,
              let refreshed = registrationUpdatedAt,
              Date().timeIntervalSince(refreshed) < 30 else { return false }
        return isRegistered
    }

    /// Avoid submitting during the short transition immediately after attach/re-registration.
    var canSendSMS: Bool {
        guard isSMSReady, let since = smsReadySince else { return false }
        return Date().timeIntervalSince(since) >= 2
    }

    var smsTransportText: String {
        if imsRegistered == true, imsSMSAvailable == true { return "IMS SMS" }
        if csRegistration?.isRegistered == true {
            return csRegistration?.isSMSOnly == true ? "CS SMS-only" : "CS / SGs"
        }
        if imsRegistered == true { return "IMS registered (SMS capability unknown)" }
        if epsRegistration?.isRegistered == true { return "LTE / NAS (unverified)" }
        return "Unavailable"
    }

    var operatorName: String { PLMN.display(code: operatorCode) }
    var accessTechnologyName: String { ATParsers.accessTechnologyName(accessTechnology ?? registration?.accessTechnology) }

    /// Stable SIM routing key. Never use CNUM for ownership: it is optional and can disappear;
    /// never use only IMEI because a replacement SIM in the same modem must not inherit retries.
    var routeKey: String {
        if let iccid = sim.iccid, !iccid.isEmpty { return "iccid:" + iccid }
        if let imsi = sim.imsi, !imsi.isEmpty { return "imsi:" + imsi }
        return "sim-session:" + unverifiedSIMSessionID
    }

    /// Number/IMEI aliases keep pre-migration rows routable long enough to pin them to the
    /// verified identity above.
    var routeAliases: [String] {
        var keys = [routeKey, "imei:" + id]
        if let iccid = sim.iccid, !iccid.isEmpty { keys.append("iccid:" + iccid) }
        if let imsi = sim.imsi, !imsi.isEmpty { keys.append("imsi:" + imsi) }
        if let number = sim.number, !number.isEmpty { keys.append(number) }
        return keys.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    func matches(routeKey candidate: String) -> Bool {
        routeAliases.contains(candidate)
    }

    /// Without ICCID/IMSI there is no safe way to prove a SIM survived a reconnect.
    func beginUnverifiedSIMSession() {
        unverifiedSIMSessionID = UUID().uuidString
    }

    /// Short human label for lists and menus.
    var label: String {
        if let n = sim.number, !n.isEmpty { return n }
        if let iccid = sim.iccid, iccid.count >= 4 { return "SIM …" + iccid.suffix(4) }
        return "IMEI …" + id.suffix(6)
    }

    var portShortName: String { port.replacingOccurrences(of: "/dev/cu.", with: "") }
}
