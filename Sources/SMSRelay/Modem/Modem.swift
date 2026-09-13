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

    var connection: ConnectionState = .connecting("")
    var lastHeartbeat: Date?
    var heartbeatRTT: TimeInterval?
    var consecutiveHeartbeatMisses = 0
    var reconnects = 0
    var usbResets = 0
    var lastError: String?

    var info = ModemInfo()
    var sim = SIMInfo()
    var registration: ATParsers.Registration?
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

    var isRegistered: Bool { registration?.isRegistered == true }
    var operatorName: String { PLMN.display(code: operatorCode) }
    var accessTechnologyName: String { ATParsers.accessTechnologyName(accessTechnology ?? registration?.accessTechnology) }

    /// Key used to route outgoing SMS to the correct modem: the SIM number when known,
    /// otherwise the IMEI. Incoming messages are tagged with the same key.
    var routeKey: String { sim.number ?? "imei:" + id }

    /// Short human label for lists and menus.
    var label: String {
        if let n = sim.number, !n.isEmpty { return n }
        if let iccid = sim.iccid, iccid.count >= 4 { return "SIM …" + iccid.suffix(4) }
        return "IMEI …" + id.suffix(6)
    }

    var portShortName: String { port.replacingOccurrences(of: "/dev/cu.", with: "") }
}
