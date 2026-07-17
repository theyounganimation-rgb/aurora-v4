// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Aurora",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Aurora", targets: ["Aurora"]),
    ],
    targets: [
        .executableTarget(
            name: "Aurora",
            path: "Sources/Aurora",
            exclude: [
                // Historical direct/API motor implementations. Aurora's
                // production action boundary is Codex delegate_task only.
                "ComputerUse",
                "Research",
                "Infrastructure/ApprovalCenter.swift",
                "Tools/ActionAuthorization.swift",
                "Tools/AppleMailService.swift",
                "Tools/AppleNotesService.swift",
                "Tools/CalendarEventService.swift",
                "Tools/ConnectedMailService.swift",
                "Tools/InstalledScreenControlSelfTest.swift",
                "Tools/IntentProposal.swift",
                "Tools/NativeCapabilityRouter.swift",
                "Tools/NativeDesktopControl.swift",
                "Tools/NativeScreenControl.swift",
                "Tools/NotesCapabilityBroker.swift",
                "Tools/ReminderService.swift",
                "Tools/SafeComputerAccess.swift",
                "Tools/TypedCapabilityAuthorization.swift",
                "Tools/YouTubeSearchService.swift",
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Security"),
                .linkedFramework("Speech"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
