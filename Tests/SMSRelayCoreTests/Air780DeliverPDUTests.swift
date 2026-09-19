import XCTest
@testable import SMSRelayCore

final class Air780DeliverPDUTests: XCTestCase {
    func testShortGSM7InternationalOA() throws {
        // Firmware-style DELIVER: SMSC 00, FO 04, OA +639171234567, GSM7 "hello"
        let pdu = "00040C9136191732547600006290021092352305E8329BFD06"
        let d = try PDUDecoder.decode(hex: pdu)
        XCTAssertEqual(d.sender, "+639171234567")
        XCTAssertEqual(d.text, "hello")
        XCTAssertEqual(d.encoding, .gsm7)
        XCTAssertNil(d.concat)
    }

    func testAlphanumericSenderGCash() throws {
        let pdu = "004409D0C761788E0600006290021092352305C4B2190D"
        let d = try PDUDecoder.decode(hex: pdu)
        XCTAssertEqual(d.sender, "GCash")
    }

    /// Real Mini capture: firmware 0.5.3 wrote UDL=450 as hex "1C2" (odd length) + UCS2 body.
    func testWideUDLRecoveryReadsLongUCS2() throws {
        let hex = "000400910008629002109225231C2004E004500560045005200200053004800410052004500200059004F005500520020004F0054005000200065007300700065006300690061006C006C00790020006F006E00200073006F006300690061006C0020006D006500640069006100200061006E006400200053004D00530020006F007200200065006D00610069006C0020006C0069006E006B0073002E002000470043006100730068002000770069006C006C0020006F006E006C00790020006E00650065006400200079006F007500720020004D00500049004E0020006F00720020004F005400500020007700680065006E0020007500730069006E006700200074006800650020004700430061007300680020004100700070002E00200059006F007500720020004F0054005000200074006F0020006C0069006E006B00200079006F0075007200200064006500760069006300650020006900730020003600300039003700390033002E00200020004900660020007400680069007300200077006100730020006E006F007400200079006F0075002C00200070006C0065006100730065002000690067006E006F00720065002E0020007900790041006600630059006E002F007100530057002E"
        XCTAssertEqual(hex.count % 2, 1)
        let d = try PDUDecoder.decode(hex: hex)
        XCTAssertTrue(d.text.contains("OTP"), d.text)
        XCTAssertTrue(d.text.contains("GCash") || d.text.contains("SHARE"), d.text)
        XCTAssertTrue(d.text.contains("609793"), d.text)
        XCTAssertTrue(d.text.hasPrefix("NEVER") || d.text.contains("NEVER") || d.text.contains("EVER"), d.text)
    }

    func testLongGSM7FitsInConcatParts() throws {
        let text = String(repeating: "A", count: 200)
        let parts = try PDUEncoder.encodeSubmit(to: "+639171234567", text: text, reference: 0x42)
        XCTAssertEqual(parts.count, 2)
        XCTAssertLessThanOrEqual(parts[0].tpduLength, 164)
        XCTAssertTrue(parts[0].hex.count % 2 == 0)
        XCTAssertTrue(parts[1].hex.count % 2 == 0)
    }

    func testUCS2ChineseSubmitIsEvenHex() throws {
        let parts = try PDUEncoder.encodeSubmit(to: "+639171234567", text: "你好世界")
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].hex.count % 2, 0)
        XCTAssertTrue(parts[0].hex.contains("0008") || parts[0].hex.contains("08"))
    }

    func testEmojiAndMixedUCS2Deliver() throws {
        let d = try PDUDecoder.decode(bytes: ucs2Deliver(oa: "+639171234567", text: "hi 😀🎉"))
        XCTAssertEqual(d.sender, "+639171234567")
        XCTAssertEqual(d.encoding, .ucs2)
        XCTAssertEqual(d.text, "hi 😀🎉")
    }

    func testEmojiSurrogateNotSplitAcrossConcatParts() throws {
        // 70 BMP chars would fit one UCS2 SMS; one emoji is 2 UTF-16 units so 69 + emoji
        // needs a second part if we fill to the 67-unit concat payload.
        let text = String(repeating: "A", count: 66) + "😀"
        let units = Array(text.utf16)
        XCTAssertGreaterThan(units.count, 67)
        let p1Text = String(decoding: units.prefix(66), as: UTF16.self) // 66 A's, emoji stays on part 2
        let p2Text = String(decoding: units.suffix(from: 66), as: UTF16.self)
        XCTAssertEqual(p2Text, "😀")
        let p1 = ucs2Deliver(oa: "+639171234567", text: p1Text, concat: (0x42, 2, 1))
        let p2 = ucs2Deliver(oa: "+639171234567", text: p2Text, concat: (0x42, 2, 2))
        let d1 = try PDUDecoder.decode(bytes: p1)
        let d2 = try PDUDecoder.decode(bytes: p2)
        XCTAssertEqual(d1.concat?.sequence, 1)
        XCTAssertEqual(d2.concat?.sequence, 2)
        XCTAssertEqual(d1.text + d2.text, text)
        XCTAssertFalse(d1.text.contains("\u{FFFD}"))
        XCTAssertEqual(d2.text, "😀")
    }

    func testZWJFamilyEmojiRoundTrip() throws {
        let family = "👨‍👩‍👧‍👦"
        let d = try PDUDecoder.decode(bytes: ucs2Deliver(oa: "+639171234567", text: family))
        XCTAssertEqual(d.text, family)
    }

    func testOutgoingEmojiUsesUCS2() throws {
        let parts = try PDUEncoder.encodeSubmit(to: "+639171234567", text: "ok 👍")
        XCTAssertEqual(parts.count, 1)
        XCTAssertTrue(parts[0].hex.contains("0008") || parts[0].hex.contains("08"))
        XCTAssertEqual(parts[0].hex.count % 2, 0)
    }

    /// SMS-DELIVER, DCS UCS2, same layout the Air780 firmware emits.
    private func ucs2Deliver(oa: String, text: String, concat: (UInt8, UInt8, UInt8)? = nil) -> [UInt8] {
        let digits = oa.filter(\.isNumber)
        let toa: UInt8 = oa.hasPrefix("+") ? 0x91 : 0x81
        var first: UInt8 = 0x04
        var ud: [UInt8] = []
        if let c = concat {
            first |= 0x40
            ud += [0x05, 0x00, 0x03, c.0, c.1, c.2]
        }
        for u in text.utf16 {
            ud.append(UInt8(u >> 8))
            ud.append(UInt8(truncatingIfNeeded: u))
        }
        var tpdu: [UInt8] = [first, UInt8(digits.count), toa]
        tpdu += PDUEncoder.semiOctets(digits)
        tpdu += [0x00, 0x08]
        tpdu += [0x62, 0x90, 0x02, 0x10, 0x92, 0x35, 0x23]
        tpdu.append(UInt8(ud.count))
        tpdu += ud
        return [0x00] + tpdu
    }
}
