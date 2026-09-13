import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .messages

    enum Tab: Hashable { case messages, settings, diagnostics }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                StatusHeader()
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
            }
            .frame(maxHeight: headerMaxHeight)

            Divider()

            Picker("", selection: $tab) {
                Text("Messages").tag(Tab.messages)
                Text("Settings").tag(Tab.settings)
                Text("Diagnostics").tag(Tab.diagnostics)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Group {
                switch tab {
                case .messages: MessagesView()
                case .settings: SettingsView()
                case .diagnostics: DiagnosticsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 420, height: 580)
    }

    /// One modem needs ~90pt; grow with more, but never eat the whole popover.
    private var headerMaxHeight: CGFloat {
        let perCard: CGFloat = 92
        return min(CGFloat(max(1, model.modems.count)) * perCard + 8, 260)
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
        var parts = ["\(model.counts.total) messages"]
        if model.counts.pending > 0 { parts.append("\(model.counts.pending) pending") }
        if model.counts.failed > 0 { parts.append("\(model.counts.failed) failed") }
        if !model.settings.forwardingEnabled { parts.append("forwarding off") }
        return parts.joined(separator: " · ")
    }
}
