import Foundation

/// Parsers for the AT responses the ML307C emits. Every parser is tolerant: a
/// malformed line yields nil rather than crashing the modem loop.
public enum ATParsers {

    // MARK: - Utilities

    /// Splits a comma-separated AT parameter list, honouring quotes, keeping empty fields.
    public static func fields(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuotes = false
        for ch in s {
            switch ch {
            case "\"": inQuotes.toggle()
            case "," where !inQuotes:
                out.append(cur)
                cur = ""
            default: cur.append(ch)
            }
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Signal

    /// +CSQ: <rssi>,<ber>
    public static func csq(_ v: String) -> (rssi: Int, ber: Int)? {
        let f = fields(v)
        guard f.count >= 2, let rssi = Int(f[0]), let ber = Int(f[1]) else { return nil }
        return (rssi, ber)
    }

    /// +CESQ: <rxlev>,<ber>,<rscp>,<ecno>,<rsrq>,<rsrp>
    public static func cesq(_ v: String) -> (rsrq: Int?, rsrp: Int?)? {
        let f = fields(v)
        guard f.count >= 6 else { return nil }
        let rsrq = Int(f[4]).flatMap { $0 == 255 ? nil : $0 }
        let rsrp = Int(f[5]).flatMap { $0 == 255 ? nil : $0 }
        return (rsrq, rsrp)
    }

    // MARK: - Registration

    public struct Registration: Equatable, Sendable {
        public let status: Int
        public let lac: String?
        public let cellID: String?
        public let accessTechnology: Int?

        /// 6/7 are the 3GPP "SMS only" registration states. They are uncommon on older
        /// firmware, but are exactly the states an SMS-only relay must not reject.
        public var isRegistered: Bool {
            status == 1 || status == 5 || status == 6 || status == 7 || status == 9 || status == 10
        }
        public var isSMSOnly: Bool { status == 6 || status == 7 }
        public var isRoaming: Bool { status == 5 || status == 7 || status == 10 }
        public var statusText: String {
            switch status {
            case 0: return "Not registered"
            case 1: return "Registered"
            case 2: return "Searching"
            case 3: return "Registration denied"
            case 4: return "Unknown"
            case 5: return "Registered (roaming)"
            case 6: return "Registered for SMS only"
            case 7: return "Registered for SMS only (roaming)"
            case 8: return "Emergency services only"
            case 9: return "Registered (CSFB not preferred)"
            case 10: return "Registered (roaming, CSFB not preferred)"
            default: return "Status \(status)"
            }
        }
    }

    /// Handles both the read response `+CREG: <n>,<stat>[,lac,ci[,act]]`
    /// and the URC form `+CREG: <stat>[,lac,ci[,act]]`.
    public static func registration(_ v: String, isURC: Bool) -> Registration? {
        var f = fields(v)
        guard !f.isEmpty else { return nil }
        if !isURC { f.removeFirst() }  // drop <n>
        guard let stat = f.first.flatMap(Int.init) else { return nil }
        let lac = f.count > 1 && !f[1].isEmpty ? f[1] : nil
        let ci = f.count > 2 && !f[2].isEmpty ? f[2] : nil
        let act = f.count > 3 ? Int(f[3]) : nil
        return Registration(status: stat, lac: lac, cellID: ci, accessTechnology: act)
    }

    /// +COPS: <mode>,<format>,"<oper>",<act>
    public static func cops(_ v: String) -> (operatorCode: String?, accessTechnology: Int?)? {
        let f = fields(v)
        guard !f.isEmpty else { return nil }
        let oper = f.count > 2 && !f[2].isEmpty ? f[2].replacingOccurrences(of: " ", with: "") : nil
        let act = f.count > 3 ? Int(f[3]) : nil
        return (oper, act)
    }

    public static func accessTechnologyName(_ act: Int?) -> String {
        switch act {
        case 0: return "GSM"
        case 1: return "GSM Compact"
        case 2: return "UTRAN"
        case 3: return "EDGE"
        case 4: return "HSDPA"
        case 5: return "HSUPA"
        case 6: return "HSPA"
        case 7: return "LTE"
        case 8: return "EC-GSM-IoT"
        case 9: return "NB-IoT"
        case 10, 11, 12, 13: return "5G"
        default: return "—"
        }
    }

    // MARK: - SIM

    /// +CNUM: "<alpha>","<number>",<type>
    public static func cnum(_ v: String) -> String? {
        let f = fields(v)
        guard f.count >= 2, !f[1].isEmpty else { return nil }
        return f[1]
    }

    /// +CPMS: "<mem1>",<used1>,<total1>,...   (read form) or <used1>,<total1>,... (set form)
    public static func cpms(_ v: String) -> (used: Int, total: Int)? {
        let f = fields(v)
        let numeric = f.compactMap(Int.init)
        guard numeric.count >= 2 else { return nil }
        return (numeric[0], numeric[1])
    }

    // MARK: - SMS

    /// +CMTI: "<mem>",<index>
    public static func cmti(_ v: String) -> (memory: String, index: Int)? {
        let f = fields(v)
        guard f.count >= 2, let idx = Int(f[1]) else { return nil }
        return (f[0], idx)
    }

    public struct PDUEntry: Equatable, Sendable {
        public let index: Int?
        public let status: Int
        public let pdu: String
    }

    /// Parses PDU-mode `+CMGL: <idx>,<stat>,[alpha],<len>` / `+CMGR: <stat>,[alpha],<len>` blocks:
    /// each header line is followed by exactly one PDU line.
    public static func pduEntries(from response: ATResponse, listing: Bool) -> [PDUEntry] {
        let prefix = listing ? "+CMGL:" : "+CMGR:"
        var out: [PDUEntry] = []
        var i = 0
        let lines = response.lines
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix(prefix), i + 1 < lines.count {
                let f = fields(String(line.dropFirst(prefix.count)))
                let pdu = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if listing {
                    if f.count >= 2, let idx = Int(f[0]), let stat = Int(f[1]) {
                        out.append(PDUEntry(index: idx, status: stat, pdu: pdu))
                    }
                } else if let stat = f.first.flatMap(Int.init) {
                    out.append(PDUEntry(index: nil, status: stat, pdu: pdu))
                }
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }
}
