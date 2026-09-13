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
    public let simNumber: String?
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
    public let simNumber: String?
    public let receivedAt: Date

    public init(pdu: String, decoded: SMSDeliver, simNumber: String?, receivedAt: Date = Date()) {
        self.pdu = pdu
        self.decoded = decoded
        self.simNumber = simNumber
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
