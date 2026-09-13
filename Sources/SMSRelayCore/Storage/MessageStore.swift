import CryptoKit
import Foundation

public enum IngestResult: Sendable, Equatable {
    /// A complete message (single-part, or the last piece of a multipart) was stored.
    case stored(StoredMessage)
    /// A fragment was stored; still waiting on `missing` more parts.
    case partStored(missing: Int)
    /// Already in the database (same PDU seen before).
    case duplicate
}

/// SQLite persistence for messages, multipart fragments and the forwarding queue.
public final class MessageStore: @unchecked Sendable {
    private let db: Database

    public init(database: Database) throws {
        db = database
        try migrate()
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS messages (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            fingerprint      TEXT    NOT NULL UNIQUE,
            sender           TEXT    NOT NULL,
            body             TEXT    NOT NULL,
            sent_at          REAL,
            received_at      REAL    NOT NULL,
            sim_number       TEXT,
            encoding         TEXT    NOT NULL,
            part_count       INTEGER NOT NULL DEFAULT 1,
            part_total       INTEGER NOT NULL DEFAULT 1,
            pdus             TEXT    NOT NULL,
            forward_status   TEXT    NOT NULL DEFAULT 'pending',
            forward_attempts INTEGER NOT NULL DEFAULT 0,
            forwarded_at     REAL,
            forward_error    TEXT,
            next_attempt_at  REAL,
            outgoing_claim_owner TEXT,
            outgoing_claim_until REAL,
            sim_display      TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_messages_forward ON messages(forward_status, next_attempt_at);

        CREATE TABLE IF NOT EXISTS parts (
            fingerprint  TEXT    PRIMARY KEY,
            sender       TEXT    NOT NULL,
            ref          INTEGER NOT NULL,
            total        INTEGER NOT NULL,
            seq          INTEGER NOT NULL,
            text         TEXT    NOT NULL,
            pdu          TEXT    NOT NULL,
            sent_at      REAL,
            received_at  REAL    NOT NULL,
            sim_number   TEXT,
            sim_display  TEXT,
            encoding     TEXT    NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_parts_group ON parts(sender, ref, total);

        CREATE TABLE IF NOT EXISTS settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS tg_refs (
            tg_message_id INTEGER PRIMARY KEY,
            chat_id       TEXT    NOT NULL,
            message_id    INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS outgoing_parts (
            message_id       INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            sequence         INTEGER NOT NULL,
            total            INTEGER NOT NULL,
            pdu              TEXT    NOT NULL,
            tpdu_length      INTEGER NOT NULL,
            tp_mr            INTEGER NOT NULL,
            sim_identity     TEXT    NOT NULL,
            attempts         INTEGER NOT NULL DEFAULT 0,
            submit_state     TEXT    NOT NULL DEFAULT 'pending',
            modem_mr         INTEGER,
            delivery_status  INTEGER,
            attempted_at      REAL,
            submitted_at     REAL,
            reported_at      REAL,
            last_error       TEXT,
            PRIMARY KEY (message_id, sequence)
        );
        CREATE INDEX IF NOT EXISTS idx_outgoing_parts_report
            ON outgoing_parts(sim_identity, tp_mr, submit_state);
        CREATE INDEX IF NOT EXISTS idx_outgoing_parts_modem_report
            ON outgoing_parts(sim_identity, modem_mr, submit_state);

        CREATE TABLE IF NOT EXISTS sms_mr_counters (
            sim_identity TEXT PRIMARY KEY,
            next_mr      INTEGER NOT NULL
        );
        """)
        // v0.2: outgoing SMS share the table.
        let columns: [String] = try db.withStatement("PRAGMA table_info(messages)") { s in
            var out: [String] = []
            while try s.step() { out.append(s.text(1) ?? "") }
            return out
        }
        if !columns.contains("direction") {
            try db.exec("ALTER TABLE messages ADD COLUMN direction TEXT NOT NULL DEFAULT 'in'")
        }
        if !columns.contains("tg_request_id") {
            try db.exec("ALTER TABLE messages ADD COLUMN tg_request_id INTEGER")
        }
        if !columns.contains("outgoing_claim_owner") {
            try db.exec("ALTER TABLE messages ADD COLUMN outgoing_claim_owner TEXT")
        }
        if !columns.contains("outgoing_claim_until") {
            try db.exec("ALTER TABLE messages ADD COLUMN outgoing_claim_until REAL")
        }
        if !columns.contains("sim_display") {
            try db.exec("ALTER TABLE messages ADD COLUMN sim_display TEXT")
        }
        let partColumns: [String] = try db.withStatement("PRAGMA table_info(parts)") { s in
            var out: [String] = []
            while try s.step() { out.append(s.text(1) ?? "") }
            return out
        }
        if !partColumns.contains("sim_display") {
            try db.exec("ALTER TABLE parts ADD COLUMN sim_display TEXT")
        }
        let outgoingColumns: [String] = try db.withStatement("PRAGMA table_info(outgoing_parts)") { s in
            var out: [String] = []
            while try s.step() { out.append(s.text(1) ?? "") }
            return out
        }
        if !outgoingColumns.contains("attempted_at") {
            try db.exec("ALTER TABLE outgoing_parts ADD COLUMN attempted_at REAL")
        }
    }

    // MARK: - Ingest

    public static func fingerprint(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func ingest(_ sms: IncomingSMS, forwardingEnabled: Bool) throws -> IngestResult {
        let initialStatus: ForwardStatus = forwardingEnabled ? .pending : .disabled
        let fp = Self.fingerprint(sms.pdu)
        let d = sms.decoded

        guard let concat = d.concat, concat.total > 1 else {
            return try db.transaction {
                let inserted = try insertMessage(
                    fingerprint: fp, sender: d.sender, body: d.text, sentAt: d.timestamp,
                    receivedAt: sms.receivedAt, simNumber: sms.simNumber, simDisplay: sms.simDisplay,
                    encoding: d.encoding.rawValue,
                    partCount: 1, partTotal: 1, pdus: [sms.pdu], status: initialStatus
                )
                guard let inserted else { return .duplicate }
                return .stored(inserted)
            }
        }

        return try db.transaction {
            let changed = try db.runChanges("""
            INSERT OR IGNORE INTO parts
                (fingerprint, sender, ref, total, seq, text, pdu, sent_at, received_at, sim_number, sim_display, encoding)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(fp), .text(d.sender), .int(concat.reference), .int(concat.total), .int(concat.sequence),
                .text(d.text), .text(sms.pdu), .date(d.timestamp), .date(sms.receivedAt),
                .optionalText(sms.simNumber), .optionalText(sms.simDisplay), .text(d.encoding.rawValue),
            ])
            guard changed > 0 else { return .duplicate }

            let have = try db.scalarInt(
                """
                SELECT COUNT(*) FROM parts
                WHERE sender = ? AND ref = ? AND total = ?
                  AND COALESCE(sim_number, '') = COALESCE(?, '')
                """,
                [.text(d.sender), .int(concat.reference), .int(concat.total), .optionalText(sms.simNumber)]
            )
            if have < concat.total {
                return .partStored(missing: concat.total - have)
            }
            guard let msg = try assembleGroup(
                sender: d.sender, ref: concat.reference, total: concat.total,
                simNumber: sms.simNumber, status: initialStatus
            ) else {
                return .duplicate
            }
            return .stored(msg)
        }
    }

    /// Joins the available fragments of a group into one message and removes them from `parts`.
    private func assembleGroup(sender: String, ref: Int, total: Int, simNumber: String?,
                               status: ForwardStatus) throws -> StoredMessage? {
        struct Frag {
            let fp: String
            let seq: Int
            let text: String
            let pdu: String
            let sentAt: Date?
            let receivedAt: Date
            let sim: String?
            let simDisplay: String?
            let enc: String
        }
        let frags: [Frag] = try db.withStatement("""
        SELECT fingerprint, seq, text, pdu, sent_at, received_at, sim_number, sim_display, encoding
        FROM parts
        WHERE sender = ? AND ref = ? AND total = ?
          AND COALESCE(sim_number, '') = COALESCE(?, '')
        ORDER BY seq ASC
        """) { s in
            try s.bind([.text(sender), .int(ref), .int(total), .optionalText(simNumber)])
            var out: [Frag] = []
            while try s.step() {
                out.append(Frag(fp: s.text(0) ?? "", seq: s.int(1), text: s.text(2) ?? "", pdu: s.text(3) ?? "",
                                sentAt: s.date(4), receivedAt: s.date(5) ?? Date(), sim: s.text(6),
                                simDisplay: s.text(7), enc: s.text(8) ?? "gsm7"))
            }
            return out
        }
        guard let first = frags.first else { return nil }

        let combinedFP = Self.fingerprint(frags.map(\.fp).joined(separator: "|"))
        let body = frags.map(\.text).joined()
        let inserted = try insertMessage(
            fingerprint: combinedFP, sender: sender, body: body,
            sentAt: frags.compactMap(\.sentAt).min(), receivedAt: frags.map(\.receivedAt).max() ?? first.receivedAt,
            simNumber: first.sim, simDisplay: first.simDisplay, encoding: first.enc,
            partCount: frags.count, partTotal: total,
            pdus: frags.map(\.pdu), status: status
        )
        try db.run("""
        DELETE FROM parts WHERE sender = ? AND ref = ? AND total = ?
          AND COALESCE(sim_number, '') = COALESCE(?, '')
        """, [.text(sender), .int(ref), .int(total), .optionalText(simNumber)])
        return inserted
    }

    /// Flushes multipart groups that never completed so a partial message still gets forwarded.
    public func flushStaleParts(olderThan age: TimeInterval, forwardingEnabled: Bool) throws -> [StoredMessage] {
        let cutoff = Date().addingTimeInterval(-age)
        let groups: [(String, Int, Int, String?)] = try db.withStatement("""
        SELECT sender, ref, total, sim_number FROM parts
        GROUP BY sender, ref, total, sim_number HAVING MAX(received_at) < ?
        """) { s in
            try s.bind([.date(cutoff)])
            var out: [(String, Int, Int, String?)] = []
            while try s.step() { out.append((s.text(0) ?? "", s.int(1), s.int(2), s.text(3))) }
            return out
        }
        var flushed: [StoredMessage] = []
        for (sender, ref, total, simNumber) in groups {
            if let m = try db.transaction({
                try assembleGroup(
                    sender: sender, ref: ref, total: total, simNumber: simNumber,
                    status: forwardingEnabled ? .pending : .disabled
                )
            }) {
                flushed.append(m)
            }
        }
        return flushed
    }

    private func insertMessage(fingerprint: String, sender: String, body: String, sentAt: Date?, receivedAt: Date,
                               simNumber: String?, simDisplay: String?, encoding: String,
                               partCount: Int, partTotal: Int,
                               pdus: [String], status: ForwardStatus) throws -> StoredMessage? {
        let pdusJSON = String(decoding: try JSONEncoder().encode(pdus), as: UTF8.self)
        let changed = try db.runChanges("""
        INSERT OR IGNORE INTO messages
            (fingerprint, sender, body, sent_at, received_at, sim_number, sim_display,
             encoding, part_count, part_total, pdus, forward_status)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """, [
            .text(fingerprint), .text(sender), .text(body), .date(sentAt), .date(receivedAt),
            .optionalText(simNumber), .optionalText(simDisplay), .text(encoding),
            .int(partCount), .int(partTotal), .text(pdusJSON), .text(status.rawValue),
        ])
        guard changed > 0 else { return nil }
        return try message(id: db.lastInsertRowID())
    }

    // MARK: - Queries

    private static let columns = """
    id, sender, body, sent_at, received_at, sim_number, encoding, part_count,
    forward_status, forward_attempts, forwarded_at, forward_error, next_attempt_at, direction, tg_request_id,
    sim_display
    """

    private func row(_ s: Statement) -> StoredMessage {
        StoredMessage(
            id: s.int64(0), direction: Direction(rawValue: s.text(13) ?? "in") ?? .incoming,
            sender: s.text(1) ?? "", body: s.text(2) ?? "",
            sentAt: s.date(3), receivedAt: s.date(4) ?? Date(), simNumber: s.text(5),
            simDisplay: s.text(15), encoding: s.text(6) ?? "", partCount: s.int(7),
            forwardStatus: ForwardStatus(rawValue: s.text(8) ?? "") ?? .pending,
            forwardAttempts: s.int(9), forwardedAt: s.date(10), forwardError: s.text(11), nextAttemptAt: s.date(12),
            telegramRequestID: s.isNull(14) ? nil : s.int64(14)
        )
    }

    // MARK: - Outgoing SMS

    /// Queues an SMS to be sent through the modem. `telegramRequestID` lets the result be
    /// posted as a Telegram reply to the message that asked for it.
    public func enqueueOutgoing(to number: String, body: String, simNumber: String?, telegramRequestID: Int64?) throws -> StoredMessage {
        let fp = Self.fingerprint("out|\(UUID().uuidString)")
        try db.run("""
        INSERT INTO messages
            (fingerprint, sender, body, sent_at, received_at, sim_number, encoding, part_count, part_total, pdus,
             forward_status, direction, tg_request_id)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [
            .text(fp), .text(number), .text(body), .null, .date(Date()), .optionalText(simNumber),
            .text(GSM7.canEncode(body) ? "gsm7" : "ucs2"), .int(1), .int(1), .text("[]"),
            .text(ForwardStatus.pending.rawValue), .text(Direction.outgoing.rawValue),
            telegramRequestID.map { .int($0) } ?? .null,
        ])
        guard let m = try message(id: db.lastInsertRowID()) else { throw Database.Error(message: "enqueue failed") }
        return m
    }

    /// Creates immutable SMS-SUBMIT PDUs before the first byte is sent. Subsequent calls return
    /// the existing rows, including after a crash, so the TE PDU and multipart UDH never change.
    public func prepareOutgoingParts(messageID: Int64, to number: String, body: String,
                                     simIdentity: String) throws -> [OutgoingPart] {
        let existing = try outgoingParts(messageID: messageID)
        if !existing.isEmpty { return existing }

        return try db.transaction {
            // A second modem loop may have won between the initial read and BEGIN IMMEDIATE.
            let raced = try outgoingParts(messageID: messageID)
            if !raced.isEmpty { return raced }

            let nextMR: Int? = try db.withStatement(
                "SELECT next_mr FROM sms_mr_counters WHERE sim_identity = ?"
            ) { s in
                try s.bind([.text(simIdentity)])
                return try s.step() ? s.int(0) : nil
            }
            let base = UInt8(nextMR ?? Int.random(in: 0...255))
            let concatReference = UInt8.random(in: 0...255)
            let encoded = try PDUEncoder.encodeSubmit(
                to: number, text: body, reference: concatReference,
                messageReferenceBase: base, requestStatusReport: true
            )

            for part in encoded {
                try db.run("""
                INSERT INTO outgoing_parts
                    (message_id, sequence, total, pdu, tpdu_length, tp_mr, sim_identity)
                VALUES (?,?,?,?,?,?,?)
                """, [
                    .int(messageID), .int(part.sequence), .int(part.total), .text(part.hex),
                    .int(part.tpduLength), .int(Int(part.messageReference)), .text(simIdentity),
                ])
            }

            let next = (Int(base) + encoded.count) & 0xFF
            try db.run("""
            INSERT INTO sms_mr_counters (sim_identity, next_mr) VALUES (?,?)
            ON CONFLICT(sim_identity) DO UPDATE SET next_mr = excluded.next_mr
            """, [.text(simIdentity), .int(next)])

            let pdus = String(decoding: try JSONEncoder().encode(encoded.map(\.hex)), as: UTF8.self)
            try db.run("""
            UPDATE messages SET pdus = ?, part_count = ?, part_total = ? WHERE id = ? AND direction = 'out'
            """, [.text(pdus), .int(encoded.count), .int(encoded.count), .int(messageID)])
            return try outgoingParts(messageID: messageID)
        }
    }

    public func outgoingParts(messageID: Int64) throws -> [OutgoingPart] {
        try db.withStatement("""
        SELECT message_id, sequence, total, pdu, tpdu_length, tp_mr, attempts, submit_state,
               modem_mr, delivery_status, last_error
        FROM outgoing_parts WHERE message_id = ? ORDER BY sequence
        """) { s in
            try s.bind([.int(messageID)])
            var result: [OutgoingPart] = []
            while try s.step() { result.append(outgoingPartRow(s)) }
            return result
        }
    }

    /// Must be called before writing AT+CMGS. If the process dies after network acceptance,
    /// the durable attempts value ensures the next run requests TP-RD (subject to modem support).
    public func beginOutgoingPartAttempt(messageID: Int64, sequence: Int) throws -> OutgoingPart {
        try db.run("""
        UPDATE outgoing_parts SET attempts = attempts + 1, attempted_at = ?, last_error = NULL
        WHERE message_id = ? AND sequence = ? AND submit_state IN ('pending','transmitting','ambiguous')
        """, [.date(Date()), .int(messageID), .int(sequence)])
        guard let part = try outgoingPart(messageID: messageID, sequence: sequence) else {
            throw Database.Error(message: "outgoing part \(messageID)/\(sequence) not found")
        }
        return part
    }

    public func markOutgoingPartTransmitting(messageID: Int64, sequence: Int) throws -> Bool {
        try db.runChanges("""
        UPDATE outgoing_parts SET submit_state = 'transmitting'
        WHERE message_id = ? AND sequence = ? AND submit_state IN ('pending','transmitting','ambiguous')
        """, [.int(messageID), .int(sequence)]) > 0
    }

    public func markOutgoingPartAmbiguous(messageID: Int64, sequence: Int, error: String) throws {
        try db.run("""
        UPDATE outgoing_parts SET submit_state = 'ambiguous', last_error = ?
        WHERE message_id = ? AND sequence = ? AND submit_state != 'reported'
        """, [.text(error), .int(messageID), .int(sequence)])
    }

    public func markOutgoingPartSubmitted(messageID: Int64, sequence: Int, modemReference: Int?,
                                          at date: Date = Date()) throws {
        try db.run("""
        UPDATE outgoing_parts
        SET submit_state = CASE WHEN submit_state = 'reported' THEN 'reported' ELSE 'submitted' END,
            modem_mr = ?, submitted_at = ?, last_error = NULL
        WHERE message_id = ? AND sequence = ?
        """, [
            modemReference.map { .int($0) } ?? .null, .date(date), .int(messageID), .int(sequence),
        ])
    }

    public func allOutgoingPartsSubmitted(messageID: Int64) throws -> Bool {
        let total = try db.scalarInt("SELECT COUNT(*) FROM outgoing_parts WHERE message_id = ?", [.int(messageID)])
        guard total > 0 else { return false }
        let accepted = try db.scalarInt("""
        SELECT COUNT(*) FROM outgoing_parts
        WHERE message_id = ? AND submit_state IN ('submitted','reported')
        """, [.int(messageID)])
        return accepted == total
    }

    /// A late report can resolve the part that caused a message-level gave_up while later
    /// multipart segments still need submission.
    @discardableResult
    public func reviveOutgoingAfterStatusReport(messageID: Int64) throws -> Bool {
        let changed = try db.runChanges("""
        UPDATE messages
        SET forward_status = 'pending', forward_attempts = 0, forward_error = NULL,
            next_attempt_at = NULL
        WHERE id = ? AND direction = 'out' AND forward_status = 'gave_up'
          AND EXISTS (
              SELECT 1 FROM outgoing_parts
              WHERE message_id = messages.id
                AND submit_state IN ('pending','transmitting','ambiguous')
          )
        """, [.int(messageID)])
        return changed > 0
    }

    /// A status report proves that the SMSC accepted a matching submission. AT+CMGS modems
    /// normally replace the TP-MR supplied by the TE, so acknowledged sends are matched using
    /// the modem-returned MR. An in-flight/ambiguous send can only be matched by a unique
    /// recipient plus SMSC timestamp window.
    public func recordOutgoingStatusReport(simIdentity: String, messageReference: UInt8,
                                           recipient: String, serviceCentreTimestamp: Date?,
                                           status: Int,
                                           at date: Date = Date()) throws -> OutgoingStatusReportMatch? {
        let normalized = PDUEncoder.normalizeNumber(recipient) ?? recipient
        let window: TimeInterval = 5 * 60

        var match: (Int64, Int)?
        if let serviceCentreTimestamp {
            match = try db.withStatement("""
            SELECT p.message_id, p.sequence
            FROM outgoing_parts p
            JOIN messages m ON m.id = p.message_id
            WHERE p.sim_identity = ? AND p.modem_mr = ? AND m.sender = ?
              AND p.submit_state IN ('submitted','reported')
              AND ABS(COALESCE(p.submitted_at, p.attempted_at) - ?) <= ?
            ORDER BY ABS(COALESCE(p.submitted_at, p.attempted_at) - ?) ASC LIMIT 1
            """) { s in
                try s.bind([
                    .text(simIdentity), .int(Int(messageReference)), .text(normalized),
                    .date(serviceCentreTimestamp), .double(window), .date(serviceCentreTimestamp),
                ])
                return try s.step() ? (s.int64(0), s.int(1)) : nil
            }
        } else {
            match = try db.withStatement("""
            SELECT p.message_id, p.sequence
            FROM outgoing_parts p
            JOIN messages m ON m.id = p.message_id
            WHERE p.sim_identity = ? AND p.modem_mr = ? AND m.sender = ?
              AND p.submit_state IN ('submitted','reported')
            ORDER BY COALESCE(p.submitted_at, p.attempted_at) DESC LIMIT 1
            """) { s in
                try s.bind([.text(simIdentity), .int(Int(messageReference)), .text(normalized)])
                return try s.step() ? (s.int64(0), s.int(1)) : nil
            }
        }

        if match == nil, let serviceCentreTimestamp {
            let candidates: [(Int64, Int)] = try db.withStatement("""
            SELECT p.message_id, p.sequence
            FROM outgoing_parts p
            JOIN messages m ON m.id = p.message_id
            WHERE p.sim_identity = ? AND m.sender = ? AND p.attempts > 0
              AND p.submit_state IN ('transmitting','ambiguous')
              AND ABS(p.attempted_at - ?) <= ?
            ORDER BY ABS(p.attempted_at - ?) ASC LIMIT 2
            """) { s in
                try s.bind([
                    .text(simIdentity), .text(normalized), .date(serviceCentreTimestamp),
                    .double(window), .date(serviceCentreTimestamp),
                ])
                var rows: [(Int64, Int)] = []
                while try s.step() { rows.append((s.int64(0), s.int(1))) }
                return rows
            }
            if candidates.count == 1 { match = candidates[0] }
        }

        guard let (messageID, sequence) = match else { return nil }
        try db.run("""
        UPDATE outgoing_parts
        SET submit_state = 'reported', delivery_status = ?, reported_at = ?, last_error = NULL
        WHERE message_id = ? AND sequence = ?
        """, [.int(status), .date(date), .int(messageID), .int(sequence)])
        return OutgoingStatusReportMatch(
            messageID: messageID, sequence: sequence,
            allPartsSubmitted: try allOutgoingPartsSubmitted(messageID: messageID)
        )
    }

    private func outgoingPart(messageID: Int64, sequence: Int) throws -> OutgoingPart? {
        try db.withStatement("""
        SELECT message_id, sequence, total, pdu, tpdu_length, tp_mr, attempts, submit_state,
               modem_mr, delivery_status, last_error
        FROM outgoing_parts WHERE message_id = ? AND sequence = ?
        """) { s in
            try s.bind([.int(messageID), .int(sequence)])
            return try s.step() ? outgoingPartRow(s) : nil
        }
    }

    private func outgoingPartRow(_ s: Statement) -> OutgoingPart {
        OutgoingPart(
            messageID: s.int64(0), sequence: s.int(1), total: s.int(2), pdu: s.text(3) ?? "",
            tpduLength: s.int(4), messageReference: UInt8(clamping: s.int(5)), attempts: s.int(6),
            state: OutgoingPartState(rawValue: s.text(7) ?? "") ?? .pending,
            modemReference: s.isNull(8) ? nil : s.int(8),
            deliveryStatus: s.isNull(9) ? nil : s.int(9), lastError: s.text(10)
        )
    }

    public func dueOutgoing(limit: Int, now: Date = Date()) throws -> [StoredMessage] {
        try db.withStatement("""
        SELECT \(Self.columns) FROM messages
        WHERE direction = 'out' AND forward_status IN ('pending','failed')
          AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
        ORDER BY id ASC LIMIT ?
        """) { s in
            try s.bind([.date(now), .int(limit)])
            var out: [StoredMessage] = []
            while try s.step() { out.append(row(s)) }
            return out
        }
    }

    /// Outgoing messages routed to a specific modem (`sim_number` holds the route key). Rows with
    /// no route key are handled by the caller-designated primary so exactly one modem sends them.
    public func dueOutgoing(routeKey: String, limit: Int, includeUntargeted: Bool = false, now: Date = Date()) throws -> [StoredMessage] {
        try dueOutgoing(
            routeKeys: [routeKey], limit: limit, includeUntargeted: includeUntargeted, now: now
        )
    }

    public func dueOutgoing(routeKeys: [String], limit: Int, includeUntargeted: Bool = false,
                            now: Date = Date()) throws -> [StoredMessage] {
        let keys = routeKeys.filter { !$0.isEmpty }.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        guard !keys.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let targeted = "sim_number IN (\(placeholders))"
        let clause = includeUntargeted
            ? "(\(targeted) OR sim_number IS NULL OR sim_number = '')"
            : targeted
        return try db.withStatement("""
        SELECT \(Self.columns) FROM messages
        WHERE direction = 'out' AND forward_status IN ('pending','failed')
          AND \(clause)
          AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
        ORDER BY id ASC LIMIT ?
        """) { s in
            try s.bind(keys.map(SQLValue.text) + [.date(now), .int(limit)])
            var out: [StoredMessage] = []
            while try s.step() { out.append(row(s)) }
            return out
        }
    }

    /// Leases a queue row to one modem loop. This prevents a primary-modem change from
    /// submitting the same untargeted message on two physical modems concurrently.
    public func claimOutgoing(id: Int64, owner: String, now: Date = Date(),
                              lease: TimeInterval = 5 * 60) throws -> Bool {
        let changed = try db.runChanges("""
        UPDATE messages SET outgoing_claim_owner = ?, outgoing_claim_until = ?
        WHERE id = ? AND direction = 'out' AND forward_status IN ('pending','failed')
          AND (outgoing_claim_owner IS NULL OR outgoing_claim_until IS NULL
               OR outgoing_claim_until <= ? OR outgoing_claim_owner = ?)
        """, [
            .text(owner), .date(now.addingTimeInterval(lease)), .int(id), .date(now), .text(owner),
        ])
        return changed > 0
    }

    @discardableResult
    public func renewOutgoingClaim(id: Int64, owner: String, now: Date = Date(),
                                   lease: TimeInterval = 5 * 60) throws -> Bool {
        let changed = try db.runChanges("""
        UPDATE messages SET outgoing_claim_until = ?
        WHERE id = ? AND outgoing_claim_owner = ? AND direction = 'out'
          AND forward_status IN ('pending','failed')
        """, [.date(now.addingTimeInterval(lease)), .int(id), .text(owner)])
        return changed > 0
    }

    public func releaseOutgoingClaim(id: Int64, owner: String) throws {
        try db.run("""
        UPDATE messages SET outgoing_claim_owner = NULL, outgoing_claim_until = NULL
        WHERE id = ? AND outgoing_claim_owner = ?
        """, [.int(id), .text(owner)])
    }

    /// Once a primary modem accepts an untargeted row, keep every retry on that SIM.
    public func pinOutgoingRoute(id: Int64, routeKey: String, owner: String) throws -> Bool {
        try bindOutgoingRoute(
            id: id, routeKey: routeKey, acceptedRouteKeys: [], owner: owner
        )
    }

    /// Also upgrades legacy number/IMEI route keys after the matching modem claims them.
    public func bindOutgoingRoute(id: Int64, routeKey: String, acceptedRouteKeys: [String],
                                  owner: String) throws -> Bool {
        let aliases = acceptedRouteKeys.filter { !$0.isEmpty }.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        let aliasClause: String
        if aliases.isEmpty {
            aliasClause = ""
        } else {
            let placeholders = Array(repeating: "?", count: aliases.count).joined(separator: ",")
            aliasClause = " OR sim_number IN (\(placeholders))"
        }
        return try db.runChanges("""
        UPDATE messages SET sim_number = ?
        WHERE id = ? AND outgoing_claim_owner = ? AND direction = 'out'
          AND (sim_number IS NULL OR sim_number = ''\(aliasClause))
        """, [.text(routeKey), .int(id), .text(owner)] + aliases.map(SQLValue.text)) > 0
    }

    /// Records how many parts an outgoing SMS was split into once it has been sent.
    @discardableResult
    public func markOutgoingSent(id: Int64, parts: Int, at date: Date = Date()) throws -> Bool {
        let changed = try db.runChanges("""
        UPDATE messages SET forward_status = 'sent', forwarded_at = ?, sent_at = ?, part_count = ?, part_total = ?,
                            forward_error = NULL, next_attempt_at = NULL, forward_attempts = forward_attempts + 1,
                            outgoing_claim_owner = NULL, outgoing_claim_until = NULL
        WHERE id = ? AND direction = 'out' AND forward_status != 'sent'
        """, [.date(date), .date(date), .int(parts), .int(parts), .int(id)])
        return changed > 0
    }

    // MARK: - Telegram message references

    public func recordTelegramRefs(_ telegramMessageIDs: [Int64], chatID: String, messageID: Int64) throws {
        for tg in telegramMessageIDs {
            try db.run("INSERT OR REPLACE INTO tg_refs (tg_message_id, chat_id, message_id) VALUES (?,?,?)",
                       [.int(tg), .text(chatID), .int(messageID)])
        }
    }

    /// The SMS a Telegram message (one of our forwarded posts) corresponds to.
    public func message(forTelegramMessageID tg: Int64, chatID: String) throws -> StoredMessage? {
        let id: Int64? = try db.withStatement("SELECT message_id FROM tg_refs WHERE tg_message_id = ? AND chat_id = ?") { s in
            try s.bind([.int(tg), .text(chatID)])
            return try s.step() ? s.int64(0) : nil
        }
        guard let id else { return nil }
        return try message(id: id)
    }

    public func message(id: Int64) throws -> StoredMessage? {
        try db.withStatement("SELECT \(Self.columns) FROM messages WHERE id = ?") { s in
            try s.bind([.int(id)])
            return try s.step() ? row(s) : nil
        }
    }

    public func page(index: Int, size: Int, search: String = "") throws -> MessagePage {
        let q = search.trimmingCharacters(in: .whitespaces)
        let whereClause = q.isEmpty ? "" : "WHERE sender LIKE ? OR body LIKE ?"
        let like = "%\(q)%"
        let params: [SQLValue] = q.isEmpty ? [] : [.text(like), .text(like)]

        let total = try db.scalarInt("SELECT COUNT(*) FROM messages \(whereClause)", params)
        let pageCount = max(1, (total + size - 1) / size)
        let clamped = min(max(0, index), pageCount - 1)

        let items: [StoredMessage] = try db.withStatement(
            "SELECT \(Self.columns) FROM messages \(whereClause) ORDER BY id DESC LIMIT ? OFFSET ?"
        ) { s in
            try s.bind(params + [.int(size), .int(clamped * size)])
            var out: [StoredMessage] = []
            while try s.step() { out.append(row(s)) }
            return out
        }
        return MessagePage(items: items, pageIndex: clamped, pageSize: size, totalCount: total)
    }

    public struct Counts: Equatable, Sendable {
        public let total: Int
        public let pending: Int
        public let failed: Int
        public let sent: Int

        public init(total: Int, pending: Int, failed: Int, sent: Int) {
            self.total = total
            self.pending = pending
            self.failed = failed
            self.sent = sent
        }

        public static let zero = Counts(total: 0, pending: 0, failed: 0, sent: 0)
    }

    public func counts() throws -> Counts {
        try db.withStatement("""
        SELECT COUNT(*),
               SUM(forward_status IN ('pending','failed')),
               SUM(forward_status = 'gave_up'),
               SUM(forward_status = 'sent')
        FROM messages WHERE direction = 'in'
        """) { s in
            _ = try s.step()
            return Counts(total: s.int(0), pending: s.int(1), failed: s.int(2), sent: s.int(3))
        }
    }

    public func delete(id: Int64) throws {
        try db.run("DELETE FROM messages WHERE id = ?", [.int(id)])
    }

    // MARK: - Forwarding queue

    public func dueForForwarding(limit: Int, now: Date = Date()) throws -> [StoredMessage] {
        try db.withStatement("""
        SELECT \(Self.columns) FROM messages
        WHERE direction = 'in' AND forward_status IN ('pending','failed')
          AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
        ORDER BY id ASC LIMIT ?
        """) { s in
            try s.bind([.date(now), .int(limit)])
            var out: [StoredMessage] = []
            while try s.step() { out.append(row(s)) }
            return out
        }
    }

    public func markForwarded(id: Int64, at date: Date = Date()) throws {
        try db.run("""
        UPDATE messages SET forward_status = 'sent', forwarded_at = ?, forward_error = NULL, next_attempt_at = NULL,
                            forward_attempts = forward_attempts + 1
        WHERE id = ?
        """, [.date(date), .int(id)])
    }

    @discardableResult
    public func markFailed(id: Int64, error: String, nextAttempt: Date?, gaveUp: Bool) throws -> Bool {
        let changed = try db.runChanges("""
        UPDATE messages SET forward_status = ?, forward_error = ?, next_attempt_at = ?,
                            forward_attempts = forward_attempts + 1,
                            outgoing_claim_owner = NULL, outgoing_claim_until = NULL
        WHERE id = ? AND forward_status != 'sent'
        """, [.text(gaveUp ? ForwardStatus.gaveUp.rawValue : ForwardStatus.failed.rawValue),
              .text(error), .date(nextAttempt), .int(id)])
        return changed > 0
    }

    /// Push a message's next attempt out without counting it as a failure (e.g. Telegram 429).
    public func defer_(id: Int64, until date: Date) throws {
        try db.run("UPDATE messages SET next_attempt_at = ? WHERE id = ? AND forward_status IN ('pending','failed')",
                   [.date(date), .int(id)])
    }

    /// Manual retry / "forward now" from the UI.
    public func requeue(id: Int64) throws {
        try db.transaction {
            guard let prior = try message(id: id) else { return }
            let activelyClaimed = try db.scalarInt("""
            SELECT COUNT(*) FROM messages
            WHERE id = ? AND outgoing_claim_owner IS NOT NULL AND outgoing_claim_until > ?
            """, [.int(id), .date(Date())]) > 0
            guard !activelyClaimed else {
                throw Database.Error(message: "SMS is currently being sent")
            }
            if prior.direction == .outgoing, prior.forwardStatus == .sent {
                // Keep the original row and part references intact for delayed status reports.
                // "Send again" is a new queue item, not a mutation of the prior submission.
                _ = try enqueueOutgoing(
                    to: prior.sender, body: prior.body, simNumber: prior.simNumber,
                    telegramRequestID: nil
                )
                return
            }
            try db.run("""
            UPDATE messages SET forward_status = 'pending', forward_attempts = 0,
                                next_attempt_at = NULL, forward_error = NULL,
                                outgoing_claim_owner = NULL, outgoing_claim_until = NULL
            WHERE id = ?
            """, [.int(id)])
        }
    }

    // MARK: - Settings KV

    public func setting(_ key: String) throws -> String? {
        try db.withStatement("SELECT value FROM settings WHERE key = ?") { s in
            try s.bind([.text(key)])
            return try s.step() ? s.text(0) : nil
        }
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key), .text(value)])
    }
}
