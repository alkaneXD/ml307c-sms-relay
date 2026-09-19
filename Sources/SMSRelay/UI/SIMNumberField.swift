import SMSRelayCore
import SwiftUI

/// Double-click to type a number when the modem did not report one. Enter saves; Escape cancels.
struct SIMNumberField: View {
    @Environment(AppModel.self) private var model
    let modem: Modem
    var monospaced: Bool = true

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("e.g. +63917…", text: $draft)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }
                    .onAppear { focused = true }
            } else if let number = modem.sim.number, !number.isEmpty {
                Text(number)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .onTapGesture(count: 2) { begin() }
                    .help("Double-click to edit")
            } else if modem.connection.isConnected {
                Text(modem.sim.isReady ? "Number not on SIM" : "SIM: \(modem.sim.status)")
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2, perform: beginIfReady)
                    .help(modem.sim.isReady ? "Double-click to enter the number" : "")
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    private func beginIfReady() {
        guard modem.sim.isReady || modem.sim.iccid != nil else { return }
        begin()
    }

    private func begin() {
        draft = modem.sim.number ?? ""
        editing = true
    }

    private func cancel() {
        editing = false
        focused = false
    }

    private func commit() {
        model.setSIMNumber(draft, for: modem)
        editing = false
        focused = false
    }
}
