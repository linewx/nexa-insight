# Nexa Insight — iOS App

Native SwiftUI client for the Nexa Insight learning app. After an episode is
imported+downloaded from the thin backend, everything runs on-device; the live
voice class talks directly to Qwen Realtime with your own key (no backend).

## Layout

- `Package.swift` — SwiftPM package `NexaInsightCore`. Builds + unit-tests the
  whole codebase for macOS (pure logic) and the iOS simulator. This is the test
  entry point.
- `NexaInsight/` — all app source, grouped by responsibility (Models, Logic,
  Services, Storage, Playback, Import, Shadowing, Classroom, Views).
- `NexaInsightCoreTests/` — 61 XCTest cases (interaction logic, store, view models).
- `project.yml` + `generate.sh` — generate the runnable `NexaInsight.xcodeproj`
  app target (gitignored; regenerate on demand).

## Build & test

```bash
# Unit tests (macOS — fastest)
cd ios && swift test

# Unit tests on the iOS simulator
xcodebuild -scheme NexaInsightCore-Package -destination 'platform=iOS Simulator,name=iPhone 15' test

# Runnable app
./generate.sh
xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' build
```

`generate.sh` pins the project to objectVersion 56 because xcodegen 2.46 emits
77 (Xcode 16), which Xcode 15.4 cannot open. Adjust the simulator name to one
installed locally (`xcrun simctl list devices available`).

## Configuration (in-app Settings)

- Backend base URL (default `http://localhost:8000`; use the Mac's LAN IP from a
  real device).
- OpenAI API key — shadowing feedback (stored in Keychain).
- DashScope API key + workspace id — live voice class (stored in Keychain).

## Activating the live voice class (WebRTC)

The live class is fully implemented but ships inactive because its dependency —
the `stasel/WebRTC` binary package — requires GitHub release-asset access that
was unavailable when this was built. `QwenRealtimeTransport.swift` already
contains the real `RTCPeerConnection` implementation behind
`#if canImport(WebRTC)`, with a graceful stub otherwise. To activate:

1. Add the package to `Package.swift`:
   ```swift
   dependencies: [.package(url: "https://github.com/stasel/WebRTC.git", from: "120.0.0")],
   // and on the NexaInsightCore target:
   dependencies: [.product(name: "WebRTC", package: "WebRTC")],
   ```
   And to `project.yml` under the app target:
   ```yaml
   packages:
     WebRTC: { url: https://github.com/stasel/WebRTC.git, from: "120.0.0" }
   targets:
     NexaInsight:
       dependencies: [{ package: WebRTC }]
   ```
2. `./generate.sh && swift package resolve`
3. Rebuild. `canImport(WebRTC)` flips to the real transport automatically — no
   other code changes. ClassroomController, LiveClassSession, and all views are
   unchanged and already unit-tested.

## Known device-only follow-ups

Validate on a physical device (not covered by unit tests): microphone capture,
audio-session routing, a real Qwen WebRTC call, and dual-track (learner+teacher)
recording — the one deferred spec item.
