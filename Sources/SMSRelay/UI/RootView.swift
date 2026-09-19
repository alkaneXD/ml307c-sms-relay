import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .messages

    enum Tab: Hashable { case messages, settings, diagnostics }

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader()
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            Picker("", selection: $tab) {
                Text("Inbox").tag(Tab.messages)
                Text("Settings").tag(Tab.settings)
                Text("Log").tag(Tab.diagnostics)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Group {
                switch tab {
                case .messages:
                    MessagesView()
                case .settings:
                    SettingsView(page: settingsPage)
                case .diagnostics:
                    DiagnosticsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 420, height: 560)
    }

    private var settingsPage: SettingsView.Page {
        model.settingsModemID == "app" ? .app : .modem(model.settingsModemID)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footerText: String {
        if model.settingsModemID == "app" {
            return "\(model.modems.count) modem\(model.modems.count == 1 ? "" : "s")"
        }
        var parts = ["\(model.counts.total) messages"]
        if model.counts.pending > 0 { parts.append("\(model.counts.pending) pending") }
        if model.counts.failed > 0 { parts.append("\(model.counts.failed) failed") }
        if let id = model.selectedModem?.id, !model.settings.modem(id).forwardingEnabled {
            parts.append("forwarding off")
        }
        return parts.joined(separator: " · ")
    }
}
