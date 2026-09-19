import Foundation

/// Names used throughout the app. `displayName` is what people see; `internalName` is used
/// for paths, labels and identifiers so they stay free of spaces.
enum AppInfo {
    static let displayName = "SMS Relay"
    static let shortName = "SMS Relay"
    static let internalName = "SMSRelay"
    static let bundleID = "dev.smsrelay.app"
    static let launchAgentLabel = "dev.smsrelay.agent"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Previous branding (0.1/0.2 shipped as "Remora"); used only for one-time migration.
    enum Legacy {
        static let appSupportFolder = "Remora"
        static let databaseFile = "remora.sqlite"
        static let logsFolder = "Remora"
        static let launchAgentLabel = "dev.remora.Remora"
        static let appBundleName = "Remora.app"
        static let previousAppBundleName = "ML307C SMS Relay.app"
    }
}
