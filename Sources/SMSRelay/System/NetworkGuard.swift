import Foundation

/// Keeps macOS from routing internet through the modem.
///
/// The ML307 exposes a CDC-ECM interface alongside its AT ports. macOS happily creates a
/// network service for it ("CDC", enX), puts it first in the service order, takes the
/// modem's DHCP gateway and sends all traffic over mobile data — which also breaks Telegram.
/// This finds the service that belongs to the modem's USB device and disables it.
enum NetworkGuard {
    struct Service: Equatable {
        let name: String
        let hardwarePort: String
        let device: String?
        let enabled: Bool
    }

    struct Outcome: Equatable {
        var interfaces: [String] = []
        var matched: [Service] = []
        var disabled: [String] = []
        var error: String?

        var summary: String {
            if let error { return "error: \(error)" }
            if interfaces.isEmpty { return "modem has no network interface" }
            if matched.isEmpty { return "no macOS service on \(interfaces.joined(separator: ","))" }
            let names = matched.map { "\($0.name) (\($0.device ?? "?"))" }.joined(separator: ", ")
            if !disabled.isEmpty { return "disabled \(disabled.joined(separator: ", "))" }
            return "\(names) already disabled"
        }
    }

    /// Disable every enabled macOS network service attached to the given USB vendor's device.
    static func enforce(vendorID: Int) -> Outcome {
        var out = Outcome()
        out.interfaces = ethernetInterfaces(vendorID: vendorID)
        guard !out.interfaces.isEmpty else { return out }

        let services: [Service]
        do { services = try listServices() } catch {
            out.error = error.localizedDescription
            return out
        }
        out.matched = services.filter { s in s.device.map(out.interfaces.contains) ?? false }
        for s in out.matched where s.enabled {
            do {
                try run("/usr/sbin/networksetup", ["-setnetworkserviceenabled", s.name, "off"])
                out.disabled.append(s.name)
            } catch {
                out.error = "could not disable \(s.name): \(error.localizedDescription)"
            }
        }
        return out
    }

    // MARK: - IOKit registry → BSD interface names

    /// BSD names (en7, …) of Ethernet interfaces whose USB parent has `idVendor == vendorID`.
    static func ethernetInterfaces(vendorID: Int) -> [String] {
        guard let data = try? runData("/usr/sbin/ioreg", ["-r", "-c", "IOUSBHostDevice", "-l", "-a", "-w0"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let devices = plist as? [[String: Any]] else { return [] }
        var names: [String] = []
        for dev in devices where (dev["idVendor"] as? Int) == vendorID {
            collectBSDNames(in: dev, into: &names)
        }
        return Array(Set(names)).sorted()
    }

    private static func collectBSDNames(in node: [String: Any], into names: inout [String]) {
        if let bsd = node["BSD Name"] as? String, bsd.hasPrefix("en") { names.append(bsd) }
        for child in node["IORegistryEntryChildren"] as? [[String: Any]] ?? [] {
            collectBSDNames(in: child, into: &names)
        }
    }

    // MARK: - networksetup

    /// Parses `networksetup -listnetworkserviceorder`:
    /// ```
    /// (1) Wi-Fi
    /// (Hardware Port: Wi-Fi, Device: en0)
    /// (*) CDC
    /// (Hardware Port: CDC, Device: en7)
    /// ```
    static func listServices() throws -> [Service] {
        let text = try runText("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
        return parseServiceOrder(text)
    }

    static func parseServiceOrder(_ text: String) -> [Service] {
        var out: [Service] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("("), let close = line.firstIndex(of: ")"),
               !line.hasPrefix("(Hardware Port") {
                let marker = String(line[line.index(after: line.startIndex)..<close])
                let name = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                var port = "", device: String? = nil
                if i + 1 < lines.count {
                    let detail = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if detail.hasPrefix("(Hardware Port:") {
                        let body = detail.dropFirst("(Hardware Port:".count).dropLast()
                        let parts = body.components(separatedBy: ", Device:")
                        port = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
                        let dev = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                        device = dev.isEmpty ? nil : dev
                        i += 1
                    }
                }
                if !name.isEmpty {
                    out.append(Service(name: name, hardwarePort: port, device: device, enabled: marker != "*"))
                }
            }
            i += 1
        }
        return out
    }

    // MARK: - process helpers

    @discardableResult
    private static func run(_ path: String, _ args: [String]) throws -> String {
        try runText(path, args)
    }

    private static func runText(_ path: String, _ args: [String]) throws -> String {
        String(decoding: try runData(path, args), as: UTF8.self)
    }

    private static func runData(_ path: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData.isEmpty ? data : errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "NetworkGuard", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "\(path) exited \(p.terminationStatus)" : msg])
        }
        return data
    }
}
