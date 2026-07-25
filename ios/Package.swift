// swift-tools-version:5.9
import PackageDescription

// Offline SwiftPM package for the pure-logic layer of the iOS app.
//
// These are the fidelity-critical ports of nexa_insight's interaction logic
// (domain.ts / classroom.ts / classroom_context / classroomConfig / the realtime
// event dispatch). They depend only on Foundation + CoreGraphics, so they build
// and unit-test without Xcode, a simulator, or any network dependency.
//
// The sources live at the same paths the Xcode target will use
// (NexaInsight/...), so this package is a drop-in: when the Xcode project is
// generated, these files are already in place and already tested.
let package = Package(
    name: "NexaInsightCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    targets: [
        .target(
            name: "NexaInsightCore",
            path: "NexaInsight",
            sources: ["Models", "Logic", "Classroom", "Playback", "Services", "Storage", "Import", "Views", "Shadowing"]
        ),
        .testTarget(
            name: "NexaInsightCoreTests",
            dependencies: ["NexaInsightCore"],
            path: "NexaInsightCoreTests"
        ),
    ]
)
