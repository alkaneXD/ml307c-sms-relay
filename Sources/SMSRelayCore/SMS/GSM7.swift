import Foundation

/// GSM 03.38 default 7-bit alphabet and its single-shift extension table.
public enum GSM7 {
    // 128 entries, index = septet value.
    private static let basic: [Character] = [
        "@", "£", "$", "¥", "è", "é", "ù", "ì", "ò", "Ç", "\n", "Ø", "ø", "\r", "Å", "å",
        "Δ", "_", "Φ", "Γ", "Λ", "Ω", "Π", "Ψ", "Σ", "Θ", "Ξ", "\u{1B}", "Æ", "æ", "ß", "É",
        " ", "!", "\"", "#", "¤", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?",
        "¡", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
        "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "Ä", "Ö", "Ñ", "Ü", "§",
        "¿", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
        "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "ä", "ö", "ñ", "ü", "à",
    ]

    private static let extended: [UInt8: Character] = [
        0x0A: "\u{0C}", 0x14: "^", 0x28: "{", 0x29: "}", 0x2F: "\\",
        0x3C: "[", 0x3D: "~", 0x3E: "]", 0x40: "|", 0x65: "€",
    ]

    private static let reverseBasic: [Character: UInt8] = {
        var m: [Character: UInt8] = [:]
        for (i, c) in basic.enumerated() where c != "\u{1B}" { m[c] = UInt8(i) }
        return m
    }()

    private static let reverseExtended: [Character: UInt8] = {
        var m: [Character: UInt8] = [:]
        for (code, c) in extended { m[c] = code }
        return m
    }()

    /// True when every character is representable in the GSM 7-bit alphabet (incl. extension table).
    public static func canEncode(_ text: String) -> Bool {
        text.allSatisfy { reverseBasic[$0] != nil || reverseExtended[$0] != nil }
    }

    /// Text → septets (extension characters become an ESC pair). Precondition: `canEncode(text)`.
    public static func encode(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.count)
        for c in text {
            if let b = reverseBasic[c] {
                out.append(b)
            } else if let e = reverseExtended[c] {
                out.append(0x1B)
                out.append(e)
            } else {
                out.append(0x3F)  // '?'
            }
        }
        return out
    }

    /// Packs septets LSB-first, starting `skipBits` bits into the first byte (UDH alignment).
    public static func pack(_ septets: [UInt8], skipBits: Int = 0) -> [UInt8] {
        let totalBits = skipBits + septets.count * 7
        var out = [UInt8](repeating: 0, count: (totalBits + 7) / 8)
        var bit = skipBits
        for s in septets {
            for b in 0..<7 {
                if (s >> b) & 1 == 1 { out[bit / 8] |= 1 << (bit % 8) }
                bit += 1
            }
        }
        return out
    }

    /// Unpacks `septetCount` 7-bit values from `data`, starting `skipBits` bits in.
    /// Used both for message bodies and for alphanumeric originating addresses.
    public static func unpack(_ data: [UInt8], septetCount: Int, skipBits: Int = 0) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(septetCount)
        for i in 0..<septetCount {
            let bitIndex = skipBits + i * 7
            let byteIndex = bitIndex / 8
            let bitOffset = bitIndex % 8
            guard byteIndex < data.count else { break }
            var value = Int(data[byteIndex]) >> bitOffset
            if bitOffset > 1, byteIndex + 1 < data.count {
                value |= Int(data[byteIndex + 1]) << (8 - bitOffset)
            }
            out.append(UInt8(value & 0x7F))
        }
        return out
    }

    /// Maps septets to text, honouring the 0x1B single-shift escape.
    public static func decode(septets: [UInt8]) -> String {
        var result = ""
        result.reserveCapacity(septets.count)
        var escape = false
        for s in septets {
            if escape {
                escape = false
                result.append(extended[s] ?? " ")
                continue
            }
            if s == 0x1B {
                escape = true
                continue
            }
            result.append(basic[Int(s)])
        }
        return result
    }

    public static func decode(packed data: [UInt8], septetCount: Int, skipBits: Int = 0) -> String {
        decode(septets: unpack(data, septetCount: septetCount, skipBits: skipBits))
    }
}
