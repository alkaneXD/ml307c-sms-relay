import AppKit
import SwiftUI

@main
struct SMSRelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        // One instance per Mac: the modem port is exclusive and two copies would fight over it.
        if KeepAlive.resolveDuplicateInstances() {
            exit(0)
        }
        let m = AppModel()
        m.start()
        _model = State(initialValue: m)
        AppDelegate.debugWindowContent = { AnyView(RootView().environment(m)) }
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Dev aid: `SMSRELAY_DEBUG_WINDOW=1 .build/debug/SMSRelay` shows the popover UI in a normal window.
    @MainActor static var debugWindowContent: (() -> AnyView)?
    private var debugWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only, even when launched as a bare binary during development.
        NSApp.setActivationPolicy(.accessory)

        if ProcessInfo.processInfo.environment["SMSRELAY_DEBUG_WINDOW"] == "1",
           let content = Self.debugWindowContent {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "\(AppInfo.displayName) (debug window)"
            window.contentView = NSHostingView(rootView: content())
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            debugWindow = window
        }
    }
}

/// The status item: cellular bars scaled to the best registered modem's signal, a plain antenna
/// when connected-but-unregistered, a slashed antenna when nothing is connected. With more than
/// one modem the count is shown next to the icon.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            icon
            if model.modems.count > 1 {
                Text("\(model.modems.count)").font(.system(size: 10, weight: .semibold))
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if model.anyRegistered {
            Image(systemName: "cellularbars", variableValue: model.bestSignal.fraction)
        } else if model.anyConnected {
            Image(systemName: "antenna.radiowaves.left.and.right")
        } else {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
        }
    }
}
