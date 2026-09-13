import AppKit
import SMSRelayCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showToken = false
    @State private var ports: [String] = SerialPort.candidatePaths()

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Telegram") {
                HStack {
                    if showToken {
                        TextField("Bot token", text: $model.settings.telegramBotToken, prompt: Text("123456:ABC-DEF…"))
                    } else {
                        SecureField("Bot token", text: $model.settings.telegramBotToken, prompt: Text("123456:ABC-DEF…"))
                    }
                    Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                }
                HStack {
                    TextField("Chat ID", text: $model.settings.telegramChatID, prompt: Text("e.g. 123456789 or -100…"))
                    Button("Find…") { Task { await model.detectChats() } }
                        .disabled(model.settings.telegramBotToken.isEmpty || model.telegramBusy)
                        .help("Lists chats that recently messaged the bot. Send it any message first.")
                }
                if !model.chatCandidates.isEmpty {
                    Picker("Detected chats", selection: $model.settings.telegramChatID) {
                        Text("—").tag(model.settings.telegramChatID)
                        ForEach(model.chatCandidates) { c in
                            Text("\(c.title) · \(c.type) · \(c.chatID)").tag(String(c.chatID))
                        }
                    }
                }
                Toggle("Forward new messages", isOn: $model.settings.forwardingEnabled)
                Toggle("Include SIM number in forwarded text", isOn: $model.settings.includeSIMNumber)
                Toggle("Alert me when the modem or network drops", isOn: $model.settings.healthAlerts)
                Toggle("Allow sending SMS from Telegram (reply or /sms)", isOn: $model.settings.telegramSendEnabled)
                    .help("Also controls listening to the chat. Only one Mac per bot token may listen — turn this off on any other Mac using the same bot.")
                if model.settings.telegramSendEnabled {
                    TextField("Allowed Telegram user IDs (optional)", text: $model.settings.telegramAllowedUserIDs,
                              prompt: Text("empty = anyone in the chat · e.g. 12345678, 87654321"))
                    HStack(spacing: 6) {
                        Circle().fill(model.telegramListening ? .green : .secondary).frame(width: 7, height: 7)
                        Text(model.telegramListening ? "Listening for replies and /sms commands"
                                                      : "Not listening yet")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Send test message") { Task { await model.testTelegram() } }
                        .disabled(!model.settings.telegramConfigured || model.telegramBusy)
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
                Picker("Port", selection: $model.settings.portPath) {
                    Text("Auto-detect ML307").tag("")
                    ForEach(ports, id: \.self) { p in
                        Text(p.replacingOccurrences(of: "/dev/", with: "")).tag(p)
                    }
                    if !model.settings.portPath.isEmpty, !ports.contains(model.settings.portPath) {
                        Text(model.settings.portPath).tag(model.settings.portPath)
                    }
                }
                .onAppear { ports = SerialPort.candidatePaths() }
                Toggle("Delete from SIM after saving", isOn: $model.settings.deleteFromSIM)
                Toggle("Network status LED (blinking green)", isOn: $model.settings.networkLED)
                Stepper("Sweep SIM every \(model.settings.pollIntervalSeconds)s",
                        value: $model.settings.pollIntervalSeconds, in: 5...300, step: 5)
            }

            Section("App") {
                Toggle("Run at login & restart if it crashes", isOn: Binding(
                    get: { model.keepAlive },
                    set: { model.keepAlive = $0 }
                ))
                .disabled(!model.canManageKeepAlive)
                .help(model.canManageKeepAlive ? "Installs a LaunchAgent in ~/Library/LaunchAgents so launchd supervises the app."
                                               : "Available when running from the .app in /Applications")
                HStack {
                    Text(model.keepAliveStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Login Items…") { KeepAlive.openLoginItemsSettings() }
                        .controlSize(.small)
                        .help("If macOS shows \(AppInfo.displayName) as 'not allowed in the background', enable it here.")
                }
                .onAppear { model.refreshKeepAliveStatus() }
                Toggle("Prevent idle sleep while modem is connected", isOn: $model.settings.preventSystemSleep)
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
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
