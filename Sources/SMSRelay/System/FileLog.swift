import Foundation

/// Append-only log at ~/Library/Logs/SMSRelay/smsrelay.log with simple size-based rotation
/// (smsrelay.log → smsrelay.log.1). Enough for post-mortems on a headless box.
final class FileLog {
    let url: URL
    private let maxBytes: UInt64
    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "smsrelay.filelog", qos: .utility)
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init?(maxBytes: UInt64 = 2 * 1024 * 1024) {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let logs = library.appendingPathComponent("Logs/\(AppInfo.internalName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        url = logs.appendingPathComponent("smsrelay.log")
        self.maxBytes = maxBytes
        Self.migrateLegacy(from: library.appendingPathComponent("Logs/\(AppInfo.Legacy.logsFolder)"), to: url)
        open()
    }

    /// Carry the old "Remora" log over once so history isn't lost.
    private static func migrateLegacy(from oldDir: URL, to newURL: URL) {
        let fm = FileManager.default
        let old = oldDir.appendingPathComponent("remora.log")
        guard !fm.fileExists(atPath: newURL.path), fm.fileExists(atPath: old.path) else { return }
        try? fm.moveItem(at: old, to: newURL)
        try? fm.removeItem(at: oldDir)
    }

    /// O_APPEND so two copies writing during a launchd hand-over can't clobber each other's lines.
    private func open() {
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func write(_ line: String) {
        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        queue.async { [self] in
            guard let handle else { return }
            handle.write(Data(stamped.utf8))
            if let size = try? handle.offset(), size > maxBytes { rotate() }
        }
    }

    private func rotate() {
        try? handle?.close()
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        open()
    }
}
