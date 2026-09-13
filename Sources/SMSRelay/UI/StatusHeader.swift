import SMSRelayCore
import SwiftUI

/// Header showing every attached modem. One compact card per modem; a placeholder when none.
struct StatusHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.modems.isEmpty {
                emptyRow
            } else {
                ForEach(model.modems) { modem in
                    ModemCard(modem: modem)
                }
            }
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Looking for a modem…").font(.headline)
                Text(model.settings.portPath.isEmpty ? "Scanning /dev/cu.usbmodem*" : model.settings.portPath)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct ModemCard: View {
    @Environment(AppModel.self) private var model
    let modem: Modem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                        .shadow(color: statusColor.opacity(0.6), radius: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                signalBlock
            }
            simRow
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch modem.connection {
        case .connected:
            if modem.consecutiveHeartbeatMisses > 0 { return .orange }
            return modem.isStable ? .green : .mint
        case .connecting, .searching: return .orange
        case .disconnected: return .red
        }
    }

    private var title: String {
        switch modem.connection {
        case .connected:
            if modem.consecutiveHeartbeatMisses > 0 { return "\(modem.label) · Unresponsive" }
            return modem.isStable ? "\(modem.label) · Stable" : modem.label
        case .connecting: return "\(modem.label) · Connecting…"
        case .searching: return "\(modem.label) · Searching…"
        case .disconnected: return "\(modem.label) · Disconnected"
        }
    }

    private var subtitle: String {
        switch modem.connection {
        case .connected(_, let since):
            let name = modem.info.model ?? "modem"
            return "\(name) · up \(uptimeText(since: since)) · \(modem.portShortName)"
        case .connecting(let port): return port.replacingOccurrences(of: "/dev/cu.", with: "")
        case .searching: return modem.portShortName
        case .disconnected(let reason): return reason
        }
    }

    private func uptimeText(since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    private var signalBlock: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Text(modem.connection.isConnected ? modem.signal.level.label : "—")
                    .font(.subheadline.weight(.medium))
                Image(systemName: "cellularbars", variableValue: modem.connection.isConnected ? modem.signal.fraction : 0)
                    .font(.title3)
                    .foregroundStyle(modem.connection.isConnected ? .primary : .secondary)
            }
            Text(networkLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var networkLine: String {
        guard modem.connection.isConnected else { return "No signal" }
        guard let reg = modem.registration else { return "Registering…" }
        guard reg.isRegistered else { return reg.statusText }
        var parts = [modem.operatorName, modem.accessTechnologyName, modem.signal.primaryDBmText]
        if reg.isRoaming { parts.append("roaming") }
        return parts.joined(separator: " · ")
    }

    private var simRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "simcard").foregroundStyle(.secondary)
            if let number = modem.sim.number {
                Text(number).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Button { model.copyToClipboard(number) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).controlSize(.small).help("Copy number")
            } else if modem.connection.isConnected {
                Text(modem.sim.isReady ? "Number not on SIM" : "SIM: \(modem.sim.status)").foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
            Spacer()
            if let used = modem.storageUsed, let total = modem.storageTotal {
                Text("SIM \(used)/\(total)")
                    .font(.caption)
                    .foregroundStyle(used >= total ? .red : .secondary)
                    .help("Messages held in SIM storage")
            }
        }
    }
}
