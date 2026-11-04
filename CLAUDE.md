# WhoZup iOS

Workspace rules, decisions and runbooks live one level up: `../CLAUDE.md` and `../docs/`
(loaded automatically when you work from `/Users/shark/Documents/Alarm`). The Android twin is
`../WhoZupAndroid` — every behaviour change here needs the matching change there.

- SwiftUI, iOS 26.1+, AlarmKit. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; shared types used by
  intents/widgets are `nonisolated`. Files are auto-included (synchronized folders).
- Targets: `WhoZup` (app), `WhoZupWidgets` (Live Activity), `WhoZupNotifications` (event RSVP
  content extension), tests `WhoZupTests`. `WhoZupShared/` compiles into app + widget
  (`WIDGET_EXTENSION` condition hides app-only code).
- This repo also owns the backend config: `firestore.rules`, `functions/`, `public/`, `firebase.json`.
- Build: `xcodebuild -scheme WhoZup -destination 'generic/platform=iOS' -derivedDataPath build-device -allowProvisioningUpdates build -quiet`.
  Tests: `xcodebuild test -scheme WhoZup -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4'`.
- In AppIntents use Firestore completion-handler APIs, not async overloads (they hang there).
- `project.pbxproj` frequently has the user's own uncommitted Xcode edits — leave them out of commits.
