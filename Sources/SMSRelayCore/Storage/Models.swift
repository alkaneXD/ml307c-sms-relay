import Foundation

public enum ForwardStatus: String, Sendable, CaseIterable {
    case pending, sent, failed, disabled, gaveUp = "gave_up"

    public var label: String {
        switch self {
        case .pending: return "Pending"
        case .sent: return "Forwarded"
        case .failed: return "Retrying"
        case .disabled: return "Not forwarded"
        case .gaveUp: return "Failed"
        }
    }
}

public enum Direction: String, Sendable {
    case incoming = "in"
    case outgoing = "out"
}

public enum OutgoingPartState: String, Sendable {
    case pending
    /// The prompt was received and the durable pre-payload hook ran. A crash from here is
    /// ambiguous because payload transmission may have started.
    case transmitting
    /// The modem timed out after accepting the TPDU; the SMSC may or may not have received it.
    case ambiguous
    /// The SMSC accepted the part (or rejected a standards-compliant retry as a duplicate).
    case submitted
    /// A status report for the submitted part has arrived.
    case reported
}

/// Durable state for one SMS-SUBMIT TPDU. The TE-side PDU and requested TP-MR are reused.
/// Many AT modems replace TP-MR on air, so TP-RD is best-effort rather than an exactly-once
/// guarantee; the modem-returned reference is stored separately for status reports.
public struct OutgoingPart: Equatable, Sendable {
    public let messageID: Int64
    public let sequence: Int
    public let total: Int
    public let pdu: String
    public let tpduLength: Int
    public let messageReference: UInt8
    public let attempts: Int
    public let state: OutgoingPartState
    public let modemReference: Int?
    public let deliveryStatus: Int?
    public let lastError: String?

    public var needsSubmission: Bool {
        state == .pending || state == .transmitting || state == .ambiguous
    }
}

public struct OutgoingStatusReportMatch: Equatable, Sendable {
    public let messageID: Int64
    public let sequence: Int
    public let allPartsSubmitted: Bool
}

/// A fully assembled SMS persisted in SQLite. For outgoing messages `sender` holds the
/// destination number and the `forward*` columns track the SIM send instead of Telegram.
public struct StoredMessage: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let direction: Direction
    public let sender: String
    public let body: String
    /// Network timestamp (SCTS). Falls back to receivedAt when absent.
    public let sentAt: Date?
    /// When the app pulled it off the modem.
    public let receivedAt: Date
    /// Stable routing identity for the SIM (stored in the legacy `sim_number` column).
    public let simNumber: String?
    /// Human-readable phone number/label captured when the incoming SMS was received.
    public let simDisplay: String?
    public let encoding: String
    public let partCount: Int
    public let forwardStatus: ForwardStatus
    public let forwardAttempts: Int
    public let forwardedAt: Date?
    public let forwardError: String?
    public let nextAttemptAt: Date?
    /// Telegram message that requested this outgoing SMS (to reply with the result).
    public let telegramRequestID: Int64?

    public var displayDate: Date { sentAt ?? receivedAt }
    public var isOutgoing: Bool { direction == .outgoing }
}

/// Everything the modem loop knows about a decoded PDU before it hits the DB.
public struct IncomingSMS: Sendable {
    public let pdu: String
    public let decoded: SMSDeliver
    /// Stable routing identity for the SIM.
    public let simNumber: String?
    public let simDisplay: String?
    public let receivedAt: Date

    public init(pdu: String, decoded: SMSDeliver, simNumber: String?, simDisplay: String? = nil,
                receivedAt: Date = Date()) {
        self.pdu = pdu
        self.decoded = decoded
        self.simNumber = simNumber
        self.simDisplay = simDisplay
        self.receivedAt = receivedAt
    }
}

public struct MessagePage: Sendable, Equatable {
    public let items: [StoredMessage]
    public let pageIndex: Int  // 0-based
    public let pageSize: Int
    public let totalCount: Int

    public var pageCount: Int { max(1, (totalCount + pageSize - 1) / pageSize) }
    public var hasPrevious: Bool { pageIndex > 0 }
    public var hasNext: Bool { pageIndex + 1 < pageCount }

    public static let empty = MessagePage(items: [], pageIndex: 0, pageSize: 20, totalCount: 0)
}
