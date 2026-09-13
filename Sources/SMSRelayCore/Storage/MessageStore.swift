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
            next_attempt_at  REAL
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
                    receivedAt: sms.receivedAt, simNumber: sms.simNumber, encoding: d.encoding.rawValue,
                    partCount: 1, partTotal: 1, pdus: [sms.pdu], status: initialStatus
                )
                guard let inserted else { return .duplicate }
                return .stored(inserted)
            }
        }

        return try db.transaction {
            try db.run("""
            INSERT OR IGNORE INTO parts (fingerprint, sender, ref, total, seq, text, pdu, sent_at, received_at, sim_number, encoding)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(fp), .text(d.sender), .int(concat.reference), .int(concat.total), .int(concat.sequence),
                .text(d.text), .text(sms.pdu), .date(d.timestamp), .date(sms.receivedAt),
                .optionalText(sms.simNumber), .text(d.encoding.rawValue),
            ])
            let changed = try db.scalarInt("SELECT changes()")
            guard changed > 0 else { return .duplicate }

            let have = try db.scalarInt(
                "SELECT COUNT(*) FROM parts WHERE sender = ? AND ref = ? AND total = ?",
                [.text(d.sender), .int(concat.reference), .int(concat.total)]
            )
            if have < concat.total {
                return .partStored(missing: concat.total - have)
            }
            guard let msg = try assembleGroup(sender: d.sender, ref: concat.reference, total: concat.total, status: initialStatus) else {
                return .duplicate
            }
            return .stored(msg)
        }
    }

    /// Joins the available fragments of a group into one message and removes them from `parts`.
    private func assembleGroup(sender: String, ref: Int, total: Int, status: ForwardStatus) throws -> StoredMessage? {
        struct Frag { let fp: String; let seq: Int; let text: String; let pdu: String; let sentAt: Date?; let receivedAt: Date; let sim: String?; let enc: String }
        let frags: [Frag] = try db.withStatement("""
        SELECT fingerprint, seq, text, pdu, sent_at, received_at, sim_number, encoding
        FROM parts WHERE sender = ? AND ref = ? AND total = ? ORDER BY seq ASC
        """) { s in
            try s.bind([.text(sender), .int(ref), .int(total)])
            var out: [Frag] = []
            while try s.step() {
                out.append(Frag(fp: s.text(0) ?? "", seq: s.int(1), text: s.text(2) ?? "", pdu: s.text(3) ?? "",
                                sentAt: s.date(4), receivedAt: s.date(5) ?? Date(), sim: s.text(6), enc: s.text(7) ?? "gsm7"))
            }
            return out
        }
        guard let first = frags.first else { return nil }

        let combinedFP = Self.fingerprint(frags.map(\.fp).joined(separator: "|"))
        let body = frags.map(\.text).joined()
        let inserted = try insertMessage(
            fingerprint: combinedFP, sender: sender, body: body,
            sentAt: frags.compactMap(\.sentAt).min(), receivedAt: frags.map(\.receivedAt).max() ?? first.receivedAt,
            simNumber: first.sim, encoding: first.enc, partCount: frags.count, partTotal: total,
            pdus: frags.map(\.pdu), status: status
        )
        try db.run("DELETE FROM parts WHERE sender = ? AND ref = ? AND total = ?", [.text(sender), .int(ref), .int(total)])
        return inserted
    }

    /// Flushes multipart groups that never completed so a partial message still gets forwarded.
    public func flushStaleParts(olderThan age: TimeInterval, forwardingEnabled: Bool) throws -> [StoredMessage] {
        let cutoff = Date().addingTimeInterval(-age)
        let groups: [(String, Int, Int)] = try db.withStatement("""
        SELECT sender, ref, total FROM parts GROUP BY sender, ref, total HAVING MAX(received_at) < ?
        """) { s in
            try s.bind([.date(cutoff)])
            var out: [(String, Int, Int)] = []
            while try s.step() { out.append((s.text(0) ?? "", s.int(1), s.int(2))) }
            return out
        }
        var flushed: [StoredMessage] = []
        for (sender, ref, total) in groups {
            if let m = try db.transaction({
                try assembleGroup(sender: sender, ref: ref, total: total, status: forwardingEnabled ? .pending : .disabled)
            }) {
                flushed.append(m)
            }
        }
        return flushed
    }

    private func insertMessage(fingerprint: String, sender: String, body: String, sentAt: Date?, receivedAt: Date,
                               simNumber: String?, encoding: String, partCount: Int, partTotal: Int,
                               pdus: [String], status: ForwardStatus) throws -> StoredMessage? {
        let pdusJSON = String(decoding: try JSONEncoder().encode(pdus), as: UTF8.self)
        try db.run("""
        INSERT OR IGNORE INTO messages
            (fingerprint, sender, body, sent_at, received_at, sim_number, encoding, part_count, part_total, pdus, forward_status)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """, [
            .text(fingerprint), .text(sender), .text(body), .date(sentAt), .date(receivedAt),
            .optionalText(simNumber), .text(encoding), .int(partCount), .int(partTotal), .text(pdusJSON), .text(status.rawValue),
        ])
        guard try db.scalarInt("SELECT changes()") > 0 else { return nil }
        return try message(id: db.lastInsertRowID())
    }

    // MARK: - Queries

    private static let columns = """
    id, sender, body, sent_at, received_at, sim_number, encoding, part_count,
    forward_status, forward_attempts, forwarded_at, forward_error, next_attempt_at, direction, tg_request_id
    """

    private func row(_ s: Statement) -> StoredMessage {
        StoredMessage(
            id: s.int64(0), direction: Direction(rawValue: s.text(13) ?? "in") ?? .incoming,
            sender: s.text(1) ?? "", body: s.text(2) ?? "",
            sentAt: s.date(3), receivedAt: s.date(4) ?? Date(), simNumber: s.text(5),
            encoding: s.text(6) ?? "", partCount: s.int(7),
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
        let clause = includeUntargeted ? "(sim_number = ? OR sim_number IS NULL OR sim_number = '')" : "sim_number = ?"
        return try db.withStatement("""
        SELECT \(Self.columns) FROM messages
        WHERE direction = 'out' AND forward_status IN ('pending','failed')
          AND \(clause)
          AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
        ORDER BY id ASC LIMIT ?
        """) { s in
            try s.bind([.text(routeKey), .date(now), .int(limit)])
            var out: [StoredMessage] = []
            while try s.step() { out.append(row(s)) }
            return out
        }
    }

    /// Records how many parts an outgoing SMS was split into once it has been sent.
    public func markOutgoingSent(id: Int64, parts: Int, at date: Date = Date()) throws {
        try db.run("""
        UPDATE messages SET forward_status = 'sent', forwarded_at = ?, sent_at = ?, part_count = ?, part_total = ?,
                            forward_error = NULL, next_attempt_at = NULL, forward_attempts = forward_attempts + 1
        WHERE id = ?
        """, [.date(date), .date(date), .int(parts), .int(parts), .int(id)])
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

    public func markFailed(id: Int64, error: String, nextAttempt: Date?, gaveUp: Bool) throws {
        try db.run("""
        UPDATE messages SET forward_status = ?, forward_error = ?, next_attempt_at = ?, forward_attempts = forward_attempts + 1
        WHERE id = ?
        """, [.text(gaveUp ? ForwardStatus.gaveUp.rawValue : ForwardStatus.failed.rawValue),
              .text(error), .date(nextAttempt), .int(id)])
    }

    /// Push a message's next attempt out without counting it as a failure (e.g. Telegram 429).
    public func defer_(id: Int64, until date: Date) throws {
        try db.run("UPDATE messages SET next_attempt_at = ? WHERE id = ? AND forward_status IN ('pending','failed')",
                   [.date(date), .int(id)])
    }

    /// Manual retry / "forward now" from the UI.
    public func requeue(id: Int64) throws {
        try db.run("""
        UPDATE messages SET forward_status = 'pending', forward_attempts = 0, next_attempt_at = NULL, forward_error = NULL
        WHERE id = ?
        """, [.int(id)])
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
