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
final class SerialPort: @unchecked Sendable {
    let path: String
    let bytes: AsyncStream<Data>

    private var fd: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "smsrelay.serial.read")
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var closed = false

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
        tcflush(fd, TCIOFLUSH)

        // Blocking writes are fine for a few dozen bytes; reads are driven by the dispatch source.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

        var cont: AsyncStream<Data>.Continuation!
        bytes = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont

        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [continuation] in continuation.finish() }
        source.resume()
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            continuation.yield(Data(buf[0..<n]))
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            // EOF or hard error → the device is gone.
            close()
        }
    }

    func write(_ data: Data) throws {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { throw SerialError.closed }
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw SerialError.write(errno)
                }
                offset += n
            }
        }
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        source.cancel()  // cancel handler finishes the stream
        Darwin.close(fd)
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
