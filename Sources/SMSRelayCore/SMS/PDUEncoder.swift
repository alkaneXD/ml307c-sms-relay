import Foundation

/// Builds SMS-SUBMIT PDUs for `AT+CMGS` in PDU mode. GSM 7-bit when the text allows it,
/// UCS2 otherwise; long texts become concatenated parts with an 8-bit reference UDH.
public enum PDUEncoder {
    public struct Part: Equatable, Sendable {
        /// Hex string to send after the `>` prompt (includes the leading `00` = use default SMSC).
        public let hex: String
        /// Value for `AT+CMGS=<length>`: TPDU length excluding the SMSC octet.
        public let tpduLength: Int
        public let sequence: Int
        public let total: Int
    }

    public enum EncodeError: Error, LocalizedError, Equatable {
        case invalidNumber(String)
        case emptyText
        case tooManyParts(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidNumber(let n): return "Invalid phone number: \(n)"
            case .emptyText: return "Message is empty"
            case .tooManyParts(let n): return "Message too long (\(n) parts, max 10)"
            }
        }
    }

    public static let maxParts = 10

    /// Normalises "+63 917-123 4567" → "+639171234567"; nil if not a phone number.
    public static func normalizeNumber(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "[\\s\\-().]", with: "", options: .regularExpression)
        if s.hasPrefix("00") { s = "+" + s.dropFirst(2) }
        let international = s.hasPrefix("+")
        let digits = international ? String(s.dropFirst()) : s
        guard (3...20).contains(digits.count), digits.allSatisfy(\.isNumber) else { return nil }
        return (international ? "+" : "") + digits
    }

    public static func encodeSubmit(to destination: String, text: String, reference: UInt8? = nil,
                                    requestStatusReport: Bool = false) throws -> [Part] {
        guard let number = normalizeNumber(destination) else { throw EncodeError.invalidNumber(destination) }
        guard !text.isEmpty else { throw EncodeError.emptyText }

        let international = number.hasPrefix("+")
        let digits = String(number.drop { $0 == "+" })
        var da: [UInt8] = [UInt8(digits.count), international ? 0x91 : 0x81]
        da += semiOctets(digits)

        let ref = reference ?? UInt8.random(in: 0...255)
        let useGSM7 = GSM7.canEncode(text)

        // Split payload into parts.
        var gsmParts: [[UInt8]] = []
        var ucsParts: [[UInt8]] = []
        if useGSM7 {
            let septets = GSM7.encode(text)
            if septets.count <= 160 {
                gsmParts = [septets]
            } else {
                var i = 0
                while i < septets.count {
                    var end = min(i + 153, septets.count)
                    if end < septets.count, septets[end - 1] == 0x1B { end -= 1 }  // keep ESC pairs together
                    gsmParts.append(Array(septets[i..<end]))
                    i = end
                }
            }
        } else {
            let units = Array(text.utf16)
            if units.count <= 70 {
                ucsParts = [bigEndian(units)]
            } else {
                var i = 0
                while i < units.count {
                    var end = min(i + 67, units.count)
                    if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
                    ucsParts.append(bigEndian(Array(units[i..<end])))
                    i = end
                }
            }
        }

        let total = useGSM7 ? gsmParts.count : ucsParts.count
        guard total <= maxParts else { throw EncodeError.tooManyParts(total) }

        var out: [Part] = []
        for seq in 1...total {
            let udh: [UInt8] = total > 1 ? [0x05, 0x00, 0x03, ref, UInt8(total), UInt8(seq)] : []
            var first: UInt8 = 0x01  // SMS-SUBMIT, no validity period
            if !udh.isEmpty { first |= 0x40 }
            if requestStatusReport { first |= 0x20 }

            var ud: [UInt8]
            let udl: Int
            let dcs: UInt8
            if useGSM7 {
                let septets = gsmParts[seq - 1]
                let headerBits = udh.count * 8
                let headerSeptets = (headerBits + 6) / 7
                let skip = udh.isEmpty ? 0 : headerSeptets * 7 - headerBits
                ud = udh + GSM7.pack(septets, skipBits: skip)
                udl = headerSeptets + septets.count
                dcs = 0x00
            } else {
                ud = udh + ucsParts[seq - 1]
                udl = ud.count
                dcs = 0x08
            }

            var tpdu: [UInt8] = [first, 0x00]  // MR assigned by the modem
            tpdu += da
            tpdu += [0x00, dcs, UInt8(udl)]
            tpdu += ud
            let hex = ([0x00] + tpdu).map { String(format: "%02X", $0) }.joined()
            out.append(Part(hex: hex, tpduLength: tpdu.count, sequence: seq, total: total))
        }
        return out
    }

    // MARK: - helpers

    static func semiOctets(_ digits: String) -> [UInt8] {
        var chars = Array(digits)
        if chars.count % 2 == 1 { chars.append("F") }
        var out: [UInt8] = []
        var i = 0
        while i < chars.count {
            let lo = UInt8(String(chars[i]), radix: 16) ?? 0
            let hi = UInt8(String(chars[i + 1]), radix: 16) ?? 0xF
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func bigEndian(_ units: [UInt16]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(units.count * 2)
        for u in units {
            out.append(UInt8(u >> 8))
            out.append(UInt8(u & 0xFF))
        }
        return out
    }
}
