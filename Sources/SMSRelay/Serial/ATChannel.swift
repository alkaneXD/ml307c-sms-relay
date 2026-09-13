import Foundation
import SMSRelayCore

struct ATPromptResponse {
    let response: ATResponse
    let promptLatency: TimeInterval
    let finalLatency: TimeInterval
}

/// Serialised AT command channel over one serial port.
///
/// Exactly one command is in flight at a time. Lines that arrive while a command is
/// pending are attributed to it unless they look like an unsolicited result code
/// (+CMTI, +CREG, …) for a *different* prefix, in which case they go to `urcs`.
actor ATChannel {
    private static let urcPrefixes = [
        "+CMTI:", "+CMT:", "+CDS:", "+CDSI:", "+CBM:", "+CREG:", "+CEREG:", "+CIREG:", "+CIREGU:", "+CGREG:",
        "+CPIN:", "+CTZV:", "+CTZE:", "+CGEV:", "+CUSD:", "+CLIP:", "RING", "NO CARRIER", "RDY",
        "+MSIMSTATE", "*", "^",
    ]

    private struct Pending {
        let id: UInt64
        let command: String
        let prefix: String?
        var lines: [String] = []
        /// Set while waiting for the final result code.
        var result: CheckedContinuation<ATResponse, Error>?
        /// Set while waiting for the `>` prompt (AT+CMGS).
        var prompt: CheckedContinuation<Void, Error>?
        /// A final result that arrived between prompt and payload phases.
        var earlyFinal: String?
        var timeout: Task<Void, Never>?
    }

    let path: String
    let urcs: AsyncStream<String>

    private let port: SerialPort
    private let urcContinuation: AsyncStream<String>.Continuation
    private var lineBuffer: [UInt8] = []
    private var pending: Pending?
    /// +CMT/+CDS/+CBM headers are followed by a raw payload line which has no URC prefix.
    private var awaitingURCPayload = false
    private var nextID: UInt64 = 0
    private var busy = false
    private var swallowCommandResults = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var readerTask: Task<Void, Never>?
    private(set) var isOpen = true
    private var logger: (@Sendable (String) -> Void)?

    init(path: String) throws {
        self.path = path
        port = try SerialPort(path: path)
        var cont: AsyncStream<String>.Continuation!
        urcs = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        urcContinuation = cont
    }

    func setLogger(_ logger: (@Sendable (String) -> Void)?) {
        self.logger = logger
    }

    func start() {
        guard readerTask == nil else { return }
        port.startReading()
        readerTask = Task { [weak self, port] in
            for await chunk in port.bytes {
                await self?.ingest(chunk)
            }
            await self?.handleClosed()
        }
    }

    // MARK: - Public API

    /// Sends a command and returns whatever the modem answered, OK or not.
    func send(_ command: String, timeout: Duration = .seconds(5)) async throws -> ATResponse {
        await acquire()
        defer { release() }
        guard isOpen else {
            logger?("send \(command) aborted: already closed")
            throw ATError.portClosed
        }

        nextID += 1
        let id = nextID
        let response: ATResponse = try await withCheckedThrowingContinuation { cont in
            var p = Pending(id: id, command: command, prefix: Self.responsePrefix(for: command))
            p.result = cont
            pending = p
            do {
                try port.write(Data((command + "\r").utf8))
            } catch {
                pending = nil
                let mapped = Self.mapSerialError(error)
                close()
                cont.resume(throwing: mapped)
                return
            }
            pending?.timeout = armTimeout(id: id, timeout)
        }
        return response
    }

    /// Two-phase command such as `AT+CMGS=<len>`: send the command, wait for the `>` prompt,
    /// then send `payload` terminated with Ctrl-Z and wait for the final result.
    func sendWithPrompt(_ command: String, payload: Data,
                        beforePayload: (@Sendable () throws -> Void)? = nil,
                        promptTimeout: Duration = .seconds(10),
                        timeout: Duration = .seconds(60)) async throws -> ATPromptResponse {
        await acquire()
        defer { release() }
        guard isOpen else { throw ATError.portClosed }

        nextID += 1
        let id = nextID
        let commandStarted = Date()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var p = Pending(id: id, command: command, prefix: Self.responsePrefix(for: command))
            p.prompt = cont
            pending = p
            do {
                try port.write(Data((command + "\r").utf8))
            } catch {
                pending = nil
                let mapped = Self.mapSerialError(error)
                close()
                cont.resume(throwing: mapped)
                return
            }
            pending?.timeout = armTimeout(id: id, promptTimeout)
        }
        let promptLatency = Date().timeIntervalSince(commandStarted)

        let payloadStarted = Date()
        let response: ATResponse = try await withCheckedThrowingContinuation { cont in
            guard var p = pending, p.id == id else {
                abortPrompt()
                cont.resume(throwing: ATError.unexpected("command state lost after prompt"))
                return
            }
            if let final = p.earlyFinal {
                pending = nil
                cont.resume(returning: ATResponse(command: command, lines: p.lines, final: final))
                return
            }
            p.result = cont
            pending = p
            do {
                try beforePayload?()
            } catch {
                pending = nil
                close()
                cont.resume(throwing: error)
                return
            }
            do {
                try port.write(payload + Data([0x1A]))
            } catch {
                pending = nil
                let mapped = Self.mapSerialError(error)
                close()
                cont.resume(throwing: mapped)
                return
            }
            pending?.timeout = armTimeout(id: id, timeout)
        }
        return ATPromptResponse(
            response: response,
            promptLatency: promptLatency,
            finalLatency: Date().timeIntervalSince(payloadStarted)
        )
    }

    private func armTimeout(id: UInt64, _ duration: Duration) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }  // cancelled → command completed
            guard !Task.isCancelled else { return }
            await self?.timedOut(id: id)
        }
    }

    /// Abort a half-finished `AT+CMGS` (modem waiting at the `>` prompt) by sending ESC.
    /// Follow with CR: a bare ESC is consumed as a prefix and the next `AT` is lost.
    func abortPrompt() {
        try? port.write(Data([0x1B, 0x0D]), timeout: 0.3)
    }

    /// Ack a `+CDS`/`+CMT`. If a command (usually `AT+CMGS`) is in flight, write the ack
    /// without taking the lock so the modem can finish that command. Otherwise use the
    /// normal queue so we do not interleave with the next heartbeat.
    func acknowledgeNewMessage() async {
        if pending != nil {
            try? port.write(Data("AT+CNMA=1\r".utf8), timeout: 0.4)
            swallowCommandResults += 1
            return
        }
        _ = try? await send("AT+CNMA=1", timeout: .seconds(3))
    }

    /// Sends a command and throws unless the final result is OK.
    @discardableResult
    func sendOK(_ command: String, timeout: Duration = .seconds(5)) async throws -> ATResponse {
        let r = try await send(command, timeout: timeout)
        guard r.isOK else { throw ATError.failure(command: command, result: r.final) }
        return r
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        port.close()
        failPending(ATError.portClosed)
        urcContinuation.finish()
        for w in waiters { w.resume() }
        waiters.removeAll()
    }

    // MARK: - Internals

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()  // hands the lock straight to the next waiter
        } else {
            busy = false
        }
    }

    /// Splits on raw 0x0A bytes. (Splitting a `String` on "\n" fails here because
    /// Swift treats "\r\n" as a single Character.)
    private func ingest(_ chunk: Data) {
        lineBuffer.append(contentsOf: chunk)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            var lineBytes = lineBuffer[lineBuffer.startIndex..<nl]
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            while lineBytes.last == 0x0D { lineBytes.removeLast() }
            while lineBytes.first == 0x0D { lineBytes.removeFirst() }
            if !lineBytes.isEmpty {
                handleLine(String(decoding: lineBytes, as: UTF8.self))
            }
        }
        // The "> " prompt (AT+CMGS) never ends in \n: detect it in the partial line.
        if var p = pending, p.prompt != nil, let gt = lineBuffer.firstIndex(of: 0x3E) {
            let space = lineBuffer.index(after: gt)
            guard space < lineBuffer.endIndex, lineBuffer[space] == 0x20 else { return }
            lineBuffer.removeSubrange(lineBuffer.startIndex...space)
            p.timeout?.cancel()
            let cont = p.prompt
            p.prompt = nil
            p.timeout = nil
            pending = p
            logger?("← >")
            cont?.resume()
        }
        if lineBuffer.count > 65536 { lineBuffer.removeAll() }
    }

    private func handleLine(_ line: String) {
        logger?("← \(line)")
        if swallowCommandResults > 0, ATResponse.isFinalLine(line) {
            swallowCommandResults -= 1
            return
        }
        if awaitingURCPayload {
            awaitingURCPayload = false
            urcContinuation.yield(line)
            return
        }
        if Self.startsMultilineURC(line) {
            awaitingURCPayload = true
        }
        guard var p = pending else {
            urcContinuation.yield(line)
            return
        }
        if ATResponse.isFinalLine(line) {
            p.timeout?.cancel()
            if let prompt = p.prompt {
                // e.g. "+CMS ERROR" instead of the prompt.
                pending = nil
                prompt.resume(throwing: ATError.failure(command: p.command, result: line))
            } else if let result = p.result {
                pending = nil
                result.resume(returning: ATResponse(command: p.command, lines: p.lines, final: line))
            } else {
                // Between prompt and payload: keep it for the payload phase.
                p.earlyFinal = line
                pending = p
            }
        } else if Self.looksLikeURC(line, pendingPrefix: p.prefix) {
            urcContinuation.yield(line)
        } else {
            p.lines.append(line)
            pending = p
        }
    }

    private func timedOut(id: UInt64) {
        guard let p = pending, p.id == id else { return }
        pending = nil
        logger?("⏱ timeout: \(p.command)")
        // A late result could be mistaken for the next command. Closing here, before the
        // command releases its lock, wakes every queued caller into portClosed.
        close()
        p.prompt?.resume(throwing: ATError.timeout(p.command))
        p.result?.resume(throwing: ATError.timeout(p.command))
    }

    private func failPending(_ error: Error) {
        guard let p = pending else { return }
        p.timeout?.cancel()
        pending = nil
        p.prompt?.resume(throwing: error)
        p.result?.resume(throwing: error)
    }

    private func handleClosed() {
        guard isOpen else { return }
        isOpen = false
        failPending(ATError.portClosed)
        urcContinuation.finish()
        for w in waiters { w.resume() }
        waiters.removeAll()
    }

    /// "AT+CREG?" → "+CREG:" so its own response is never mistaken for a URC.
    static func responsePrefix(for command: String) -> String? {
        let upper = command.uppercased()
        guard upper.hasPrefix("AT+") else { return nil }
        let body = upper.dropFirst(2)
        let name = body.prefix { $0 == "+" || $0.isLetter || $0.isNumber }
        return name.count > 1 ? String(name) + ":" : nil
    }

    static func looksLikeURC(_ line: String, pendingPrefix: String?) -> Bool {
        if let p = pendingPrefix, line.hasPrefix(p) { return false }
        return urcPrefixes.contains { line.hasPrefix($0) }
    }

    private static func startsMultilineURC(_ line: String) -> Bool {
        line.hasPrefix("+CMT:") || line.hasPrefix("+CDS:") || line.hasPrefix("+CBM:")
    }

    private static func mapSerialError(_ error: Error) -> Error {
        switch error {
        case SerialError.write(let errno_): return ATError.writeFailed(errno_)
        case SerialError.closed: return ATError.portClosed
        default: return error
        }
    }
}
