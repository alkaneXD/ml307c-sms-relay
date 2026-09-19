import AppKit
import Foundation

/// launchd supervision via a user LaunchAgent that the app writes itself:
/// starts at login and is relaunched if it ever exits abnormally. Quitting from the
/// menu is a clean exit and is *not* restarted.
///
/// A plain LaunchAgent (not SMAppService) is used on purpose: SMAppService pins the job to
/// the binary's code-signing identity, which changes with every ad-hoc-signed build, so a
/// routine update would leave launchd unable to spawn the app (EX_CONFIG / codesigning).
enum KeepAlive {
    static let label = AppInfo.launchAgentLabel
    private static let managedEnv = "SMSRELAY_LAUNCHD"

    /// True when this process was spawned by our launchd agent (env set in the plist).
    static var isLaunchdManaged: Bool {
        let env = ProcessInfo.processInfo.environment
        return env[managedEnv] == "1" || env["REMORA_LAUNCHD"] == "1"
    }

    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    private static var agentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }
    private static var plistURL: URL { agentsDir.appendingPathComponent("\(label).plist") }
    private static var executablePath: String { Bundle.main.executablePath ?? Bundle.main.bundlePath + "/Contents/MacOS/\(AppInfo.internalName)" }
    private static var domain: String { "gui/\(getuid())" }

    /// Enabled = plist present and pointing at this app.
    static var isEnabled: Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return false }
        return args.first == executablePath
    }

    static var isLoaded: Bool {
        launchctl(["print", "\(domain)/\(label)"]) == 0
    }

    static var statusText: String {
        if !isAvailable { return "Available when running from the .app" }
        if isEnabled {
            if isLaunchdManaged { return "Supervised by launchd — restarts automatically if it crashes" }
            if isLoaded { return "Enabled — launchd will supervise from the next start" }
            return "Enabled — supervision starts at next login"
        }
        if FileManager.default.fileExists(atPath: plistURL.path) {
            return "Enabled for a different copy of the app — toggle off and on to fix"
        }
        return "Off — the app only runs while you keep it open"
    }

    static func enable() throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "EnvironmentVariables": [managedEnv: "1"],
            "AssociatedBundleIdentifiers": Bundle.main.bundleIdentifier ?? label,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        startSupervisedCopy()
    }

    /// Drop a loaded job before bootstrap so launchd does not keep a stale ProgramArguments
    /// (rename /Applications/ML307C SMS Relay.app → SMS Relay.app left EX_CONFIG 78).
    private static func unloadAgent() {
        _ = launchctl(["bootout", "\(domain)/\(label)"])
    }

    /// Removes the agent so it no longer starts at login. The current session is left alone
    /// (a still-loaded job just means a crash would still be caught until logout).
    static func disable() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
        if !isLaunchdManaged {
            _ = launchctl(["bootout", "\(domain)/\(label)"])
        }
    }

    /// Ask launchd to run the supervised copy now. If the job is already loaded but idle
    /// (e.g. after an update), kickstart it. The new copy then terminates any manual copy.
    static func startSupervisedCopy() {
        if !isLaunchdManaged {
            unloadAgent()
        }
        if launchctl(["bootstrap", domain, plistURL.path]) != 0 {
            _ = launchctl(["kickstart", "\(domain)/\(label)"])
        }
    }

    /// If supervision is enabled but this copy was started by hand (Finder, `open`), hand over to
    /// launchd so a crash is always caught. Returns true if the handover was requested.
    static func handOverToLaunchdIfNeeded() -> Bool {
        guard isEnabled, !isLaunchdManaged else { return false }
        startSupervisedCopy()
        return true
    }

    /// 0.1/0.2 registered the agent under the old name pointing at the old bundle. Replace it
    /// with one for this app so supervision continues after the rename. Returns true if migrated.
    static func migrateLegacyAgent() -> Bool {
        var migrated = false
        let oldLabel = AppInfo.Legacy.launchAgentLabel
        let oldPlist = agentsDir.appendingPathComponent("\(oldLabel).plist")
        if FileManager.default.fileExists(atPath: oldPlist.path) {
            _ = launchctl(["bootout", "\(domain)/\(oldLabel)"])
            try? FileManager.default.removeItem(at: oldPlist)
            migrated = true
        }
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let args = plist["ProgramArguments"] as? [String],
           let path = args.first,
           path.contains(AppInfo.Legacy.previousAppBundleName) {
            migrated = true
        }
        if migrated, isAvailable {
            try? enable()
        }
        return migrated
    }

    /// Only one instance may own the modem. The launchd-managed copy always wins so that
    /// enabling supervision hands over seamlessly; otherwise the newer copy backs off.
    /// Returns true if this process should exit.
    static func resolveDuplicateInstances() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return false }
        if isLaunchdManaged {
            for app in others { _ = app.terminate() }
            return false
        }
        return true
    }

    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
