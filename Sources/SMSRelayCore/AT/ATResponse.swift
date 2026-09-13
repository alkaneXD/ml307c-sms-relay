import Foundation

/// Result of one AT command exchange: intermediate lines + the final result code.
public struct ATResponse: Sendable, Equatable {
    public let command: String
    public let lines: [String]
    public let final: String

    public init(command: String, lines: [String], final: String) {
        self.command = command
        self.lines = lines
        self.final = final
    }

    public var isOK: Bool { final == "OK" }

    /// Lines beginning with the given prefix (e.g. "+CSQ:"), with the prefix stripped and trimmed.
    public func values(for prefix: String) -> [String] {
        lines.compactMap { line in
            guard line.hasPrefix(prefix) else { return nil }
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
    }

    public func value(for prefix: String) -> String? { values(for: prefix).first }

    /// Concatenated information text for commands like ATI / AT+CGMM whose payload has no prefix.
    public var informationText: String {
        lines.filter { !$0.hasPrefix("+") }.joined(separator: "\n")
    }

    public static func isFinalLine(_ line: String) -> Bool {
        line == "OK" || line == "ERROR" || line.hasPrefix("+CME ERROR") || line.hasPrefix("+CMS ERROR")
            || line == "NO CARRIER" || line == "BUSY" || line == "NO ANSWER" || line == "NO DIALTONE"
    }
}

public enum ATError: Error, LocalizedError, Sendable, Equatable {
    case timeout(String)
    case failure(command: String, result: String)
    case portClosed
    case writeFailed(Int32)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let cmd): return "Timeout waiting for \(cmd)"
        case .failure(let cmd, let result): return "\(cmd) → \(result)"
        case .portClosed: return "Serial port closed"
        case .writeFailed(let errno_): return "Write failed (errno \(errno_))"
        case .unexpected(let msg): return msg
        }
    }
}
