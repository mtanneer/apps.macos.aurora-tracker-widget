# AuroraTracker — Project Notes

See `README.md` for features, data sources, and build/test instructions. This file is for things a future agent needs but wouldn't derive from reading the code.

## Xcode project format

`AuroraTracker.xcodeproj` uses `PBXFileSystemSynchronizedRootGroup` (folder-based sync) for the `AuroraTracker/` and `AuroraWidget/` target folders — files dropped into those folders are picked up automatically, no manual pbxproj wiring needed.

`Shared/` (code compiled into both targets) is **not** a synchronized group — synced groups only belong to one target. New files added to `Shared/` need manual `PBXBuildFile`/`PBXFileReference` entries and must be added to **both** targets' `PBXSourcesBuildPhase` `files` lists in `project.pbxproj`. Follow the existing pattern for `Shared/NOAAForecast.swift` as a template.

`AuroraTrackerTests/` is a real XCTest target, also wired manually (not synchronized) — same pattern applies when adding test files.

## Building from the CLI

`xcodebuild ... CODE_SIGNING_ALLOWED=NO build` compiles without signing — use this for fast correctness checks.

For a real signed build (needed to test App Group / location / anything requiring entitlements to actually work at runtime), use `xcodebuild ... -allowProvisioningUpdates build`. This still requires that Xcode has been opened at least once with a signed-in Apple ID to register the device and generate provisioning profiles — `xcodebuild` alone cannot do the interactive Apple ID auth step.

## App Group

`B768V573Z6.group.manas.projects.AuroraTracker` shares coarse (rounded to nearest degree) location and cached outlook data between the app and widget extension. If you add/change entitlements, you must also add the capability in Xcode's Signing & Capabilities UI for both targets (not just edit the `.entitlements` file) — the provisioning profile needs to actually grant it, which only Xcode's interactive flow can generate.

A `Couldn't read values in CFPrefsPlistSource ... kCFPreferencesAnyUser` warning in the console on launch is a known cosmetic `cfprefsd` quirk for App Group containers on unnotarized dev builds — it does not indicate a real read/write failure. Verify actual behavior with `defaults read B768V573Z6.group.manas.projects.AuroraTracker` rather than trusting the log line.

## Location

`LocationService.requestAuthorizationAndWait()` awaits the actual permission decision (the plain fire-and-forget `requestWhenInUseAuthorization()` is no longer exposed). Concurrent callers are queued and all resumed. Always use the `AndWait` variant before doing anything that depends on authorization status — the plain fire-and-forget version was the root cause of a real bug where "Enable Location" appeared to do nothing (permission dialog took time to resolve, and the location fetch that followed immediately saw stale `.notDetermined` status and bailed).

macOS App Sandbox requires **both** `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` (Info.plist string) **and** `ENABLE_RESOURCE_ACCESS_LOCATION = YES` (build setting) on the app target — the Info.plist string alone is not sufficient like it is on iOS; without the entitlement, `requestWhenInUseAuthorization()` silently no-ops with no prompt.

## Known pre-existing gotcha (fixed)

`MiniBarChart` previously returned `AnyView` from inside a `GeometryReader` closure with an early `return EmptyView()`. This is a real SwiftUI antipattern that caused a `SIGSEGV` in the WidgetKit Simulator host during view teardown. Avoid `AnyView` + early-return patterns inside `GeometryReader`/other view-builder closures — build the view tree directly instead.
