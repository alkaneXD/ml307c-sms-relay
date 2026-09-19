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
}
