import AppKit
import SMSRelayCore
import SwiftUI

struct SettingsView: View {
    enum Page: Equatable {
        case app
        case modem(String)
    }

    @Environment(AppModel.self) private var model
    let page: Page

    var body: some View {
        Form {
            switch page {
            case .app:
                AppSettingsPane()
            case .modem(let imei):
                ModemSettingsPane(imei: imei)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            if !model.settings.portPath.isEmpty { model.settings.portPath = "" }
        }
    }
}

private struct AppSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Detected") {
            if model.modems.isEmpty {
                Text("Looking for ML307 and Air780…")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.modems, id: \.id) { m in
                    LabeledContent(m.settingsChipTitle) {
                        Text(m.isRegistered ? m.operatorName : "not registered")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        Section("App") {
            Toggle("Run at login & restart if it crashes", isOn: Binding(
                get: { model.keepAlive },
                set: { model.keepAlive = $0 }
            ))
            .disabled(!model.canManageKeepAlive)
            HStack {
                Text(model.keepAliveStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Login Items…") { KeepAlive.openLoginItemsSettings() }
                    .controlSize(.small)
            }
            .onAppear { model.refreshKeepAliveStatus() }
            Toggle("Prevent idle sleep while a modem is connected", isOn: $model.settings.preventSystemSleep)
            Stepper("Messages per page: \(model.settings.pageSize)", value: $model.settings.pageSize, in: 10...100, step: 10)
            LabeledContent("Log file") {
                Button("Reveal") {
                    if let url = model.fileLog?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .controlSize(.small)
                .disabled(model.fileLog == nil)
            }
            LabeledContent("Database") {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.databasePath)])
                }
                .controlSize(.small)
            }
        }
    }
}

private struct ModemSettingsPane: View {
    @Environment(AppModel.self) private var model
    let imei: String
    @State private var showToken = false

    var body: some View {
        let live = model.modem(id: imei)
        Section("This modem") {
            if let live {
                LabeledContent("Model", value: live.info.model?.replacingOccurrences(of: "\"", with: "") ?? "—")
                LabeledContent("IMEI", value: imei)
                if let iccid = live.sim.iccid { LabeledContent("ICCID", value: iccid) }
                LabeledContent("MSISDN") {
                    SIMNumberField(modem: live, monospaced: false)
                }
            } else {
                Text("Not plugged in")
                    .foregroundStyle(.secondary)
            }
        }
        Section("Telegram") {
            HStack {
                if showToken {
                    TextField("Bot token", text: tokenBinding, prompt: Text("123456:ABC-DEF…"))
                } else {
                    SecureField("Bot token", text: tokenBinding, prompt: Text("123456:ABC-DEF…"))
                }
                Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
            }
            HStack {
                TextField("Chat ID", text: chatBinding, prompt: Text("e.g. 123456789 or -100…"))
                Button("Find…") { Task { await model.detectChats(imei: imei) } }
                    .disabled(ms.telegramBotToken.isEmpty || model.telegramBusy)
            }
            if !model.chatCandidates.isEmpty {
                Picker("Detected chats", selection: chatBinding) {
                    Text("—").tag(ms.telegramChatID)
                    ForEach(model.chatCandidates) { c in
                        Text("\(c.title) · \(c.type) · \(c.chatID)").tag(String(c.chatID))
                    }
                }
            }
            Toggle("Forward new messages", isOn: boolBinding(\.forwardingEnabled))
            Toggle("Include SIM number in forwarded text", isOn: boolBinding(\.includeSIMNumber))
            Toggle("Alert me when this modem or network drops", isOn: boolBinding(\.healthAlerts))
            Toggle("Allow sending SMS from Telegram (reply or /sms)", isOn: boolBinding(\.telegramSendEnabled))
            if ms.telegramSendEnabled {
                TextField("Allowed Telegram user IDs (optional)", text: stringBinding(\.telegramAllowedUserIDs),
                          prompt: Text("empty = anyone in the chat"))
            }
            HStack {
                Button("Send test message") { Task { await model.testTelegram(imei: imei) } }
                    .disabled(!ms.telegramConfigured || model.telegramBusy)
                if model.telegramBusy { ProgressView().controlSize(.small) }
                Spacer()
                if let bot = model.telegramBot {
                    Text("@\(bot.username)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let status = model.telegramStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status.hasPrefix("Failed") || status.hasPrefix("Forwarding error") ? .red : .secondary)
                    .textSelection(.enabled)
            }
        }
        Section("Modem") {
            Toggle("Delete from SIM after saving", isOn: boolBinding(\.deleteFromSIM))
            Toggle("Network status LED", isOn: boolBinding(\.networkLED))
                .help("ML307: AT+MLED. Air780: AT+CNETLIGHT.")
            Stepper("Sweep SIM every \(ms.pollIntervalSeconds)s",
                    value: intBinding(\.pollIntervalSeconds), in: 5...300, step: 5)
        }
    }

    private var ms: ModemSettings { model.settings.modem(imei) }
    private var tokenBinding: Binding<String> { stringBinding(\.telegramBotToken) }
    private var chatBinding: Binding<String> { stringBinding(\.telegramChatID) }

    private func stringBinding(_ keyPath: WritableKeyPath<ModemSettings, String>) -> Binding<String> {
        Binding(
            get: { model.settings.modem(imei)[keyPath: keyPath] },
            set: { value in
                var s = model.settings
                s.updateModem(imei) { $0[keyPath: keyPath] = value }
                model.settings = s
            }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<ModemSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings.modem(imei)[keyPath: keyPath] },
            set: { value in
                var s = model.settings
                s.updateModem(imei) { $0[keyPath: keyPath] = value }
                model.settings = s
            }
        )
    }

    private func intBinding(_ keyPath: WritableKeyPath<ModemSettings, Int>) -> Binding<Int> {
        Binding(
            get: { model.settings.modem(imei)[keyPath: keyPath] },
            set: { value in
                var s = model.settings
                s.updateModem(imei) { $0[keyPath: keyPath] = value }
                model.settings = s
            }
        )
    }
}
