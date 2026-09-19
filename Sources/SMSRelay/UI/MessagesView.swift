import SMSRelayCore
import SwiftUI

struct MessagesView: View {
    @Environment(AppModel.self) private var model
    @State private var composing = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search sender or text", text: $model.search)
                        .textFieldStyle(.plain)
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { composing.toggle() }
                } label: {
                    Image(systemName: composing ? "xmark" : "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help(composing ? "Close" : "New SMS")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            if composing {
                ComposeView { composing = false }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            if model.page.items.isEmpty {
                ContentUnavailableView(
                    model.search.isEmpty ? "No messages yet" : "No matches",
                    systemImage: "tray",
                    description: Text(model.search.isEmpty ? "Incoming SMS will appear here." : "Try a different search.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.page.items) { message in
                            MessageRow(message: message)
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }

            Divider()
            pagination
        }
    }

    private var pagination: some View {
        HStack {
            Button { model.previousPage() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.page.hasPrevious)
            Spacer()
            Text(pageText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button { model.nextPage() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.page.hasNext)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var pageText: String {
        let p = model.page
        guard p.totalCount > 0 else { return "0 messages" }
        let first = p.pageIndex * p.pageSize + 1
        let last = min(p.totalCount, first + p.items.count - 1)
        return "\(first)–\(last) of \(p.totalCount) · page \(p.pageIndex + 1)/\(p.pageCount)"
    }
}

/// Inline "send an SMS from the SIM" form.
struct ComposeView: View {
    @Environment(AppModel.self) private var model
    var onDone: () -> Void
    @State private var number = ""
    @State private var text = ""
    @State private var error: String?
    @State private var viaModemID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("To (+639171234567)", text: $number)
                .textFieldStyle(.roundedBorder)
            TextField("Message", text: $text, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text(lengthHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Send via SIM") {
                    do {
                        let via = model.selectedModem ?? model.modems.first { $0.id == viaModemID }
                        try model.sendSMS(to: number, text: text.trimmingCharacters(in: .whitespacesAndNewlines), via: via)
                        onDone()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || PDUEncoder.normalizeNumber(number) == nil)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { viaModemID = model.selectedModem?.id ?? model.primaryModem?.id ?? "" }
    }

    private var lengthHint: String {
        guard !text.isEmpty else { return "GSM-7 up to 160 chars per SMS; unicode 70" }
        let parts = (try? PDUEncoder.encodeSubmit(to: "+10000000000", text: text, reference: 0).count) ?? 0
        return "\(text.count) chars · \(parts) SMS"
    }
}

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: StoredMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if message.isOutgoing {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.blue)
                        .help("Sent from the SIM")
                }
                Text(message.sender)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(message.displayDate, format: dateFormat)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusIcon
                    .font(.caption)
                    .help(statusHelp)
            }
            Text(message.body)
                .font(.callout)
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let err = message.forwardError, message.forwardStatus != .sent {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
        .contextMenu {
            Button("Copy text") { model.copyToClipboard(message.body) }
            Button(message.isOutgoing ? "Copy number" : "Copy sender") { model.copyToClipboard(message.sender) }
            Divider()
            if message.isOutgoing {
                Button(message.forwardStatus == .sent ? "Send again" : "Retry send") { model.forwardNow(message) }
            } else {
                Button(message.forwardStatus == .sent ? "Forward again" : "Forward now") { model.forwardNow(message) }
                    .disabled(!model.settings.anyTelegramConfigured)
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(message) }
        }
    }

    private var dateFormat: Date.FormatStyle {
        let sameYear = Calendar.current.isDate(message.displayDate, equalTo: Date(), toGranularity: .year)
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        if !sameYear { style = style.year() }
        return style
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.forwardStatus {
        case .sent: Image(systemName: message.isOutgoing ? "paperplane.fill" : "checkmark.circle.fill").foregroundStyle(.green)
        case .pending: Image(systemName: "clock").foregroundStyle(.secondary)
        case .failed: Image(systemName: "arrow.clockwise.circle").foregroundStyle(.orange)
        case .gaveUp: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .disabled: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        }
    }

    private var statusHelp: String {
        let what = message.isOutgoing ? "Sent via SIM" : "Forwarded"
        switch message.forwardStatus {
        case .sent:
            if let at = message.forwardedAt { return "\(what) \(at.formatted(date: .abbreviated, time: .shortened))" + (message.isOutgoing && message.partCount > 1 ? " · \(message.partCount) parts" : "") }
            return what
        case .pending: return message.isOutgoing ? "Waiting for the modem to send" : "Waiting to forward"
        case .failed: return "Retrying (\(message.forwardAttempts) attempts)"
        case .gaveUp: return "Gave up after \(message.forwardAttempts) attempts — right-click to retry"
        case .disabled: return "Received while forwarding was off"
        }
    }
}
