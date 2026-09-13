import Foundation

/// Concatenation info from the User Data Header (IEI 0x00 / 0x08).
public struct ConcatInfo: Equatable, Sendable {
    public let reference: Int
    public let total: Int
    public let sequence: Int  // 1-based

    public init(reference: Int, total: Int, sequence: Int) {
        self.reference = reference
        self.total = total
        self.sequence = sequence
    }
}

/// A decoded SMS-DELIVER TPDU.
public struct SMSDeliver: Equatable, Sendable {
    public enum Encoding: String, Sendable { case gsm7, data8bit, ucs2 }

    public let smsc: String?
    public let sender: String
    public let protocolID: UInt8
    public let encoding: Encoding
    /// Service centre timestamp as sent by the network (includes the network's TZ).
    public let timestamp: Date?
    /// The TZ offset (seconds) encoded in the SCTS, kept for display.
    public let timezoneOffset: Int?
    public let concat: ConcatInfo?
    public let text: String
    public let hasUserDataHeader: Bool

    public init(smsc: String?, sender: String, protocolID: UInt8, encoding: Encoding, timestamp: Date?,
                timezoneOffset: Int?, concat: ConcatInfo?, text: String, hasUserDataHeader: Bool) {
        self.smsc = smsc
        self.sender = sender
        self.protocolID = protocolID
        self.encoding = encoding
        self.timestamp = timestamp
        self.timezoneOffset = timezoneOffset
        self.concat = concat
        self.text = text
        self.hasUserDataHeader = hasUserDataHeader
    }
}

public enum PDUError: Error, LocalizedError, Equatable {
    case invalidHex
    case truncated(String)
    case notDeliver(mti: UInt8)

    public var errorDescription: String? {
        switch self {
        case .invalidHex: return "PDU is not valid hex"
        case .truncated(let where_): return "PDU truncated at \(where_)"
        case .notDeliver(let mti): return "PDU is not an SMS-DELIVER (MTI=\(mti))"
        }
    }
}

public enum PDUDecoder {
    public static func decode(hex: String) throws -> SMSDeliver {
        guard let bytes = hexToBytes(hex) else { throw PDUError.invalidHex }
        var r = Reader(bytes)

        // --- SMSC ---
        let smscLen = Int(try r.byte("smsc length"))
        var smsc: String? = nil
        if smscLen > 0 {
            let toa = try r.byte("smsc toa")
            let digits = try r.bytes(smscLen - 1, "smsc digits")
            smsc = formatNumber(semiOctets: digits, digitCount: (smscLen - 1) * 2, toa: toa)
        }

        // --- first octet ---
        let first = try r.byte("first octet")
        let mti = first & 0x03
        guard mti == 0x00 else { throw PDUError.notDeliver(mti: mti) }
        let udhi = (first & 0x40) != 0

        // --- originating address ---
        let oaDigits = Int(try r.byte("oa length"))
        let oaTOA = try r.byte("oa toa")
        let oaBytes = try r.bytes((oaDigits + 1) / 2, "oa digits")
        let sender: String
        if (oaTOA & 0x70) == 0x50 {
            // Alphanumeric sender: 7-bit packed, septets = digits*4/7
            let septets = oaDigits * 4 / 7
            sender = GSM7.decode(packed: oaBytes, septetCount: septets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            sender = formatNumber(semiOctets: oaBytes, digitCount: oaDigits, toa: oaTOA)
        }

        let pid = try r.byte("pid")
        let dcs = try r.byte("dcs")
        let encoding = Self.encoding(fromDCS: dcs)

        // --- SCTS ---
        let scts = try r.bytes(7, "scts")
        let (timestamp, tz) = decodeTimestamp(scts)

        // --- user data ---
        let udl = Int(try r.byte("udl"))
        let ud = Array(r.remaining())

        var concat: ConcatInfo? = nil
        var headerOctets = 0
        if udhi, let udhl = ud.first {
            headerOctets = Int(udhl) + 1
            let header = Array(ud.dropFirst().prefix(Int(udhl)))
            concat = parseConcat(header)
        }

        let text: String
        switch encoding {
        case .gsm7:
            // Text begins on the septet boundary after the header.
            let headerBits = headerOctets * 8
            let skipSeptets = (headerBits + 6) / 7
            let skipBits = skipSeptets * 7
            let septets = max(0, udl - skipSeptets)
            text = GSM7.decode(packed: ud, septetCount: septets, skipBits: skipBits)
        case .ucs2:
            let body = Array(ud.dropFirst(headerOctets).prefix(max(0, udl - headerOctets)))
            text = decodeUCS2(body)
        case .data8bit:
            let body = Array(ud.dropFirst(headerOctets).prefix(max(0, udl - headerOctets)))
            // Binary payloads (WAP push, vendor data) are kept as hex rather than mangled text.
            if let s = String(bytes: body, encoding: .utf8), !s.contains("\u{0}") {
                text = s
            } else {
                text = "[binary] " + body.map { String(format: "%02X", $0) }.joined()
            }
        }

        return SMSDeliver(
            smsc: smsc, sender: sender, protocolID: pid, encoding: encoding,
            timestamp: timestamp, timezoneOffset: tz, concat: concat, text: text,
            hasUserDataHeader: udhi
        )
    }

    // MARK: - helpers

    static func encoding(fromDCS dcs: UInt8) -> SMSDeliver.Encoding {
        switch dcs >> 4 {
        case 0x0...0x3:
            // General data coding: bits 3-2 select the alphabet.
            switch (dcs >> 2) & 0x03 {
            case 0x01: return .data8bit
            case 0x02: return .ucs2
            default: return .gsm7
            }
        case 0xE:
            return .ucs2  // message waiting, UCS2
        case 0xF:
            return (dcs & 0x04) != 0 ? .data8bit : .gsm7
        default:
            return .gsm7
        }
    }

    static func parseConcat(_ header: [UInt8]) -> ConcatInfo? {
        var i = 0
        while i + 1 < header.count {
            let iei = header[i]
            let len = Int(header[i + 1])
            let start = i + 2
            guard start + len <= header.count else { break }
            let ie = Array(header[start..<start + len])
            if iei == 0x00, len == 3 {
                return ConcatInfo(reference: Int(ie[0]), total: Int(ie[1]), sequence: Int(ie[2]))
            }
            if iei == 0x08, len == 4 {
                return ConcatInfo(reference: Int(ie[0]) << 8 | Int(ie[1]), total: Int(ie[2]), sequence: Int(ie[3]))
            }
            i = start + len
        }
        return nil
    }

    /// Semi-octet (nibble swapped) digit string. 0xF pads odd lengths.
    static func semiOctetDigits(_ bytes: [UInt8], count: Int) -> String {
        var s = ""
        for b in bytes {
            let lo = b & 0x0F, hi = b >> 4
            if s.count < count { s.append(digitChar(lo)) }
            if s.count < count { s.append(digitChar(hi)) }
        }
        return s
    }

    private static func digitChar(_ v: UInt8) -> Character {
        switch v {
        case 0...9: return Character(String(v))
        case 0xA: return "*"
        case 0xB: return "#"
        case 0xC: return "a"
        case 0xD: return "b"
        case 0xE: return "c"
        default: return "F"
        }
    }

    static func formatNumber(semiOctets: [UInt8], digitCount: Int, toa: UInt8) -> String {
        var digits = semiOctetDigits(semiOctets, count: digitCount)
        while digits.hasSuffix("F") { digits.removeLast() }
        let international = (toa & 0x70) == 0x10
        return international ? "+" + digits : digits
    }

    static func decodeTimestamp(_ b: [UInt8]) -> (Date?, Int?) {
        func swapped(_ x: UInt8) -> Int { Int(x & 0x0F) * 10 + Int(x >> 4) }
        let yy = swapped(b[0]), mm = swapped(b[1]), dd = swapped(b[2])
        let hh = swapped(b[3]), mi = swapped(b[4]), ss = swapped(b[5])
        let tzRaw = b[6]
        let tzNegative = (tzRaw & 0x08) != 0
        let quarters = Int(tzRaw & 0x07) * 10 + Int(tzRaw >> 4)
        let tzSeconds = (tzNegative ? -1 : 1) * quarters * 15 * 60

        var comps = DateComponents()
        comps.year = 2000 + yy
        comps.month = mm
        comps.day = dd
        comps.hour = hh
        comps.minute = mi
        comps.second = ss
        comps.timeZone = TimeZone(secondsFromGMT: tzSeconds)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: tzSeconds) ?? .current
        return (cal.date(from: comps), tzSeconds)
    }

    static func decodeUCS2(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            units.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    public static func hexToBytes(_ hex: String) -> [UInt8]? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let v = UInt8(clean[idx..<next], radix: 16) else { return nil }
            out.append(v)
            idx = next
        }
        return out
    }

    private struct Reader {
        let bytes: [UInt8]
        var pos = 0
        init(_ b: [UInt8]) { bytes = b }

        mutating func byte(_ what: String) throws -> UInt8 {
            guard pos < bytes.count else { throw PDUError.truncated(what) }
            defer { pos += 1 }
            return bytes[pos]
        }

        mutating func bytes(_ n: Int, _ what: String) throws -> [UInt8] {
            guard pos + n <= bytes.count else { throw PDUError.truncated(what) }
            defer { pos += n }
            return Array(bytes[pos..<pos + n])
        }

        func remaining() -> ArraySlice<UInt8> { bytes[pos...] }
    }
}
