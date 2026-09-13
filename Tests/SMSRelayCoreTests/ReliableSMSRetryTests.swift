import XCTest
@testable import SMSRelayCore

final class ReliableSMSRetryTests: XCTestCase {
    func testRetryPreservesPDUAndSetsOnlyRejectDuplicates() throws {
        let part = try XCTUnwrap(PDUEncoder.encodeSubmit(
            to: "+639171234567", text: "hello", reference: 0x77,
            messageReferenceBase: 0x2A, requestStatusReport: true
        ).first)
        let original = try XCTUnwrap(PDUDecoder.hexToBytes(part.hex))
        let retry = try XCTUnwrap(PDUDecoder.hexToBytes(
            PDUEncoder.settingRejectDuplicates(in: part.hex)
        ))

        XCTAssertEqual(part.messageReference, 0x2A)
        XCTAssertEqual(original[2], 0x2A)
        XCTAssertEqual(original[1] & 0x20, 0x20, "TP-SRR must request a status report")
        XCTAssertEqual(original[1] & 0x04, 0, "the first submit must not claim to be a retry")

        var expected = original
        expected[1] |= 0x04
        XCTAssertEqual(retry, expected, "a retry may change only TP-RD")
    }

    func testMultipartUsesStableConcatReferenceAndSequentialMessageReferences() throws {
        let parts = try PDUEncoder.encodeSubmit(
            to: "+639171234567", text: String(repeating: "A", count: 200),
            reference: 0x77, messageReferenceBase: 0xFE, requestStatusReport: true
        )

        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.map(\.messageReference), [0xFE, 0xFF])
        XCTAssertTrue(parts[0].hex.contains("050003770201"))
        XCTAssertTrue(parts[1].hex.contains("050003770202"))
    }

    func testStatusReportDecoder() throws {
        // SMSC omitted, SMS-STATUS-REPORT, MR=42, recipient=+63917123456,
        // two valid timestamps, and TP-ST=0 (delivered).
        let pdu = "00022A0B913619173254F6421020214365004210203143650000"
        let report = try PDUDecoder.decodeStatusReport(hex: pdu)

        XCTAssertEqual(report.messageReference, 42)
        XCTAssertEqual(report.recipient, "+63917123456")
        XCTAssertEqual(report.status, 0)
        XCTAssertTrue(report.isDelivered)
        XCTAssertTrue(report.isComplete)
        XCTAssertNotNil(report.serviceCentreTimestamp)
        XCTAssertNotNil(report.dischargeTime)
    }

    func testSMSOnlyRegistrationStatesAreAccepted() {
        let home = ATParsers.Registration(status: 6, lac: nil, cellID: nil, accessTechnology: 7)
        let roaming = ATParsers.Registration(status: 7, lac: nil, cellID: nil, accessTechnology: 7)

        XCTAssertTrue(home.isRegistered)
        XCTAssertTrue(home.isSMSOnly)
        XCTAssertFalse(home.isRoaming)
        XCTAssertTrue(roaming.isRegistered)
        XCTAssertTrue(roaming.isSMSOnly)
        XCTAssertTrue(roaming.isRoaming)
    }

    func testCMSErrorCodeParsingForTimeoutAndDuplicateRejection() {
        XCTAssertEqual(
            ATError.failure(command: "AT+CMGS", result: "+CMS ERROR: 332").cmsErrorCode,
            332
        )
        XCTAssertEqual(
            ATError.failure(command: "AT+CMGS", result: "+CMS ERROR: 197").cmsErrorCode,
            197
        )
        XCTAssertNil(ATError.failure(command: "AT+CMGS", result: "ERROR").cmsErrorCode)
    }

    func testPreparedPartsAndAttemptStateAreDurable() throws {
        try withTemporaryStore { store in
            let message = try store.enqueueOutgoing(
                to: "+639171234567", body: String(repeating: "B", count: 200),
                simNumber: "route", telegramRequestID: 123
            )
            let firstRead = try store.prepareOutgoingParts(
                messageID: message.id, to: message.sender, body: message.body,
                simIdentity: "sim-1"
            )
            let secondRead = try store.prepareOutgoingParts(
                messageID: message.id, to: message.sender, body: message.body,
                simIdentity: "sim-1"
            )

            XCTAssertEqual(firstRead, secondRead)
            XCTAssertEqual(firstRead.count, 2)

            let begun = try store.beginOutgoingPartAttempt(
                messageID: message.id, sequence: firstRead[0].sequence
            )
            XCTAssertEqual(begun.attempts, 1)
            try store.markOutgoingPartSubmitted(
                messageID: message.id, sequence: firstRead[0].sequence, modemReference: 17
            )

            let resumed = try store.outgoingParts(messageID: message.id)
            XCTAssertFalse(resumed[0].needsSubmission)
            XCTAssertTrue(resumed[1].needsSubmission)
            XCTAssertFalse(try store.allOutgoingPartsSubmitted(messageID: message.id))
        }
    }

    func testStatusReportResolvesAmbiguousSubmissionAndFinalizationIsIdempotent() throws {
        try withTemporaryStore { store in
            let message = try store.enqueueOutgoing(
                to: "+639171234567", body: "hello", simNumber: "route",
                telegramRequestID: 123
            )
            let part = try XCTUnwrap(store.prepareOutgoingParts(
                messageID: message.id, to: message.sender, body: message.body,
                simIdentity: "sim-1"
            ).first)
            _ = try store.beginOutgoingPartAttempt(messageID: message.id, sequence: part.sequence)
            try store.markOutgoingPartAmbiguous(
                messageID: message.id, sequence: part.sequence, error: "+CMS ERROR: 332"
            )

            let match = try XCTUnwrap(store.recordOutgoingStatusReport(
                simIdentity: "sim-1", messageReference: part.messageReference,
                recipient: message.sender, serviceCentreTimestamp: Date(), status: 0
            ))
            XCTAssertEqual(match.messageID, message.id)
            XCTAssertTrue(match.allPartsSubmitted)
            XCTAssertEqual(try store.outgoingParts(messageID: message.id).first?.state, .reported)

            XCTAssertTrue(try store.markOutgoingSent(id: message.id, parts: 1))
            XCTAssertFalse(try store.markOutgoingSent(id: message.id, parts: 1))
            XCTAssertEqual(try store.message(id: message.id)?.forwardAttempts, 1)
        }
    }

    func testMessageReferenceCounterAdvancesAcrossMessages() throws {
        try withTemporaryStore { store in
            let first = try store.enqueueOutgoing(
                to: "+639171234567", body: String(repeating: "C", count: 200),
                simNumber: "route", telegramRequestID: nil
            )
            let firstParts = try store.prepareOutgoingParts(
                messageID: first.id, to: first.sender, body: first.body, simIdentity: "sim-1"
            )
            let second = try store.enqueueOutgoing(
                to: "+639171234567", body: "next", simNumber: "route", telegramRequestID: nil
            )
            let secondPart = try XCTUnwrap(store.prepareOutgoingParts(
                messageID: second.id, to: second.sender, body: second.body, simIdentity: "sim-1"
            ).first)

            XCTAssertEqual(
                secondPart.messageReference,
                firstParts[0].messageReference &+ UInt8(firstParts.count)
            )
        }
    }

    func testExistingDatabaseMigratesOutgoingPartTables() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMSRelayMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try Database(path: directory.appendingPathComponent("legacy.sqlite").path)
        try database.exec("""
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fingerprint TEXT NOT NULL UNIQUE,
            sender TEXT NOT NULL,
            body TEXT NOT NULL,
            sent_at REAL,
            received_at REAL NOT NULL,
            sim_number TEXT,
            encoding TEXT NOT NULL,
            part_count INTEGER NOT NULL DEFAULT 1,
            part_total INTEGER NOT NULL DEFAULT 1,
            pdus TEXT NOT NULL,
            forward_status TEXT NOT NULL DEFAULT 'pending',
            forward_attempts INTEGER NOT NULL DEFAULT 0,
            forwarded_at REAL,
            forward_error TEXT,
            next_attempt_at REAL
        );
        """)

        let store = try MessageStore(database: database)
        let message = try store.enqueueOutgoing(
            to: "+639171234567", body: "migrated", simNumber: "route", telegramRequestID: nil
        )
        XCTAssertEqual(try store.prepareOutgoingParts(
            messageID: message.id, to: message.sender, body: message.body, simIdentity: "sim-1"
        ).count, 1)
    }

    func testCrashAfterAttemptPreservesTEReferenceAndRequestsDuplicateRejection() throws {
        try withTemporaryStore { store in
            let message = try store.enqueueOutgoing(
                to: "+639171234567", body: "crash-safe", simNumber: "route", telegramRequestID: nil
            )
            let original = try XCTUnwrap(store.prepareOutgoingParts(
                messageID: message.id, to: message.sender, body: message.body,
                simIdentity: "sim-1"
            ).first)

            // Simulate a process disappearing after CMGS began but before it could persist OK/332.
            _ = try store.beginOutgoingPartAttempt(messageID: message.id, sequence: original.sequence)
            XCTAssertTrue(try store.markOutgoingPartTransmitting(
                messageID: message.id, sequence: original.sequence
            ))
            let resumed = try store.beginOutgoingPartAttempt(
                messageID: message.id, sequence: original.sequence
            )
            XCTAssertEqual(resumed.attempts, 2)
            XCTAssertEqual(resumed.state, .transmitting)

            let firstBytes = try XCTUnwrap(PDUDecoder.hexToBytes(original.pdu))
            let retryBytes = try XCTUnwrap(PDUDecoder.hexToBytes(
                PDUEncoder.settingRejectDuplicates(in: resumed.pdu)
            ))
            XCTAssertEqual(firstBytes[2], retryBytes[2], "the TE-side TP-MR must survive a crash")
            XCTAssertEqual(retryBytes[1] & 0x04, 0x04, "resumed submit must request TP-RD")
        }
    }

    func testManualRetryKeepsFailedPartsButSendAgainCreatesFreshParts() throws {
        try withTemporaryStore { store in
            let message = try store.enqueueOutgoing(
                to: "+639171234567", body: "again", simNumber: "route", telegramRequestID: nil
            )
            let original = try XCTUnwrap(store.prepareOutgoingParts(
                messageID: message.id, to: message.sender, body: message.body,
                simIdentity: "sim-1"
            ).first)
            _ = try store.beginOutgoingPartAttempt(messageID: message.id, sequence: original.sequence)
            try store.markOutgoingPartAmbiguous(
                messageID: message.id, sequence: original.sequence, error: "+CMS ERROR: 332"
            )
            _ = try store.markFailed(
                id: message.id, error: "+CMS ERROR: 332", nextAttempt: nil, gaveUp: true
            )

            try store.requeue(id: message.id)
            XCTAssertEqual(try store.outgoingParts(messageID: message.id).first?.pdu, original.pdu)

            _ = try store.markOutgoingSent(id: message.id, parts: 1)
            try store.requeue(id: message.id)
            XCTAssertEqual(try store.outgoingParts(messageID: message.id).first?.pdu, original.pdu)
            let queued = try store.dueOutgoing(limit: 10)
            XCTAssertEqual(queued.count, 1)
            XCTAssertNotEqual(queued[0].id, message.id)
        }
    }

    func testOutgoingClaimAllowsOnlyOneModemOwner() throws {
        try withTemporaryStore { store in
            let message = try store.enqueueOutgoing(
                to: "+639171234567", body: "claim", simNumber: nil, telegramRequestID: nil
            )
            let now = Date()
            XCTAssertTrue(try store.claimOutgoing(
                id: message.id, owner: "modem-a", now: now, lease: 300
            ))
            XCTAssertFalse(try store.claimOutgoing(
                id: message.id, owner: "modem-b", now: now, lease: 300
            ))
            XCTAssertTrue(try store.renewOutgoingClaim(
                id: message.id, owner: "modem-a", now: now, lease: 300
            ))
            try store.releaseOutgoingClaim(id: message.id, owner: "modem-a")
            XCTAssertTrue(try store.claimOutgoing(
                id: message.id, owner: "modem-b", now: now, lease: 300
            ))
        }
    }

    func testUntargetedMessageIsPinnedToClaimingModem() throws {
        try withTemporaryStore { store in
            let message = try store.enqueueOutgoing(
                to: "+639171234567", body: "pin", simNumber: nil, telegramRequestID: nil
            )
            XCTAssertTrue(try store.claimOutgoing(id: message.id, owner: "owner-a"))
            XCTAssertTrue(try store.pinOutgoingRoute(
                id: message.id, routeKey: "sim-a", owner: "owner-a"
            ))
            try store.releaseOutgoingClaim(id: message.id, owner: "owner-a")

            XCTAssertEqual(
                try store.dueOutgoing(
                    routeKey: "sim-a", limit: 10, includeUntargeted: false
                ).map(\.id),
                [message.id]
            )
            XCTAssertTrue(try store.dueOutgoing(
                routeKey: "sim-b", limit: 10, includeUntargeted: true
            ).isEmpty)
        }
    }

    func testLegacyNumberRouteIsReboundToStableSIMIdentity() throws {
        try withTemporaryStore { store in
            let legacyNumber = "+639180000000"
            let message = try store.enqueueOutgoing(
                to: "+639171234567", body: "legacy", simNumber: legacyNumber,
                telegramRequestID: nil
            )
            XCTAssertTrue(try store.claimOutgoing(id: message.id, owner: "owner-a"))
            XCTAssertTrue(try store.bindOutgoingRoute(
                id: message.id, routeKey: "iccid:1234",
                acceptedRouteKeys: ["iccid:1234", legacyNumber], owner: "owner-a"
            ))
            try store.releaseOutgoingClaim(id: message.id, owner: "owner-a")
            XCTAssertEqual(
                try store.dueOutgoing(
                    routeKeys: ["iccid:1234"], limit: 10, includeUntargeted: false
                ).map(\.id),
                [message.id]
            )
        }
    }

    func testResolvedPartCannotEnterTransmittingStateAgain() throws {
        try withTemporaryStore { store in
            let message = try store.enqueueOutgoing(
                to: "+639171234567", body: "resolved", simNumber: "route", telegramRequestID: nil
            )
            let part = try XCTUnwrap(store.prepareOutgoingParts(
                messageID: message.id, to: message.sender, body: message.body,
                simIdentity: "sim-1"
            ).first)
            _ = try store.beginOutgoingPartAttempt(messageID: message.id, sequence: part.sequence)
            try store.markOutgoingPartSubmitted(
                messageID: message.id, sequence: part.sequence, modemReference: 7
            )

            XCTAssertFalse(try store.markOutgoingPartTransmitting(
                messageID: message.id, sequence: part.sequence
            ))
        }
    }

    func testManualRetryCannotClearActiveSendLease() throws {
        try withTemporaryStore { store in
            let message = try store.enqueueOutgoing(
                to: "+639171234567", body: "busy", simNumber: nil, telegramRequestID: nil
            )
            XCTAssertTrue(try store.claimOutgoing(id: message.id, owner: "modem-a"))
            XCTAssertThrowsError(try store.requeue(id: message.id))
            XCTAssertFalse(try store.claimOutgoing(id: message.id, owner: "modem-b"))
        }
    }

    func testMultipartAssemblyDoesNotMixSIMRoutesAndKeepsDisplayLabel() throws {
        try withTemporaryStore { store in
            func incoming(_ text: String, sequence: Int, sim: String, display: String, pdu: String) -> IncomingSMS {
                IncomingSMS(
                    pdu: pdu,
                    decoded: SMSDeliver(
                        smsc: nil, sender: "+639171111111", protocolID: 0, encoding: .gsm7,
                        timestamp: nil, timezoneOffset: nil,
                        concat: ConcatInfo(reference: 9, total: 2, sequence: sequence),
                        text: text, hasUserDataHeader: true
                    ),
                    simNumber: sim, simDisplay: display
                )
            }

            XCTAssertEqual(
                try store.ingest(
                    incoming("A1", sequence: 1, sim: "iccid:a", display: "+63001", pdu: "AA"),
                    forwardingEnabled: true
                ),
                .partStored(missing: 1)
            )
            XCTAssertEqual(
                try store.ingest(
                    incoming("B2", sequence: 2, sim: "iccid:b", display: "+63002", pdu: "BB"),
                    forwardingEnabled: true
                ),
                .partStored(missing: 1)
            )
            let result = try store.ingest(
                incoming("A2", sequence: 2, sim: "iccid:a", display: "+63001", pdu: "CC"),
                forwardingEnabled: true
            )
            guard case .stored(let assembled) = result else {
                return XCTFail("expected SIM A multipart message to assemble")
            }
            XCTAssertEqual(assembled.body, "A1A2")
            XCTAssertEqual(assembled.simNumber, "iccid:a")
            XCTAssertEqual(assembled.simDisplay, "+63001")
        }
    }

    func testDelayedStatusReportUsesModemReferenceAndSMSCSubmissionTime() throws {
        try withTemporaryStore { store in
            let recipient = "+639171234567"
            let oldDate = Date().addingTimeInterval(-3600)
            let newDate = Date()

            let oldMessage = try store.enqueueOutgoing(
                to: recipient, body: "old", simNumber: "route", telegramRequestID: nil
            )
            let oldPart = try XCTUnwrap(store.prepareOutgoingParts(
                messageID: oldMessage.id, to: recipient, body: oldMessage.body,
                simIdentity: "sim-1"
            ).first)
            _ = try store.beginOutgoingPartAttempt(messageID: oldMessage.id, sequence: oldPart.sequence)
            try store.markOutgoingPartSubmitted(
                messageID: oldMessage.id, sequence: oldPart.sequence, modemReference: 42, at: oldDate
            )

            let newMessage = try store.enqueueOutgoing(
                to: recipient, body: "new", simNumber: "route", telegramRequestID: nil
            )
            let newPart = try XCTUnwrap(store.prepareOutgoingParts(
                messageID: newMessage.id, to: recipient, body: newMessage.body,
                simIdentity: "sim-1"
            ).first)
            _ = try store.beginOutgoingPartAttempt(messageID: newMessage.id, sequence: newPart.sequence)
            try store.markOutgoingPartSubmitted(
                messageID: newMessage.id, sequence: newPart.sequence, modemReference: 42, at: newDate
            )

            let match = try XCTUnwrap(store.recordOutgoingStatusReport(
                simIdentity: "sim-1", messageReference: 42, recipient: recipient,
                serviceCentreTimestamp: oldDate, status: 0
            ))
            XCTAssertEqual(match.messageID, oldMessage.id)
            XCTAssertEqual(try store.outgoingParts(messageID: newMessage.id).first?.state, .submitted)
        }
    }

    func testAmbiguousStatusReportRequiresUniqueTimestampCandidate() throws {
        try withTemporaryStore { store in
            let recipient = "+639171234567"
            for body in ["one", "two"] {
                let message = try store.enqueueOutgoing(
                    to: recipient, body: body, simNumber: "route", telegramRequestID: nil
                )
                let part = try XCTUnwrap(store.prepareOutgoingParts(
                    messageID: message.id, to: recipient, body: body, simIdentity: "sim-1"
                ).first)
                _ = try store.beginOutgoingPartAttempt(messageID: message.id, sequence: part.sequence)
                try store.markOutgoingPartAmbiguous(
                    messageID: message.id, sequence: part.sequence, error: "+CMS ERROR: 332"
                )
            }

            XCTAssertNil(try store.recordOutgoingStatusReport(
                simIdentity: "sim-1", messageReference: 99, recipient: recipient,
                serviceCentreTimestamp: Date(), status: 0
            ))
        }
    }

    func testLateReportRevivesRemainingMultipartSegments() throws {
        try withTemporaryStore { store in
            let message = try store.enqueueOutgoing(
                to: "+639171234567", body: String(repeating: "D", count: 200),
                simNumber: "iccid:sim-1", telegramRequestID: nil
            )
            let parts = try store.prepareOutgoingParts(
                messageID: message.id, to: message.sender, body: message.body,
                simIdentity: "iccid:sim-1"
            )
            _ = try store.beginOutgoingPartAttempt(
                messageID: message.id, sequence: parts[0].sequence
            )
            try store.markOutgoingPartAmbiguous(
                messageID: message.id, sequence: parts[0].sequence, error: "+CMS ERROR: 332"
            )
            _ = try store.markFailed(
                id: message.id, error: "+CMS ERROR: 332", nextAttempt: nil, gaveUp: true
            )

            let match = try XCTUnwrap(store.recordOutgoingStatusReport(
                simIdentity: "iccid:sim-1", messageReference: 99,
                recipient: message.sender, serviceCentreTimestamp: Date(), status: 0
            ))
            XCTAssertFalse(match.allPartsSubmitted)
            XCTAssertTrue(try store.reviveOutgoingAfterStatusReport(messageID: message.id))
            XCTAssertEqual(
                try store.dueOutgoing(
                    routeKeys: ["iccid:sim-1"], limit: 10
                ).map(\.id),
                [message.id]
            )
            XCTAssertTrue(try store.outgoingParts(messageID: message.id)[1].needsSubmission)
        }
    }

    func testDatabaseTransactionBlocksInterleavedConnectionWrites() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMSRelayTransactionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try Database(path: directory.appendingPathComponent("test.sqlite").path)
        try database.exec("CREATE TABLE events (value INTEGER)")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let transactionDone = DispatchSemaphore(value: 0)
        let competingWriteDone = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            try! database.transaction {
                try database.run("INSERT INTO events VALUES (1)")
                entered.signal()
                release.wait()
                try database.run("INSERT INTO events VALUES (3)")
            }
            transactionDone.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            try! database.run("INSERT INTO events VALUES (2)")
            competingWriteDone.signal()
        }
        XCTAssertEqual(competingWriteDone.wait(timeout: .now() + 0.1), .timedOut)
        release.signal()
        XCTAssertEqual(transactionDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(competingWriteDone.wait(timeout: .now() + 2), .success)

        let values: [Int] = try database.withStatement("SELECT value FROM events ORDER BY rowid") { s in
            var result: [Int] = []
            while try s.step() { result.append(s.int(0)) }
            return result
        }
        XCTAssertEqual(values, [1, 3, 2])
    }

    private func withTemporaryStore(_ body: (MessageStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMSRelayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try Database(path: directory.appendingPathComponent("test.sqlite").path)
        let store = try MessageStore(database: database)
        try body(store)
    }
}
