import Darwin
import Foundation

enum SerialError: Error, LocalizedError {
    case open(String, Int32)
    case configure(Int32)
    case write(Int32)
    case closed

    var errorDescription: String? {
        switch self {
        case .open(let path, let e): return "open(\(path)) failed: \(String(cString: strerror(e)))"
        case .configure(let e): return "termios failed: \(String(cString: strerror(e)))"
        case .write(let e): return "write failed: \(String(cString: strerror(e)))"
        case .closed: return "port closed"
        }
    }
}

/// POSIX serial port for a CDC-ACM device. Bytes arrive in order through `bytes`;
/// the stream finishes when the device goes away (unplug) or `close()` is called.
///
/// Reads and writes use `poll()` rather than `DispatchSource`. On macOS, USB CDC-ACM
/// devices often fail to deliver `DispatchSourceRead` events while `O_NONBLOCK` is set.
final class SerialPort: @unchecked Sendable {
    let path: String
    let bytes: AsyncStream<Data>

    private let fd: Int32
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var closed = false
    private var fdClosed = false
    private var streamFinished = false
    private var readerStarted = false

    init(path: String) throws {
        self.path = path
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError.open(path, errno) }
        self.fd = fd

        // Take exclusive ownership so a second copy of the app (or a stray `screen`) can't interleave commands.
        _ = ioctl(fd, TIOCEXCL)

        var tty = termios()
        guard tcgetattr(fd, &tty) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw SerialError.configure(e)
        }
        cfmakeraw(&tty)
        cfsetspeed(&tty, speed_t(B115200))  // ignored by CDC-ACM but keeps termios happy
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tty.c_cflag &= ~tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        guard tcsetattr(fd, TCSANOW, &tty) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw SerialError.configure(e)
        }
        var modemBits: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(fd, TIOCMBIS, &modemBits)
        tcflush(fd, TCIOFLUSH)

        var cont: AsyncStream<Data>.Continuation!
        bytes = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    /// Must run after the port is retained. Starting a `weak self` thread from `init`
    /// can drop the reader before the first AT command.
    func startReading() {
        lock.lock()
        if readerStarted || closed {
            lock.unlock()
            return
        }
        readerStarted = true
        lock.unlock()
        let thread = Thread { [unowned self] in self.readLoop() }
        thread.name = "smsrelay.serial.read"
        thread.start()
    }

    private func readLoop() {
        while true {
            lock.lock()
            let done = closed
            lock.unlock()
            if done { break }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pfd, 1, 200)
            if rc < 0 {
                if errno == EINTR { continue }
                if errno == EBADF { close(); break }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if rc == 0 { continue }
            if pfd.revents & Int16(POLLNVAL) != 0 {
                close()
                break
            }
            if pfd.revents & Int16(POLLIN) != 0 {
                readAvailable()
            }
        }
        finishStream()
    }

    private func readAvailable() {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            continuation.yield(Data(buf[0..<n]))
        } else if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
            close()
        }
        // n == 0 after POLLIN is treated as a no-op: CDC-ACM often reports readable
        // without delivering a byte. Hangup is handled via POLLHUP above.
    }

    func write(_ data: Data, timeout: TimeInterval = 2) throws {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { throw SerialError.closed }
        var offset = 0
        let deadline = Date().addingTimeInterval(timeout)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        try waitWritable(deadline: deadline)
                        continue
                    }
                    throw SerialError.write(errno)
                }
                offset += n
            }
        }
    }

    private func waitWritable(deadline: Date) throws {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { throw SerialError.write(ETIMEDOUT) }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = Int32(min(max(remaining * 1000, 1), 2_000))
        let rc = poll(&pfd, 1, ms)
        if rc == 0 { throw SerialError.write(ETIMEDOUT) }
        if rc < 0 && errno != EINTR { throw SerialError.write(errno) }
        if pfd.revents & Int16(POLLNVAL) != 0 {
            throw SerialError.write(EBADF)
        }
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let shouldCloseFD = !fdClosed
        fdClosed = true
        lock.unlock()
        if shouldCloseFD { Darwin.close(fd) }
        finishStream()
    }

    private func finishStream() {
        lock.lock()
        if streamFinished {
            lock.unlock()
            return
        }
        streamFinished = true
        lock.unlock()
        continuation.finish()
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    deinit { close() }

    /// All CDC-ACM "callout" devices currently present.
    static func candidatePaths() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev"))?
            .filter { $0.hasPrefix("cu.usbmodem") }
            .sorted()
            .map { "/dev/" + $0 } ?? []
    }
}
