import SMSRelayCore
import SwiftUI

/// Signal for the selected stick, a centered SIM dropdown, then that stick's status.
struct StatusHeader: View {
    @Environment(AppModel.self) private var model

    private var selected: Modem? {
        model.modems.first { $0.id == model.settingsModemID } ?? model.modems.first
    }

    var body: some View {
        VStack(spacing: 10) {
            if let modem = selected {
                signalRow(modem)
                simPicker
                statusRow(modem)
            } else {
                emptyRow
                simPicker
            }
        }
    }

    private var simPicker: some View {
        Menu {
            ForEach(model.modems) { m in
                Button(m.settingsChipTitle) { model.settingsModemID = m.id }
            }
            Button("App settings") { model.settingsModemID = "app" }
        } label: {
            HStack {
                Text(pickerLabel)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary))
        }
        .menuStyle(.borderlessButton)
        .disabled(model.modems.isEmpty)
        .onChange(of: model.modems.map(\.id)) { _, ids in
            if model.settingsModemID != "app", !ids.contains(model.settingsModemID) {
                model.settingsModemID = ids.first ?? "app"
            }
        }
    }

    private var pickerLabel: String {
        if model.settingsModemID == "app" { return "App settings" }
        if let m = model.modems.first(where: { $0.id == model.settingsModemID }) {
            return m.settingsChipTitle
        }
        if let m = model.modems.first { return m.settingsChipTitle }
        return "Choose SIM"
    }

    private func signalRow(_ modem: Modem) -> some View {
        HStack {
            Circle()
                .fill(statusColor(modem))
                .frame(width: 9, height: 9)
                .shadow(color: statusColor(modem).opacity(0.6), radius: 3)
            Text(title(modem)).font(.headline)
            Spacer()
            Text(modem.connection.isConnected ? modem.signal.level.label : "—")
                .font(.subheadline.weight(.medium))
            Image(systemName: "cellularbars", variableValue: modem.connection.isConnected ? modem.signal.fraction : 0)
                .font(.title3)
                .foregroundStyle(modem.connection.isConnected ? .primary : .secondary)
        }
    }

    private func statusRow(_ modem: Modem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(networkLine(modem))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "simcard").foregroundStyle(.secondary)
                SIMNumberField(modem: modem)
                Spacer()
                if let used = modem.storageUsed, let total = modem.storageTotal {
                    Text("SIM \(used)/\(total)")
                        .font(.caption)
                        .foregroundStyle(used >= total ? .red : .secondary)
                }
            }
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(.secondary)
            Text("Looking for a modem…").font(.headline)
            Spacer()
        }
    }

    private func statusColor(_ modem: Modem) -> Color {
        switch modem.connection {
        case .connected:
            if modem.consecutiveHeartbeatMisses > 0 { return .orange }
            return modem.isStable ? .green : .mint
        case .connecting, .searching: return .orange
        case .disconnected: return .red
        }
    }

    private func title(_ modem: Modem) -> String {
        switch modem.connection {
        case .connected:
            if modem.consecutiveHeartbeatMisses > 0 { return "Unresponsive" }
            return modem.isStable ? "Stable" : "Connected"
        case .connecting: return "Connecting…"
        case .searching: return "Searching…"
        case .disconnected: return "Disconnected"
        }
    }

    private func networkLine(_ modem: Modem) -> String {
        guard modem.connection.isConnected else { return "No signal" }
        guard let reg = modem.registration else { return "Registering…" }
        guard reg.isRegistered else { return reg.statusText }
        var parts = [modem.operatorName, modem.accessTechnologyName, modem.signal.primaryDBmText]
        if reg.isRoaming { parts.append("roaming") }
        return parts.joined(separator: " · ")
    }
}
