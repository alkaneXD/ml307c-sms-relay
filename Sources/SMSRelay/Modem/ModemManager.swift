import Foundation
import SMSRelayCore

/// Discovers ML307 / Air780 USB modems and runs one `ModemService` per physical unit.
///
/// A single ML307C exposes several serial ports; two identical modems expose several each and
/// may even share the same fake USB serial. To attach reliably we probe each unclaimed port,
/// read its IMEI, and key everything on that — so the two AT ports of one modem collapse to one
/// logical modem, and a genuinely different unit becomes a second one. Hot-plug and unplug are
/// handled by rescanning every few seconds.
@MainActor
final class ModemManager {
    /// China Mobile IoT ("CORIG") — the ML307 family's USB vendor ID.
    nonisolated static let usbVendorID = 0x2C91

    private enum Probe { case modem(imei: String); case notModem }

    private unowned let app: AppModel
    private var services: [String: ModemService] = [:]   // IMEI → service
    private var probeCache: [String: Probe] = [:]        // port → last probe result
    private var scanTask: Task<Void, Never>?
    private var guardTask: Task<Void, Never>?
    private let scanInterval: Duration = .seconds(3)

    init(app: AppModel) {
        self.app = app
    }

    func start() {
        guard scanTask == nil else { return }
        scanTask = Task { await scanLoop() }
        guardTask = Task { await networkGuardLoop() }
    }

    /// Settings changed (e.g. port override) — forget everything and rediscover.
    func rescan() {
        for svc in services.values { svc.stop() }
        for id in Array(services.keys) { app.removeModem(id: id) }
        services.removeAll()
        probeCache.removeAll()
    }

    func kickOutgoing() { for svc in services.values { svc.kickOutgoing() } }
    func applyNetworkLED() { for svc in services.values { svc.applyNetworkLED() } }
    func applyNetworkLED(id: String) { services[id]?.applyNetworkLED() }

    // MARK: - Scan loop

    private func scanLoop() async {
        while !Task.isCancelled {
            await scanOnce()
            try? await Task.sleep(for: scanInterval)
        }
    }

    private func scanOnce() async {
        let ports = SerialPort.candidatePaths()
        let present = Set(ports)

        // Forget cache for ports that are gone.
        probeCache = probeCache.filter { present.contains($0.key) }

        // Reap services whose control port disappeared or that ended on their own.
        for (imei, svc) in services where svc.hasEnded || !present.contains(svc.port) {
            svc.stop()
            services[imei] = nil
            app.removeModem(id: imei)
            probeCache = probeCache.filter { if case .modem(imei) = $0.value { return false }; return true }
            app.log("modem …\(imei.suffix(6)) removed (unplugged)")
        }

        // Probe unclaimed, not-yet-cached ports in parallel (one dongle = 3 ports).
        let claimed = Set(services.values.map(\.port))
        let toProbe = ports.filter { !claimed.contains($0) && probeCache[$0] == nil }
        if !toProbe.isEmpty {
            await withTaskGroup(of: (String, Probe?).self) { group in
                for port in toProbe {
                    group.addTask { await (port, self.probe(port)) }
                }
                for await (port, result) in group {
                    if let result { probeCache[port] = result }
                }
            }
        }

        // Group discovered modem ports by IMEI; start a service for any new modem.
        var portsByIMEI: [String: [String]] = [:]
        for (port, result) in probeCache {
            if case .modem(let imei) = result, present.contains(port) {
                portsByIMEI[imei, default: []].append(port)
            }
        }
        for (imei, imeiPorts) in portsByIMEI where services[imei] == nil {
            guard let control = imeiPorts.sorted().first else { continue }
            let modem = Modem(id: imei, port: control)
            app.addModem(modem)
            let svc = ModemService(app: app, modem: modem)
            services[imei] = svc
            svc.start()
            app.log("modem …\(imei.suffix(6)) attached on \(modem.portShortName)")
        }
    }

    /// Opens a port briefly to learn whether it's an ML307/Air780 and, if so, its IMEI.
    private func probe(_ port: String) async -> Probe? {
        let overridden = !app.settings.portPath.trimmingCharacters(in: .whitespaces).isEmpty
        let name = URL(fileURLWithPath: port).lastPathComponent
        let result = await Task.detached { () -> Probe? in
            guard let ch = try? ATChannel(path: port) else {
                Self.probeLog(name, "open failed")
                return nil
            }
            await ch.start()
            try? await Task.sleep(for: .milliseconds(50))
            await ch.setLogger { line in
                Self.probeLog(name, line)
            }
            do {
                let ok = try await ch.send("AT", timeout: .seconds(2))
                guard ok.isOK else {
                    await ch.close()
                    Self.probeLog(name, ok.final)
                    return .notModem
                }
                _ = try? await ch.send("ATE0", timeout: .seconds(1))
                let info = try? await ch.send("ATI", timeout: .seconds(2))
                let cgmm = try? await ch.send("AT+CGMM", timeout: .seconds(2))
                let blob = ((info?.informationText ?? "") + " " + (cgmm?.informationText ?? "")).uppercased()
                let isSupported = blob.contains("ML307") || blob.contains("AIR780")
                guard isSupported || overridden else {
                    await ch.close()
                    Self.probeLog(name, "not an ML307/Air780")
                    return .notModem
                }
                let imei = (try? await ch.send("AT+CGSN", timeout: .seconds(2)))?.informationText
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await ch.close()
                guard !imei.isEmpty else {
                    Self.probeLog(name, "empty IMEI")
                    return nil
                }
                Self.probeLog(name, "modem …\(imei.suffix(6))")
                return .modem(imei: imei)
            } catch {
                await ch.close()
                Self.probeLog(name, error.localizedDescription)
                // Diagnostic/NMEA ports stay silent. Cache them so they do not block
                // the scan loop for 2s every few seconds.
                if let atError = error as? ATError, atError.isTimeout {
                    return .notModem
                }
                return nil
            }
        }.value
        return result
    }

    private nonisolated static func probeLog(_ port: String, _ detail: String) {
        FileHandle.standardError.write(Data("    [probe \(port)] \(detail)\n".utf8))
    }

    // MARK: - USB reset

    func resetUSB(_ modem: Modem?, reason: String) async {
        if let modem, let svc = services[modem.id] {
            await svc.resetUSBDevice(reason: reason)
        } else {
            // No specific modem — re-enumerate every ML307 on the bus.
            let n = await Task.detached {
                let a = (try? USBReset.reenumerate(vendorID: Self.usbVendorID)) ?? 0
                let b = (try? USBReset.reenumerate(vendorID: 0x19D1)) ?? 0
                return a + b
            }.value
            app.log("USB re-enumerated \(n) device(s) — \(reason)")
        }
    }

    // MARK: - macOS network guard (global)

    private func networkGuardLoop() async {
        var delays: [Duration] = [.seconds(4), .seconds(20), .seconds(60)]
        while !Task.isCancelled {
            await enforceNetworkGuard()
            let delay = delays.isEmpty ? Duration.seconds(3600) : delays.removeFirst()
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }

    func enforceNetworkGuard() async {
        let outcome = await Task.detached { NetworkGuard.enforce(vendorID: Self.usbVendorID) }.value
        if !outcome.disabled.isEmpty {
            app.log("network guard: disabled macOS service(s) \(outcome.disabled.joined(separator: ", ")) so the modem is never used for internet")
        } else if let err = outcome.error {
            app.log("network guard: \(err)")
        }
        app.networkGuardStatus = outcome.summary
    }
}
