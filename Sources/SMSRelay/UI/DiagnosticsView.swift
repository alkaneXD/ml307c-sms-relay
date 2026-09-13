import SMSRelayCore
import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if model.modems.isEmpty {
                    Section("Modems") {
                        Text("No modem detected. Plug in an ML307C via USB.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.modems) { modem in
                    modemSection(modem)
                }
                Section("Safeguards") {
                    row("macOS network service", model.networkGuardStatus)
                    row("Supervision", KeepAlive.isLaunchdManaged ? "launchd (auto-restart)" : "manual launch")
                    row("Idle sleep", model.isPreventingSleep ? "prevented" : "allowed")
                    row("Last error", model.lastError)
                    HStack {
                        Button("Re-check network guard") { Task { await model.recheckNetworkGuard() } }
                            .disabled(!model.anyConnected)
                        Spacer()
                    }
                    .help("The modem's USB Ethernet interface must never become the default route.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            logView
                .frame(height: 150)
        }
    }

    @ViewBuilder
    private func modemSection(_ modem: Modem) -> some View {
        Section(modem.label) {
            row("Model", modem.info.model)
            row("Firmware", modem.info.firmware)
            row("IMEI", modem.id)
            row("Port", modem.port)
            row("SIM status", modem.sim.status)
            row("Number", modem.sim.number)
            row("ICCID", modem.sim.iccid)
            row("IMSI", modem.sim.imsi)
            row("Operator", modem.operatorCode.map { "\(modem.operatorName) (\($0))" })
            row("Technology", modem.connection.isConnected ? modem.accessTechnologyName : nil)
            row("EPS registration", modem.epsRegistration?.statusText)
            row("CS registration", modem.csRegistration?.statusText)
            row("IMS registration", modem.imsRegistered.map { $0 ? "Registered" : "Not registered" })
            row("IMS SMS capability", modem.imsSMSAvailable.map { $0 ? "Available" : "Unavailable" })
            row("UE IMS SMS setting", modem.imsSMSConfigured.map { $0 ? "Enabled" : "Disabled" })
            row("SMS transport", modem.smsTransportText)
            row("Signal", modem.connection.isConnected
                ? "\(modem.signal.level.label) · \(modem.signal.primaryDBmText)" : nil)
            row("SIM storage", modem.storageUsed.map { "\($0) / \(modem.storageTotal ?? 0)" })
            row("Heartbeat RTT", modem.heartbeatRTT.map { String(format: "%.0f ms", $0 * 1000) })
            row("Reconnects / USB resets", "\(modem.reconnects) / \(modem.usbResets)")
            row("Auto-dialup", modem.modemAutoDial.map { $0 ? "ON — will be disabled" : "off" })
            HStack {
                Button("Reset this USB device") { Task { await model.resetUSB(modem) } }
                    .disabled(model.usbResetBusy)
                if model.usbResetBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .help("Software unplug/replug of just this modem — use if it stops answering but its port is still listed.")
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        LabeledContent(label) {
            Text(value?.isEmpty == false ? value! : "—")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.logEntries) { entry in
                        Text("\(entry.date, format: .dateTime.hour().minute().second()) \(entry.text)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .id(entry.id)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .onChange(of: model.logEntries.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear {
                if let id = model.logEntries.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}
