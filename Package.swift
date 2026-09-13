// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SMSRelay",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SMSRelayCore", targets: ["SMSRelayCore"]),
        .executable(name: "SMSRelay", targets: ["SMSRelay"]),
    ],
    targets: [
        // Pure logic: PDU coding, AT parsing, SQLite storage, Telegram client. No UI, no serial I/O.
        .target(
            name: "SMSRelayCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Menu bar app: serial port, modem state machine, forwarding loop, SwiftUI.
        .executableTarget(
            name: "SMSRelay",
            dependencies: ["SMSRelayCore"]
        ),
    ]
)
