# Fastlane: Screenshot Automation, Store Submission, and Archive Storage

**Date:** 2026-07-30
**Status:** Approved design (brainstorm output); implementation plan is a separate step
**Scope:** V2 / `main` only. `release/v1` keeps its manual process for its remaining life.

## Goals

1. One-command regeneration of App Store screenshots (fastlane `snapshot` + UI tests + faked demo data).
2. One-command TestFlight upload (`beta`) and App Store submission (`release`), with listing metadata versioned in the repo.
3. Every uploaded build's `.xcarchive`/dSYMs stored in two places: a local archive folder and GitHub release assets.

## Non-goals

- CI: all lanes run locally on the maintainer's Mac.
- Widget / Live Activity screenshots (snapshot cannot capture them).
- V1 branch tooling, `match`, multi-locale screenshots (single locale, matching the live listing).
- Privacy-manifest work (#345) and CloudKit prod schema deploy (#346) remain separate runway items.

## Toolchain and repo layout

- Homebrew Ruby 3.x + Bundler. `Gemfile`/`Gemfile.lock` at repo root pin fastlane exactly; all invocations are `bundle exec fastlane <lane>`. System Ruby 2.6 is not used.
- New files:

```
Gemfile, Gemfile.lock
fastlane/
  Fastfile          # lanes: screenshots, beta, release + shared archive step
  Appfile           # com.cynexia.family-foqos, team BU7526J4QY
  Snapfile          # devices, language, screenshots scheme
  Deliverfile       # deliver config; submission only ever from the release lane
  metadata/         # listing text, seeded via `deliver download_metadata` (starts as V1 copy; V2 rewrite becomes a reviewable diff)
  screenshots/      # generated output (already gitignored)
FoqosUITests/
  SnapshotHelper.swift
  ScreenshotTests.swift
```

- **Auth:** App Store Connect API key (`.p8`) generated once, stored outside the repo (e.g. `~/.appstoreconnect/`), referenced via a gitignored `.env`. The same key backs `-allowProvisioningUpdates` for automatic signing. No Apple ID 2FA prompts; no secrets in git.

## Demo mode (app-side seams)

Activation: `ScreenshotDemoMode.isActive` = launch args contain `--screenshot-demo`; hard-compiled `false` outside `#if DEBUG` (snapshot runs Debug builds; the App Store binary contains none of this). Scenario selection via `--demo-scenario <name>`: `home-active`, `profile-editor`, `parent-dashboard`. One app launch = one staged scenario.

**Shared foundation:** in demo mode the SwiftData container is created in-memory and seeded with 3–4 realistic profiles. Sync engine and CloudKit listeners never start; each manager's fetch/refresh path gets a demo-mode early return so no network calls or error alerts fire.

**Per scenario:**

- `home-active`: one profile with an in-progress session (startTime ≈ 40 min ago) so timer/active UI renders live.
- `profile-editor`: app-selection summary renders from a demo fixture (fake app names/icons) instead of real `ApplicationToken`s, which cannot resolve on a simulator. This is the only view-level demo path; the exact seam is pinned at planning time against the actual view code.
- `parent-dashboard` (grounded in `ParentDashboardView.swift`): force `.parent` mode, `CloudKitManager.isSignedIn = true`, `LockCodeManager.hasAnyLockCode = true`, fixture `familyMembers` (one co-parent, two children) and `HeartbeatManager.monitoredDevices`. Pending-invitation sections stay empty — `CKShare.Participant` is unconstructible; accepted limitation.

**Containment guarantees (dummy data must not bleed into other tests):**

- The launch argument is the only activation path; only `ScreenshotTests` passes it. `FoqosTests` runs without it, and every seam is `guard ScreenshotDemoMode.isActive else { existing behavior }` — inactive means byte-for-byte the current code path.
- Demo seeding touches only the per-launch in-memory container: never the on-disk store, UserDefaults suites, or CloudKit.
- Tripwire unit test asserts `ScreenshotDemoMode.isActive == false` in a normal test run, so any widening of the activation path fails the fast suite.

## Screenshot capture

- `bundle exec fastlane screenshots` runs `snapshot` against a dedicated shared scheme + test plan containing only `FoqosUITests`, so the fast unit-test loop (2–3 s) never boots UI tests.
- `ScreenshotTests` launches the app once per scenario and calls `snapshot("01-home-active")` etc. Status bar (9:41, full signal/battery) handled by snapshot.
- Devices: both sets are captured and uploaded — iPhone 6.9" (ASC-required size) and 6.5". Language: whatever the live listing uses, confirmed when metadata is first pulled.
- **Simulator hygiene (shared machine — other apps use Xcode/sims):** snapshot addresses simulators by name, the pattern AGENTS.md bans for tests because it clones sims into `~/Library/Developer/XCTestDevices` (~16 GB each). The lane records the XCTestDevices directory listing before the run and afterwards deletes only entries created during the run. Never `snapshot reset_simulators` (erases ALL simulators) and never a blanket XCTestDevices purge — other projects' simulators must remain untouched. Actual disk behavior verified during implementation.
- The screenshots lane counts as a build/test activity under the one-implementation-stream-per-machine rule.

## Versioning

- **Build number** = `git rev-list --count HEAD`, injected at build time via `xcargs` (`CURRENT_PROJECT_VERSION` override; pbxproj untouched, no bump commits). Monotonic on `main`; the one-time jump from 19 to ~commit-count is harmless (TestFlight only requires "greater than last"). Any build number maps back to its commit.
- **Marketing version** (`2.0.0`) stays in the pbxproj, edited deliberately when cutting a version.
- **Git hash in the binary:** already exists — a build phase writes `BuildInfo.plist` (`GitCommitSHA`, `GitHasUncommittedChanges`), surfaced via `AppBuildInfo`/DebugView. The lanes inherit it; no new work.

## Lanes

- `beta`: preflight (clean tree, on `main`) → `gym` Release archive, automatic signing (`-allowProvisioningUpdates` + API key) → `pilot` upload to TestFlight beta group → archive-storage step.
- `release`: same build path → `deliver` uploads build + screenshots + `metadata/` → submit for review only after explicit interactive confirmation → archive-storage step.
- `screenshots`: as above; produces `fastlane/screenshots/` consumed by `release`.

## Archive storage (shared step in beta and release)

1. Copy the `.xcarchive` to `~/Archives/family-foqos/FamilyFoqos-<version>-<build>-<shortsha>.xcarchive` (covered by Mac backups).
2. Zip dSYMs and attach to a GitHub release via `gh release create`: betas → prerelease on tag `build/<n>`; App Store releases → release on `v<version>`.
   - GitHub release assets have no expiry (unlike Actions artifacts), 2 GiB/file cap — but no contractual durability SLA, hence the local copy as the second leg.
   - Implementation must confirm the "Protect release tags" ruleset does not block `build/*` tag creation; fallback is attaching beta assets to a rolling prerelease.
3. Failure policy: once the build is safely at Apple, archive-storage failures (e.g. `gh` hiccup) warn but do not fail the lane; the local copy is written first.

## Testing

- Tripwire test: `ScreenshotDemoMode.isActive` false in normal runs.
- Demo fixture seeding unit-tested against an in-memory container (profiles/session exist), so screenshot-day breakage surfaces in the fast suite, not after a simulator boot.
- Lanes verified by running them for real: `screenshots` end-to-end; `beta` against TestFlight. No mocked-ASC tests.

## Error handling and safety rails

- `beta`/`release` refuse a dirty tree or non-`main` branch.
- `release` never auto-submits; explicit confirmation required.
- API key and `.env` never enter git.

## One-time manual steps (maintainer)

1. Generate the App Store Connect API key and place the `.p8` locally.
2. Confirm/pick the TestFlight beta group.
3. `brew install ruby` (if not present) + `bundle install`.

## Decisions log

- Scope: V2/`main` only.
- Screenshots: full snapshot automation with faked data; screens = Home + active session, profile editor/triggers, parent dashboard.
- Metadata: managed in-repo by `deliver`.
- Archives: both local folder and GitHub release assets.
- Approach: canonical fastlane, Bundler-pinned (Approach 1 of 3 presented).
- Build number = commit count (maintainer-confirmed); git hash injection reuses the existing BuildInfo.plist build phase.
- Simulator cleanup must be surgical; machine is shared with other Xcode/simulator work.
