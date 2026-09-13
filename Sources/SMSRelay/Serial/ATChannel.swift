import Foundation
import SMSRelayCore

/// Serialised AT command channel over one serial port.
///
/// Exactly one command is in flight at a time. Lines that arrive while a command is
/// pending are attributed to it unless they look like an unsolicited result code
/// (+CMTI, +CREG, …) for a *different* prefix, in which case they go to `urcs`.
actor ATChannel {
    private static let urcPrefixes = [
        "+CMTI:", "+CMT:", "+CDS:", "+CDSI:", "+CBM:", "+CREG:", "+CEREG:", "+CGREG:",
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
    private var nextID: UInt64 = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var readerTask: Task<Void, Never>?
    private var lastTimeout: Date?
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
        guard isOpen else { throw ATError.portClosed }

        // After a timeout the modem may still emit the late reply; give it a moment so those
        // lines drain as noise instead of being attributed to this command.
        if let t = lastTimeout, Date().timeIntervalSince(t) < 2 {
            try? await Task.sleep(for: .milliseconds(400))
            lastTimeout = nil
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
                cont.resume(throwing: error)
                return
            }
            pending?.timeout = armTimeout(id: id, timeout)
        }
        return response
    }

    /// Two-phase command such as `AT+CMGS=<len>`: send the command, wait for the `>` prompt,
    /// then send `payload` terminated with Ctrl-Z and wait for the final result.
    func sendWithPrompt(_ command: String, payload: Data, promptTimeout: Duration = .seconds(10),
                        timeout: Duration = .seconds(60)) async throws -> ATResponse {
        await acquire()
        defer { release() }
        guard isOpen else { throw ATError.portClosed }
        if let t = lastTimeout, Date().timeIntervalSince(t) < 2 {
            try? await Task.sleep(for: .milliseconds(400))
            lastTimeout = nil
        }

        nextID += 1
        let id = nextID
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var p = Pending(id: id, command: command, prefix: Self.responsePrefix(for: command))
            p.prompt = cont
            pending = p
            do {
                try port.write(Data((command + "\r").utf8))
            } catch {
                pending = nil
                cont.resume(throwing: error)
                return
            }
            pending?.timeout = armTimeout(id: id, promptTimeout)
        }

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
                try port.write(payload + Data([0x1A]))
            } catch {
                pending = nil
                cont.resume(throwing: error)
                return
            }
            pending?.timeout = armTimeout(id: id, timeout)
        }
        return response
    }

    private func armTimeout(id: UInt64, _ duration: Duration) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }  // cancelled → command completed
            guard !Task.isCancelled else { return }
            await self?.timedOut(id: id)
        }
    }

    /// Abort a half-finished `AT+CMGS` (modem waiting at the `>` prompt) by sending ESC.
    /// Safe to send at any time: outside prompt mode the modem ignores it.
    func abortPrompt() {
        try? port.write(Data([0x1B]))
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
            lineBuffer.removeSubrange(lineBuffer.startIndex...gt)
            while lineBuffer.first == 0x20 { lineBuffer.removeFirst() }
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
        lastTimeout = Date()
        logger?("⏱ timeout: \(p.command)")
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
}
