import Foundation

/// Signal snapshot derived from +CSQ / +CESQ.
public struct SignalQuality: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case none = 0, poor, fair, good, excellent
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .none: return "No signal"
            case .poor: return "Poor"
            case .fair: return "Fair"
            case .good: return "Good"
            case .excellent: return "Excellent"
            }
        }
    }

    /// 0...31 from +CSQ, or nil when 99 (unknown).
    public let rssiIndex: Int?
    /// dBm from +CESQ <rsrp> when on LTE.
    public let rsrpDBm: Int?
    /// dB from +CESQ <rsrq>.
    public let rsrqDB: Double?

    public init(rssiIndex: Int?, rsrpDBm: Int? = nil, rsrqDB: Double? = nil) {
        self.rssiIndex = rssiIndex
        self.rsrpDBm = rsrpDBm
        self.rsrqDB = rsrqDB
    }

    public static let unknown = SignalQuality(rssiIndex: nil)

    public init(csq rssi: Int, cesq: (rsrq: Int?, rsrp: Int?)?) {
        rssiIndex = (0...31).contains(rssi) ? rssi : nil
        rsrpDBm = cesq?.rsrp.map { -140 + $0 }
        rsrqDB = cesq?.rsrq.map { -19.5 + Double($0) * 0.5 }
    }

    public var rssiDBm: Int? { rssiIndex.map { -113 + 2 * $0 } }

    /// Prefer RSRP (meaningful on LTE), fall back to RSSI.
    public var level: Level {
        if let rsrp = rsrpDBm {
            // Conventional LTE RSRP bands.
            if rsrp >= -80 { return .excellent }
            if rsrp >= -90 { return .good }
            if rsrp >= -100 { return .fair }
            return .poor
        }
        guard let rssi = rssiIndex else { return .none }
        if rssi >= 20 { return .excellent }
        if rssi >= 15 { return .good }
        if rssi >= 10 { return .fair }
        return .poor
    }

    /// 0.0…1.0 for `Image(systemName: "cellularbars", variableValue:)`.
    public var fraction: Double {
        switch level {
        case .none: return 0
        case .poor: return 0.25
        case .fair: return 0.5
        case .good: return 0.75
        case .excellent: return 1
        }
    }

    public var primaryDBmText: String {
        if let rsrp = rsrpDBm { return "\(rsrp) dBm" }
        if let rssi = rssiDBm { return "\(rssi) dBm" }
        return "—"
    }
}

/// Human names for PLMN codes. Falls back to the raw MCC-MNC.
public enum PLMN {
    private static let table: [String: String] = [
        // Philippines
        "51501": "Islacom", "51502": "Globe", "51503": "Smart", "51505": "Sun Cellular",
        "51518": "DITO", "51588": "Next Mobile",
        // A few common ones for when the SIM travels.
        "46000": "China Mobile", "46001": "China Unicom", "46011": "China Telecom",
        "52501": "Singtel", "52503": "M1", "52505": "StarHub",
        "50212": "Maxis", "50213": "Celcom", "50219": "Digi",
        "45400": "CSL", "45406": "SmarTone", "45412": "China Mobile HK",
        "44010": "NTT Docomo", "44020": "SoftBank", "44050": "KDDI",
        "31026": "T-Mobile US", "310410": "AT&T", "311480": "Verizon",
    ]

    public static func name(for code: String?) -> String? {
        guard let code = code?.replacingOccurrences(of: " ", with: ""), !code.isEmpty else { return nil }
        return table[code]
    }

    public static func display(code: String?) -> String {
        guard let code = code?.replacingOccurrences(of: " ", with: ""), !code.isEmpty else { return "—" }
        if let n = table[code] { return n }
        return code
    }
}
