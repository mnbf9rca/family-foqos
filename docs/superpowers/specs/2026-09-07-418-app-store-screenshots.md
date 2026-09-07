# App Store screenshots for V2 (#418)

**Date:** 2026-09-07
**Status:** Design for review; ships inside the #418 implementation PR on `feat/418-update-screenshots`
**Scope:** Which screenshots the en-GB listing carries, their order, their captions, and the demo data each one needs. The upload lane itself is issue #418's implementation work and is not designed here.

## Problem

The live listing still shows five V1 screenshots. Two of them show things V2 no longer has: the "Blocking Strategy" radio list, and the "Sync blocks across devices" settings page. The three V2 screenshots the `screenshots` lane produces today (home with an active session, the top of the profile editor, the parent dashboard) were chosen in July 2026, before start triggers, stop conditions, session safety, and the account-wide tag list landed. Nobody has asked whether they are the right set.

## What the listing has to say

The description promises three things, in this order: block distracting apps with a tap, a schedule, or a physical scan; parents lock the rules while kids run their own profiles; and the first three screenshots are what App Store search results show. The set below puts one screenshot on each promise, keeps the parent's management page fourth, and closes with location restrictions, the one V1 screenshot whose feature V2 kept unchanged.

## Decision: five screenshots

| Order | Name | Screen | Caption (en-GB) |
|---|---|---|---|
| 1 | `01-home-active` | Home, "Homework" session running | Block distracting apps, on your terms |
| 2 | `02-profile-triggers` | Profile editor, scrolled to "Start by..." and "Continue until..." | Start with a tap, a schedule or an NFC tag |
| 3 | `03-child-locked` | Child dashboard ("My Screen Time") with locked profile cards | Kids run their own profiles. Parents lock the rules |
| 4 | `04-parent-dashboard` | Parent dashboard ("Family Controls") | Manage the lock code from any parent device |
| 5 | `05-location-restrictions` | "Location Restrictions" sheet for "No social at work", map preview of "Work" | Stays blocked until you leave work |

### 1. Home with an active session (unchanged)

Keep the current scenario and caption. It is the screen people use every day, and the timer, "Stop" button, break control, and the "Breaks" chip show the product working rather than being configured. The habit tracker above the card shows the seeded history.

### 2. Profile editor at the trigger sections (replaces `02-profile-editor`)

The current screenshot shows the top of the editor: the name field and the app picker. Every app blocker has an app picker, and its caption, "Pick the strategy that works for you", names a V1 concept that V2 removed. The V2 difference is that a profile chooses how it starts ("Start by...") and what ends it ("Continue until..."), with NFC, QR, schedule, timer, and tap as the choices.

Staging:

- Open the "Deep Focus" profile (manual or any-NFC start, any-NFC stop) instead of the first profile.
- Scroll the form until the "Start by..." section header is at or near the top of the screen. The "Continue until..." header must also be visible. If the "Session Safety" rows fit above "Start by...", that is welcome but not required.
- The UI test waits for both headers, then captures.

### 3. Child dashboard with locked profiles (new)

Nothing in the current set shows the family promise from the child's side, and that promise is the reason the app exists apart from upstream Foqos. The child dashboard shows it in one frame: "Linked to Parent", "Lock code active", orange locked-profile cards with "6 apps blocked", and the caption "These profiles require a lock code to edit or delete". The V1 listing carried this message with a locked profile editor; the dashboard says it with less chrome.

Staging, as a new `child-locked` scenario:

- Select `.child` mode in the seeder for this scenario only.
- Mark "School Nights", "Homework", and "Bedtime" as managed (`isManaged = true`, `managedByChildId = "_demo-emma"`) for this scenario only, so three locked cards render and "My Profiles" reads "1 profile you can edit". Other scenarios keep today's seed, where only "Homework" is managed.
- Keep `isConnectedToFamily = true` and set `isShareOwner = false`, because a child is never the share owner.
- In Child mode `LockCodeManager.canVerifyCode` reads the private cache of shared lock codes, not `lockCodes`. Extend `seedForScreenshots` to fill that cache too, so the link card reads "Lock code active".
- Present `ChildDashboardView` as a sheet from `HomeView` in the existing `#if DEBUG` `onAppearApp` seam, the same way `parent-dashboard` presents `ParentDashboardView`. In the real app the dashboard is a sheet from Settings; the frame looks the same.
- `ChildDashboardView.verifyChildAuthorization()` runs in the view's `.task` and calls the real Family Controls `requestAuthorization(for: .child)`, which fails on a simulator and shows an alert over the capture. Add `guard !ScreenshotDemoMode.isActive else { return }` as the first line of that view method, the same pattern `HomeView` uses. Real users are unaffected because `isActive` is a compile-time `false` outside DEBUG. No change to `AuthorizationVerifier`.
- The UI test waits for the "Locked Profiles" header, asserts that no alert is present, then captures.

### 4. Parent dashboard (unchanged, renumbered)

Keep the current scenario and caption. It is the parent's one management page, and the V1 listing already sells it with the same caption.

### 5. Location restrictions (new; human ruling 2026-09-07)

V1 sold this feature with a map and V2 kept it unchanged. The frame tells one story (human ruling 2026-09-07): a profile called "No social at work" can only be switched off once you have left "Work". The sheet shows the "Must be outside" rule ("Stop only away from selected locations") selected, the "Work" location row, and the "Preview" map with the location's circle and pin. The map preview draws its region and circle from the saved location's own coordinates and has no user-location dot, so the picture depends on map tiles loading, not on the device position. The screenshot Mac has internet access, so tiles load.

Staging, as a new `location-restrictions` scenario:

- Seed one `SavedLocation` named "Work" at latitude 51.5054, longitude -0.0235 (Canary Wharf, London) with the default 500 m radius, for this scenario only.
- Seed one extra profile named "No social at work" (manual start, manual stop) for this scenario only, carrying a `geofenceRule` of type `.outside` that references "Work", so the picker opens with "Must be outside" selected, the row ticked, and the "Preview" section present. The four standard profiles are unchanged.
- `HomeView` opens "No social at work" for editing in the existing `onAppearApp` seam, and `BlockedProfileView` sets `showingGeofencePicker = true` in its `onAppear` when this scenario is active. In the real app the sheet opens from the "Location Restrictions" row; the frame looks the same.
- The UI test pins the simulator (below), waits for the "Restriction Type" and "Preview" headers, waits three seconds for map tiles, then captures.
- Location permission is requested only on the stop and emergency-unblock paths (`GeofenceEvaluator`, `StrategyManager`), never at launch or when the picker opens, so no permission alert can cover the capture and no code guard is needed.

Simulator position, inside the gated capture flow: fastlane snapshot kills and shuts down the booted simulator before it launches the tests (`snapshot/lib/snapshot/simulator_launchers/simulator_launcher_base.rb`, `prepare_simulators_for_launch`, in the pinned fastlane 2.238.0), and the gate's `xcrun` adapter routes that shutdown to the gate-owned UUID. A pin set from the lane before `snapshot` therefore may not survive to capture. The pin is set from inside the UI test instead, after that restart and immediately before capture:

```swift
let work = CLLocation(latitude: 51.5054, longitude: -0.0235)
XCUIDevice.shared.location = XCUILocation(location: work)
```

`XCUIDevice.location` is "the location currently being simulated by the device" (XCUIAutomation, iOS 16.4 and later; the project's Xcode 26 toolchain has it). The test reads the property back and asserts the coordinate equals 51.5054, -0.0235 before it captures, so the effect is checked at capture time in the same lifecycle that captures. This puts the device "at work" to match the story. No Fastfile step and no `simctl` call are needed; the gate wrapper still owns the simulator as before.

## Not included, and why
- **Device sync settings page.** A page of toggles sells nothing the description does not already say. Sync stays in the description text.
- **Blocking strategy picker.** V2 removed the concept. Screenshot 2 replaces it.
- **Tags list, Stats for Nerds, Emergency Unblock, intro pages.** The tag list is a plain list. Stats are not a listing promise and the habit tracker in screenshot 1 already hints at history. The emergency sheet reads as a warning, not a feature. Intro pages are not the product.

## Implementation notes for the #418 PR

- `FoqosUITests/ScreenshotTests.swift`: rename `testProfileEditorScreenshot` to open "Deep Focus" and scroll to the trigger sections; add `testChildLockedScreenshot` and `testLocationRestrictionsScreenshot` (the latter imports CoreLocation and pins the device as in section 5); renumber the parent dashboard snapshot to `04-parent-dashboard`.
- `Foqos/Utils/ScreenshotDemoMode.swift`: add `childLocked = "child-locked"` and `locationRestrictions = "location-restrictions"`.
- `Foqos/Views/Child/ChildDashboardView.swift`: the demo guard in `verifyChildAuthorization()` described above.
- `Foqos/Utils/ScreenshotDemoSeeder.swift`: the scenario-specific changes above. Unit-test the child scenario the same way `ScreenshotDemoSeederTests` covers the others: mode is `.child`, three managed profiles, cached lock code present. Unit-test the location scenario: one saved location named "Work" at 51.5054, -0.0235, and a fifth profile "No social at work" carries an `.outside` rule referencing it.
- `Foqos/Views/BlockedProfileView.swift`: the `onAppear` seam that opens the location picker in the `location-restrictions` scenario, inside `#if DEBUG`.
- `fastlane/Fastfile`: `assert_framed_screenshots` lists the five names and derives the expected count from the list instead of the literal `3`.
- `fastlane/screenshots/en-GB/title.strings`: the five captions above. The captions must render without clipping at the current frame font size; the final PNG inspection is the check. If one clips, shorten that caption rather than the font.
- Acceptance: `scripts/xcode-stream.sh --agent build1 --session <session> -- scripts/fastlane.sh screenshots` produces exactly five framed en-GB images, the location frame shows rendered map tiles with the "Work" pin and circle rather than a blank map, and the PR description attaches all five images (the PNGs are gitignored) so the maintainer can check them before the lane uploads them.
