# App Store screenshots for V2 (#418)

**Date:** 2026-09-07
**Status:** Design for review; ships inside the #418 implementation PR on `feat/418-update-screenshots`
**Scope:** Which screenshots the en-GB listing carries, their order, their captions, and the demo data each one needs. The upload lane itself is issue #418's implementation work and is not designed here.

## Problem

The live listing still shows five V1 screenshots. Two of them show things V2 no longer has: the "Blocking Strategy" radio list, and the "Sync blocks across devices" settings page. The three V2 screenshots the `screenshots` lane produces today (home with an active session, the top of the profile editor, the parent dashboard) were chosen in July 2026, before start triggers, stop conditions, session safety, and the account-wide tag list landed. Nobody has asked whether they are the right set.

## What the listing has to say

The description promises three things, in this order: block distracting apps with a tap, a schedule, or a physical scan; parents lock the rules while kids run their own profiles; and the first three screenshots are what App Store search results show. The set below puts one screenshot on each promise and keeps the parent's management page fourth.

## Decision: four screenshots

| Order | Name | Screen | Caption (en-GB) |
|---|---|---|---|
| 1 | `01-home-active` | Home, "Homework" session running | Block distracting apps, on your terms |
| 2 | `02-profile-triggers` | Profile editor, scrolled to "Start by..." and "Continue until..." | Start with a tap, a schedule or an NFC tag |
| 3 | `03-child-locked` | Child dashboard ("My Screen Time") with locked profile cards | Kids run their own profiles. Parents lock the rules |
| 4 | `04-parent-dashboard` | Parent dashboard ("Family Controls") | Manage the lock code from any parent device |

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

## Not included, and why

- **Location restrictions.** V2 still has the feature and V1 sold it with a map. The map needs tiles from the network on the simulator and a seeded saved location. A blank map is worse than no screenshot. Add it later if the maintainer wants a fifth, after a real run shows the map renders.
- **Device sync settings page.** A page of toggles sells nothing the description does not already say. Sync stays in the description text.
- **Blocking strategy picker.** V2 removed the concept. Screenshot 2 replaces it.
- **Tags list, Stats for Nerds, Emergency Unblock, intro pages.** The tag list is a plain list. Stats are not a listing promise and the habit tracker in screenshot 1 already hints at history. The emergency sheet reads as a warning, not a feature. Intro pages are not the product.

## Implementation notes for the #418 PR

- `FoqosUITests/ScreenshotTests.swift`: rename `testProfileEditorScreenshot` to open "Deep Focus" and scroll to the trigger sections; add `testChildLockedScreenshot`; renumber the parent dashboard snapshot to `04-parent-dashboard`.
- `Foqos/Utils/ScreenshotDemoMode.swift`: add `childLocked = "child-locked"`.
- `Foqos/Views/Child/ChildDashboardView.swift`: the demo guard in `verifyChildAuthorization()` described above.
- `Foqos/Utils/ScreenshotDemoSeeder.swift`: the scenario-specific changes above. Unit-test the child scenario the same way `ScreenshotDemoSeederTests` covers the others: mode is `.child`, three managed profiles, cached lock code present.
- `fastlane/Fastfile`: `assert_framed_screenshots` lists the four names and derives the expected count from the list instead of the literal `3`.
- `fastlane/screenshots/en-GB/title.strings`: the four captions above. The captions must render without clipping at the current frame font size; the final PNG inspection is the check. If one clips, shorten that caption rather than the font.
- Acceptance: `scripts/xcode-stream.sh --agent build1 --session <session> -- scripts/fastlane.sh screenshots` produces exactly four framed en-GB images, and the PR description attaches those four images (the PNGs are gitignored) so the maintainer can check them before the lane uploads them.
