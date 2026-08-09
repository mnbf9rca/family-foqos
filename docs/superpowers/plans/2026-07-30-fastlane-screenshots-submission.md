# Fastlane Screenshots, Submission & Archive Storage — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-command screenshot regeneration (`snapshot` + demo-mode seams), TestFlight/App Store lanes with release-blocker gates, and dual archive storage (local folder + GitHub release assets), per the approved spec `docs/superpowers/specs/2026-07-30-fastlane-screenshots-submission-design.md`.

**Architecture:** Bundler-pinned fastlane with three lanes (`screenshots`, `beta`, `release`) sharing a preflight and an archive-storage step. App-side, a `#if DEBUG`-only `ScreenshotDemoMode` (launch-argument activated) switches the SwiftData container to in-memory, seeds fixtures, forces published state on the manager singletons, and suppresses all CloudKit/network startup work. UI tests in the (currently sourceless) `FoqosUITests` target drive one launch per scenario.

**Tech Stack:** fastlane (snapshot/frameit/gym/pilot/deliver), Bundler + Homebrew Ruby 3.x, `gh` CLI, `xcrun cktool`, ImageMagick (frameit dependency), Swift/SwiftUI/SwiftData.

## Global Constraints

- Scope is V2/`main` only; `release/v1` untouched.
- App Store Connect auth: API key at `~/.appstoreconnect/AuthKey_U2UZLVHKA5.p8`, Key ID `U2UZLVHKA5`, Issuer ID `40dafdb2-c05f-4849-b343-1471a977051e` — referenced only via gitignored `fastlane/.env`, never committed.
- Demo code is `#if DEBUG` only; the only activation path is the `--screenshot-demo` launch argument; inactive means byte-for-byte existing behavior (`guard`-style early returns only).
- Demo seeding touches ONLY the per-launch in-memory container — never the on-disk store, the app-group `SharedData` suite, or CloudKit. (Exception, accepted by spec: `AppModeManager.selectMode` persists to the demo app's own sim-sandbox `UserDefaults.standard`.)
- Simulator hygiene: this machine runs other Xcode/simulator work. NEVER `snapshot reset_simulators`, never blanket-delete `~/Library/Developer/XCTestDevices` — delete only entries created by the current run.
- One implementation stream per machine (AGENTS.md): every build/test step in this plan is part of that single stream.
- Unit tests: `xcodebuild test` with simulator **UUID** destination (never name), Given/When/Then naming, single pinned `Date()` per test.
- Formatting: swift-format via pre-commit hook; 2-space indent; `Log.*` not `print()`.
- Team `BU7526J4QY`, app id `com.cynexia.family-foqos`, container `iCloud.com.cynexia.family-foqos`, automatic signing.
- Commits: never force/amend; new commits only.

## Phase map

- **Phase A (Tasks 1–4):** fastlane foundation + `beta` lane. No app-code changes. Independently shippable.
- **Phase B (Tasks 5–9):** app-side demo mode. Independently shippable (unit-tested, invisible in production).
- **Phase C (Tasks 10–11):** UI tests + `screenshots` lane + frameit. Depends on B.
- **Phase D (Tasks 12–13):** metadata + `release` lane with gates. Depends on A; screenshots optional at deliver time.

---

### Task 1: Toolchain — Gemfile, .env, gitignore

**Files:**
- Create: `Gemfile`
- Create: `fastlane/.env.template`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `bundle exec fastlane` runnable; `ENV["ASC_KEY_ID"]`, `ENV["ASC_ISSUER_ID"]`, `ENV["ASC_KEY_PATH"]` available to all later lane code via dotenv (fastlane auto-loads `fastlane/.env`).

- [ ] **Step 1: Verify Homebrew Ruby ≥3.0 is installed**

Run: `brew list ruby >/dev/null 2>&1 || brew install ruby; $(brew --prefix ruby)/bin/ruby --version`
Expected: `ruby 3.x`. (System Ruby 2.6 must not be used; all `bundle` invocations below use the brew Ruby: `export PATH="$(brew --prefix ruby)/bin:$PATH"` in the session, and document this in the Fastfile header comment in Task 2.)

- [ ] **Step 2: Create Gemfile**

```ruby
source "https://rubygems.org"

gem "fastlane"
```

- [ ] **Step 3: Install and pin**

Run: `export PATH="$(brew --prefix ruby)/bin:$PATH" && bundle install`
Expected: `Gemfile.lock` created with an exact fastlane version. Run `bundle exec fastlane --version` and confirm it reports that version.

- [ ] **Step 4: Create fastlane/.env.template (committed) and fastlane/.env (not committed)**

`fastlane/.env.template`:
```
# Copy to fastlane/.env and fill in. fastlane auto-loads fastlane/.env.
ASC_KEY_ID=
ASC_ISSUER_ID=
ASC_KEY_PATH=
```

`fastlane/.env` (create locally, DO NOT COMMIT):
```
ASC_KEY_ID=U2UZLVHKA5
ASC_ISSUER_ID=40dafdb2-c05f-4849-b343-1471a977051e
ASC_KEY_PATH=/Users/rob/.appstoreconnect/AuthKey_U2UZLVHKA5.p8
```

- [ ] **Step 5: Extend .gitignore**

Append to `.gitignore` (the fastlane section already ignores `report.xml`, `Preview.html`, `screenshots/**/*.png`, `test_output`):
```
fastlane/.env
fastlane/README.md
vendor/bundle/
.bundle/
```

- [ ] **Step 6: Commit**

```bash
git add Gemfile Gemfile.lock fastlane/.env.template .gitignore
git commit -m "build: add Bundler-pinned fastlane toolchain (#spec 2026-07-30)"
```

---

### Task 2: Appfile + Fastfile skeleton — preflight, build number, API key

**Files:**
- Create: `fastlane/Appfile`
- Create: `fastlane/Fastfile`

**Interfaces:**
- Produces: private lanes `preflight` (dirty-tree + branch guard), `asc_api_key` (returns `app_store_connect_api_key` hash), helper `derived_build_number` (String, `git rev-list --count HEAD`). All later lane tasks call these exact names.

- [ ] **Step 1: Create Appfile**

```ruby
app_identifier("com.cynexia.family-foqos")
team_id("BU7526J4QY")
```

- [ ] **Step 2: Create Fastfile skeleton**

```ruby
# Runs under Homebrew Ruby via Bundler: export PATH="$(brew --prefix ruby)/bin:$PATH" && bundle exec fastlane <lane>
default_platform(:ios)

XCODEPROJ = "FamilyFoqos.xcodeproj"
SCHEME = "FamilyFoqos"
ARCHIVE_DIR = File.expand_path("~/Archives/family-foqos")

platform :ios do
  private_lane :preflight do
    ensure_git_status_clean
    ensure_git_branch(branch: "main")
  end

  private_lane :asc_api_key do
    app_store_connect_api_key(
      key_id: ENV.fetch("ASC_KEY_ID"),
      issuer_id: ENV.fetch("ASC_ISSUER_ID"),
      key_filepath: ENV.fetch("ASC_KEY_PATH")
    )
  end

  def derived_build_number
    sh("git rev-list --count HEAD", log: false).strip
  end

  desc "Prints the derived build number (sanity check)"
  lane :build_number do
    UI.message("Derived build number: #{derived_build_number}")
  end
end
```

- [ ] **Step 3: Verify lanes parse and helpers work**

Run: `bundle exec fastlane lanes` → lists `build_number` without error.
Run: `bundle exec fastlane build_number` → prints an integer > 19 (current commit count).
Run: `bundle exec fastlane run app_store_connect_api_key key_id:"$ASC_KEY_ID" issuer_id:"$ASC_ISSUER_ID" key_filepath:"$HOME/.appstoreconnect/AuthKey_U2UZLVHKA5.p8"` → succeeds (validates the .p8 loads).

- [ ] **Step 4: Commit**

```bash
git add fastlane/Appfile fastlane/Fastfile
git commit -m "build: fastlane Appfile + Fastfile skeleton (preflight, build number, ASC key)"
```

---

### Task 3: Archive-storage step + release-blocker gates

**Files:**
- Modify: `fastlane/Fastfile`
- Create: `scripts/check-prod-schema.sh`
- Create: `fastlane/required-prod-schema.txt`

**Interfaces:**
- Consumes: `derived_build_number` from Task 2.
- Produces: `store_archive(prerelease:)` private lane (reads `lane_context[SharedValues::XCODEBUILD_ARCHIVE]`); `assert_no_release_blockers` private lane; `scripts/check-prod-schema.sh` (exit 0 = schema OK, exit 1 = missing entries, other = query failure).

- [ ] **Step 1: Write the schema-gate script**

`scripts/check-prod-schema.sh` (chmod +x):
```bash
#!/bin/bash
# Release gate: verify every record type this build requires exists in the
# DEPLOYED CloudKit PRODUCTION schema. Fails closed: any cktool error aborts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQUIRED_FILE="$REPO_ROOT/fastlane/required-prod-schema.txt"
TEAM_ID="BU7526J4QY"
CONTAINER_ID="iCloud.com.cynexia.family-foqos"

SCHEMA=$(xcrun cktool export-schema \
  --team-id "$TEAM_ID" \
  --container-id "$CONTAINER_ID" \
  --environment production)

missing=0
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  if ! grep -qF "$line" <<<"$SCHEMA"; then
    echo "MISSING in production schema: $line"
    missing=1
  fi
done <"$REQUIRED_FILE"

if [[ "$missing" -eq 1 ]]; then
  echo "Production schema is behind this build. Deploy via CloudKit Console (#346), then re-run."
  exit 1
fi
echo "Production schema OK."
```

- [ ] **Step 2: Generate the required-schema file from the development environment**

Run: `xcrun cktool export-schema --team-id BU7526J4QY --container-id iCloud.com.cynexia.family-foqos --environment development | grep "RECORD TYPE" | sed 's/ (//' | sed 's/^ *//' > fastlane/required-prod-schema.txt`

Then open `fastlane/required-prod-schema.txt`, prepend this header, and review the list against what V2 actually reads/writes (keep all `RECORD TYPE X` lines; they are the V2 requirement set):
```
# Record types the current build requires in the PRODUCTION CloudKit schema.
# Checked by scripts/check-prod-schema.sh (release lane gate).
# Regenerate from the development environment when the schema grows.
```

- [ ] **Step 3: Verify the gate fails today (that is the correct current state)**

Run: `./scripts/check-prod-schema.sh; echo "exit: $?"`
Expected: prints `MISSING in production schema: ...` for the V2 sync record types (production currently holds only V1-era family types — confirmed 2026-07-30) and `exit: 1`. If it prints `Production schema OK.`, STOP — the required file was generated wrong (it must contain V2 types absent from production while #346 is open).

- [ ] **Step 4: Add gates + archive storage to Fastfile**

Inside `platform :ios do`:
```ruby
  private_lane :assert_no_release_blockers do
    # Fail closed: if gh errors (network, auth), sh raises and the lane aborts.
    out = sh("gh issue list --state open --label release-blocking --json number,title", log: false)
    issues = JSON.parse(out)
    unless issues.empty?
      list = issues.map { |i| "##{i["number"]} #{i["title"]}" }.join("\n  ")
      UI.user_error!("Release blocked by open release-blocking issues:\n  #{list}")
    end
    sh("./scripts/check-prod-schema.sh")
  end

  # Copies the .xcarchive locally, zips dSYMs, attaches them to a GitHub release.
  # GitHub failure warns but does not fail (local copy is the safety net and is written first).
  private_lane :store_archive do |options|
    archive = lane_context[SharedValues::XCODEBUILD_ARCHIVE]
    UI.user_error!("No xcarchive in lane context") if archive.nil? || !File.exist?(archive)

    version = get_version_number(xcodeproj: XCODEPROJ, target: "FamilyFoqos")
    build = derived_build_number
    sha = sh("git rev-parse --short=7 HEAD", log: false).strip
    stem = "FamilyFoqos-#{version}-#{build}-#{sha}"

    FileUtils.mkdir_p(ARCHIVE_DIR)
    local_copy = File.join(ARCHIVE_DIR, "#{stem}.xcarchive")
    FileUtils.rm_rf(local_copy)
    FileUtils.cp_r(archive, local_copy)
    UI.success("Archive stored: #{local_copy}")

    dsym_zip = File.join(ARCHIVE_DIR, "#{stem}-dSYMs.zip")
    sh("cd '#{archive}/dSYMs' && zip -qr '#{dsym_zip}' .")

    tag = options[:prerelease] ? "build/#{build}" : "v#{version}"
    begin
      flags = options[:prerelease] ? "--prerelease" : ""
      sh("gh release create '#{tag}' #{flags} --title '#{stem}' " \
         "--notes 'Automated archive upload (dSYMs) for #{stem}.' '#{dsym_zip}'")
      UI.success("dSYMs attached to GitHub release #{tag}")
    rescue => e
      UI.important("GitHub release upload FAILED (local archive is safe): #{e.message}")
    end
  end
```
Add `require "json"` and `require "fileutils"` at the top of the Fastfile.

- [ ] **Step 5: Verify the pieces without a real build**

Run: `bundle exec fastlane run get_version_number xcodeproj:FamilyFoqos.xcodeproj target:FamilyFoqos` → `2.0.0`.
Create a throwaway lane temporarily (delete before commit) or use `bundle exec fastlane lanes` to confirm parsing. Then exercise the blocker gate directly by adding a temporary public lane `lane :gates do assert_no_release_blockers end`, running `bundle exec fastlane gates`, and confirming it ABORTS listing #345 and #346 (both open). Keep the `gates` lane — it is useful standalone; document it with `desc "Run release-blocker gates only"`.

- [ ] **Step 6: Commit**

```bash
git add fastlane/Fastfile scripts/check-prod-schema.sh fastlane/required-prod-schema.txt
git commit -m "build: release-blocker gates (label + prod-schema) and archive storage step"
```

---

### Task 4: `beta` lane (gym + pilot) — CHECKPOINT with maintainer

**Files:**
- Modify: `fastlane/Fastfile`

**Interfaces:**
- Consumes: `preflight`, `asc_api_key`, `derived_build_number`, `store_archive` (Tasks 2–3).
- Produces: `lane :beta` — the TestFlight command.

- [ ] **Step 1: Add the beta lane**

```ruby
  desc "Build and upload to TestFlight, then store the archive (local + GitHub prerelease)"
  lane :beta do
    preflight
    api_key = asc_api_key
    build = derived_build_number
    gym(
      project: XCODEPROJ,
      scheme: SCHEME,
      configuration: "Release",
      export_method: "app-store",
      xcargs: "CURRENT_PROJECT_VERSION=#{build} -allowProvisioningUpdates " \
              "-authenticationKeyPath #{File.expand_path(ENV.fetch('ASC_KEY_PATH'))} " \
              "-authenticationKeyID #{ENV.fetch('ASC_KEY_ID')} " \
              "-authenticationKeyIssuerID #{ENV.fetch('ASC_ISSUER_ID')}"
    )
    pilot(api_key: api_key, skip_waiting_for_build_processing: true)
    store_archive(prerelease: true)
  end
```

- [ ] **Step 2: Run it for real (maintainer present)**

Run: `bundle exec fastlane beta` on a clean `main` checkout.
Expected: archive succeeds with automatic signing, upload reaches TestFlight, `~/Archives/family-foqos/FamilyFoqos-2.0.0-<build>-<sha>.xcarchive` exists, and a `build/<n>` prerelease appears on GitHub with the dSYM zip. Group assignment to the son's TestFlight group happens manually in ASC (one-time, per spec).
**This step needs the maintainer**: first build on the account may prompt export-compliance questions in ASC. Report results and STOP for review before Phase B.

- [ ] **Step 3: Commit**

```bash
git add fastlane/Fastfile
git commit -m "build: beta lane — gym + pilot + archive storage"
```

---

### Task 5: `ScreenshotDemoMode` + tripwire test (TDD)

**Files:**
- Create: `Foqos/Utils/ScreenshotDemoMode.swift`
- Test: `FoqosTests/ScreenshotDemoModeTests.swift`

**Interfaces:**
- Produces: `ScreenshotDemoMode.isActive: Bool`, `ScreenshotDemoMode.scenario: ScreenshotDemoScenario?`, `ScreenshotDemoMode.overrideForTesting: Bool?` (DEBUG-only), `enum ScreenshotDemoScenario: String` with cases `.homeActive = "home-active"`, `.profileEditor = "profile-editor"`, `.parentDashboard = "parent-dashboard"`. All later tasks reference these exact names.

- [ ] **Step 1: Write the failing tests**

`FoqosTests/ScreenshotDemoModeTests.swift`:
```swift
import XCTest

@testable import FamilyFoqos

final class ScreenshotDemoModeTests: XCTestCase {
  override func tearDown() {
    ScreenshotDemoMode.overrideForTesting = nil
    super.tearDown()
  }

  // Tripwire (spec containment guarantee): demo mode must be OFF in a normal test run.
  // If this ever fails, the activation path has widened — that is a release blocker.
  func testGivenNormalTestRun_WhenCheckingDemoMode_ThenInactive() {
    XCTAssertFalse(ScreenshotDemoMode.isActive)
    XCTAssertNil(ScreenshotDemoMode.scenario)
  }

  func testGivenOverrideActive_WhenCheckingIsActive_ThenActive() {
    ScreenshotDemoMode.overrideForTesting = true
    XCTAssertTrue(ScreenshotDemoMode.isActive)
  }

  func testGivenScenarioRawValues_WhenParsing_ThenAllThreeResolve() {
    XCTAssertEqual(ScreenshotDemoScenario(rawValue: "home-active"), .homeActive)
    XCTAssertEqual(ScreenshotDemoScenario(rawValue: "profile-editor"), .profileEditor)
    XCTAssertEqual(ScreenshotDemoScenario(rawValue: "parent-dashboard"), .parentDashboard)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Boot the simulator once (AGENTS.md): `xcrun simctl list devices available | grep "iPhone 17"`, then `xcrun simctl boot <UUID>`.
Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/ScreenshotDemoModeTests | xcpretty`
Expected: BUILD FAILURE — `ScreenshotDemoMode` not defined.

- [ ] **Step 3: Implement**

`Foqos/Utils/ScreenshotDemoMode.swift`:
```swift
import Foundation

/// Scenario staged by one demo-mode app launch (one launch = one screenshot scene).
enum ScreenshotDemoScenario: String {
  case homeActive = "home-active"
  case profileEditor = "profile-editor"
  case parentDashboard = "parent-dashboard"
}

/// Screenshot demo mode: active ONLY when launched with `--screenshot-demo`
/// (fastlane snapshot UI tests). Compiled to a constant `false` outside DEBUG,
/// so no demo path exists in the App Store binary.
enum ScreenshotDemoMode {
  #if DEBUG
    /// Test-only escape hatch so unit tests can exercise demo-gated code paths.
    static var overrideForTesting: Bool?

    static var isActive: Bool {
      if let overrideForTesting { return overrideForTesting }
      return ProcessInfo.processInfo.arguments.contains("--screenshot-demo")
    }

    static var scenario: ScreenshotDemoScenario? {
      guard isActive else { return nil }
      let args = ProcessInfo.processInfo.arguments
      guard let flagIndex = args.firstIndex(of: "--demo-scenario"),
        args.indices.contains(flagIndex + 1)
      else { return nil }
      return ScreenshotDemoScenario(rawValue: args[flagIndex + 1])
    }
  #else
    static let isActive = false
    static let scenario: ScreenshotDemoScenario? = nil
  #endif
}
```
Add the file to the `FamilyFoqos` target (pbxproj: PBXFileReference + PBXBuildFile + entry in the `Utils` PBXGroup + the FamilyFoqos target's Sources phase — follow the pattern of the neighboring `Foqos/Utils/SafeQuery.swift` entries; generate new 24-hex-uppercase UUIDs with `uuidgen | tr -d '-' | cut -c1-24`).

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Foqos/Utils/ScreenshotDemoMode.swift FoqosTests/ScreenshotDemoModeTests.swift FamilyFoqos.xcodeproj/project.pbxproj
git commit -m "feat: ScreenshotDemoMode launch-arg gate with tripwire test"
```

---

### Task 6: Startup guards — container swap + CloudKit suppression

**Files:**
- Modify: `Foqos/FoqosApp.swift` (container global ~line 36-50; scenePhase block ~line 135-169; `.onAppear` ~line 275-296; `AppDelegate.didFinishLaunchingWithOptions` ~line 360)
- Modify: `Foqos/CloudKit/CloudKitManager.swift` (`checkAccountStatus` line 59, `verifySelfFamilyMemberRecord` line 243, `refreshShareParticipants` line 206, `syncShareParticipantsToFamilyMembers` line 253, `fetchFamilyMembers` line 125)
- Modify: `Foqos/Utils/LockCodeManager.swift` (`fetchLockCodes` line 134)
- Modify: `Foqos/Utils/HeartbeatManager.swift` (`refreshHeartbeats` line 130)

**Interfaces:**
- Consumes: `ScreenshotDemoMode.isActive` (Task 5).
- Produces: in demo mode, zero CloudKit/network calls at launch/foreground; container is in-memory. Guard pattern (identical everywhere): `guard !ScreenshotDemoMode.isActive else { return }` as the FIRST statement (or `if !ScreenshotDemoMode.isActive` wrapping, for the FoqosApp blocks).

- [ ] **Step 1: Container swap**

In the file-level `container` closure in `FoqosApp.swift`, change one line:
```swift
    let modelConfiguration = ModelConfiguration(
      schema: schema,
      isStoredInMemoryOnly: ScreenshotDemoMode.isActive,
      cloudKitDatabase: .none
    )
```

- [ ] **Step 2: Guard FoqosApp startup work**

In the `scenePhase == .active` handler, wrap the two `Task { ... }` blocks and the `profileSyncManager.syncNow()` block:
```swift
          if newPhase == .active {
            if !ScreenshotDemoMode.isActive {
              Task {
                await CloudKitManager.shared.checkAccountStatus()
                await CloudKitManager.shared.verifySelfFamilyMemberRecord()
                verifyChildAuthorizationIfNeeded()
                if AppModeManager.shared.currentMode == .child {
                  await LockCodeManager.shared.processPendingCommands()
                }
              }
              Task { await StrategyManager.shared.drainSessionStopOutbox() }
              if profileSyncManager.isEnabled {
                do {
                  try profileSyncManager.syncNow()
                } catch {
                  Log.warning("syncNow skipped: \(error.localizedDescription)", category: .sync)
                }
              }
            }
            // (leave the PreActivationReminderScheduler warm-return block as is)
```
In `.onAppear`, extend the engine-attach guard:
```swift
          if !isRunningUnitTests && !ScreenshotDemoMode.isActive {
            Task {
              await profileSyncManager.attachEngine(
                modelContext: container.mainContext,
                emergencyManager: emergencyManager)
            }
          }
```
In `AppDelegate.didFinishLaunchingWithOptions`, guard remote-notification registration:
```swift
    if !ScreenshotDemoMode.isActive {
      application.registerForRemoteNotifications()
    }
```

- [ ] **Step 3: Guard the manager fetch paths**

First statement of each listed method:
- `CloudKitManager.checkAccountStatus()`, `verifySelfFamilyMemberRecord()`, `refreshShareParticipants()`, `syncShareParticipantsToFamilyMembers()`: `guard !ScreenshotDemoMode.isActive else { return }`
- `CloudKitManager.fetchFamilyMembers()`: `guard !ScreenshotDemoMode.isActive else { return familyMembers }` (returns the seeded array untouched)
- `LockCodeManager.fetchLockCodes()`: `guard !ScreenshotDemoMode.isActive else { return }`
- `HeartbeatManager.refreshHeartbeats()`: `guard !ScreenshotDemoMode.isActive else { return }`

This makes `ParentDashboardView.refreshData()` (which calls four of these) a natural no-op in demo mode with no view changes.

- [ ] **Step 4: Run the full unit suite (regression: guards must change nothing when inactive)**

Run: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty`
Expected: entire suite green (the tripwire test proves `isActive == false` here, so every guard falls through).

- [ ] **Step 5: Commit**

```bash
git add Foqos/FoqosApp.swift Foqos/CloudKit/CloudKitManager.swift Foqos/Utils/LockCodeManager.swift Foqos/Utils/HeartbeatManager.swift
git commit -m "feat: demo-mode startup guards — in-memory container, CloudKit suppression"
```

---

### Task 7: Demo seeder + fixtures (TDD)

**Files:**
- Create: `Foqos/Utils/ScreenshotDemoSeeder.swift`
- Modify: `Foqos/Utils/LockCodeManager.swift` (add DEBUG seeding hook — `lockCodes` is `private(set)`)
- Modify: `Foqos/FoqosApp.swift` (call seeder)
- Test: `FoqosTests/ScreenshotDemoSeederTests.swift`

**Interfaces:**
- Consumes: `ScreenshotDemoMode` (Task 5); models `BlockedProfiles(name:...)`, `BlockedProfileSession(tag:blockedProfile:forceStarted:startTime:)`, `FamilyMember(userRecordName:displayName:role:enrolledAt:isActive:)`, `MonitoredDevice` memberwise init, `FamilyLockCode(code:scope:)`.
- Produces: `ScreenshotDemoSeeder.seed(container:now:)` (@MainActor, DEBUG-only); `LockCodeManager.seedForScreenshots(_:)` (DEBUG-only).

- [ ] **Step 1: Write the failing tests**

`FoqosTests/ScreenshotDemoSeederTests.swift`:
```swift
import SwiftData
import XCTest

@testable import FamilyFoqos

@MainActor
final class ScreenshotDemoSeederTests: XCTestCase {
  private var container: ModelContainer!

  override func setUp() async throws {
    try await super.setUp()
    container = try TestModelContainer.create()
    ScreenshotDemoMode.overrideForTesting = true
  }

  override func tearDown() async throws {
    ScreenshotDemoMode.overrideForTesting = nil
    // Seeder mutates shared singletons; reset so later test classes see clean state.
    CloudKitManager.shared.isSignedIn = false
    CloudKitManager.shared.familyMembers = []
    CloudKitManager.shared.isConnectedToFamily = false
    CloudKitManager.shared.isShareOwner = false
    HeartbeatManager.shared.monitoredDevices = []
    LockCodeManager.shared.seedForScreenshots([])
    try await super.tearDown()
  }

  func testGivenDemoMode_WhenSeeding_ThenProfilesAndActiveSessionExist() throws {
    let now = Date()
    try ScreenshotDemoSeeder.seed(container: container, now: now)

    let context = container.mainContext
    let profiles = try context.fetch(FetchDescriptor<BlockedProfiles>())
    XCTAssertEqual(profiles.count, 4)
    XCTAssertTrue(profiles.contains { $0.isManaged })

    let sessions = try context.fetch(FetchDescriptor<BlockedProfileSession>())
    XCTAssertEqual(sessions.count, 1)
    let session = try XCTUnwrap(sessions.first)
    XCTAssertTrue(session.isActive)
    XCTAssertEqual(session.startTime, now.addingTimeInterval(-2400))
  }

  func testGivenDemoMode_WhenSeeding_ThenFamilyStateIsStaged() throws {
    try ScreenshotDemoSeeder.seed(container: container, now: Date())

    XCTAssertTrue(CloudKitManager.shared.isSignedIn)
    XCTAssertEqual(CloudKitManager.shared.familyMembers.parents.count, 1)
    XCTAssertEqual(CloudKitManager.shared.familyMembers.children.count, 2)
    XCTAssertTrue(LockCodeManager.shared.hasAnyLockCode)
    XCTAssertEqual(HeartbeatManager.shared.monitoredDevices.count, 2)
  }

  func testGivenDemoModeInactive_WhenSeeding_ThenThrowsNothingAndSeedsNothing() throws {
    ScreenshotDemoMode.overrideForTesting = false
    try ScreenshotDemoSeeder.seed(container: container, now: Date())
    let profiles = try container.mainContext.fetch(FetchDescriptor<BlockedProfiles>())
    XCTAssertTrue(profiles.isEmpty)
  }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:FoqosTests/ScreenshotDemoSeederTests | xcpretty`
Expected: BUILD FAILURE — `ScreenshotDemoSeeder` / `seedForScreenshots` not defined.

- [ ] **Step 3: Implement the LockCodeManager hook**

In `Foqos/Utils/LockCodeManager.swift`, inside the class:
```swift
  #if DEBUG
    /// Screenshot/demo + test seeding only — `lockCodes` is private(set).
    func seedForScreenshots(_ codes: [FamilyLockCode]) {
      lockCodes = codes
    }
  #endif
```

- [ ] **Step 4: Implement the seeder**

`Foqos/Utils/ScreenshotDemoSeeder.swift`:
```swift
import Foundation
import SwiftData

#if DEBUG
  /// Seeds the in-memory demo container and stages published singleton state for
  /// screenshot scenarios. Only ever writes to the passed (in-memory) container —
  /// never the on-disk store, SharedData suite, or CloudKit (all guarded off in demo mode).
  @MainActor
  enum ScreenshotDemoSeeder {
    static func seed(container: ModelContainer, now: Date = Date()) throws {
      guard ScreenshotDemoMode.isActive else { return }
      let context = container.mainContext

      let school = BlockedProfiles(
        name: "School Nights", enableLiveActivity: true, reminderTimeInSeconds: 3600, order: 0)
      school.startTriggers = ProfileStartTriggers(manual: true, schedule: true)
      school.stopConditions = ProfileStopConditions(manual: true, schedule: true)
      school.startSchedule = ProfileScheduleTime(
        days: [.sunday, .monday, .tuesday, .wednesday, .thursday], hour: 19, minute: 0,
        updatedAt: now)
      school.stopSchedule = ProfileScheduleTime(
        days: [.sunday, .monday, .tuesday, .wednesday, .thursday], hour: 21, minute: 0,
        updatedAt: now)

      let homework = BlockedProfiles(
        name: "Homework", enableBreaks: true, order: 1, isManaged: true,
        managedByChildId: "_demo-emma")
      homework.startTriggers = ProfileStartTriggers(manual: true)
      homework.stopConditions = ProfileStopConditions(manual: true, timer: true)

      let bedtime = BlockedProfiles(name: "Bedtime", order: 2)
      bedtime.startTriggers = ProfileStartTriggers(schedule: true)
      bedtime.stopConditions = ProfileStopConditions(schedule: true)

      let focus = BlockedProfiles(name: "Deep Focus", enableStrictMode: true, order: 3)
      focus.startTriggers = ProfileStartTriggers(manual: true, anyNFC: true)
      focus.stopConditions = ProfileStopConditions(anyNFC: true)

      for profile in [school, homework, bedtime, focus] {
        context.insert(profile)
      }

      if ScreenshotDemoMode.scenario == .homeActive {
        // Direct init (NOT createSession) so no SharedData/app-group write occurs.
        let session = BlockedProfileSession(
          tag: "manual", blockedProfile: homework, startTime: now.addingTimeInterval(-2400))
        context.insert(session)
      }
      try context.save()

      CloudKitManager.shared.isSignedIn = true
      CloudKitManager.shared.isConnectedToFamily = true
      CloudKitManager.shared.isShareOwner = true
      CloudKitManager.shared.familyMembers = [
        FamilyMember(
          userRecordName: "_demo-alex", displayName: "Alex", role: .parent,
          enrolledAt: now.addingTimeInterval(-86400 * 190)),
        FamilyMember(
          userRecordName: "_demo-emma", displayName: "Emma", role: .child,
          enrolledAt: now.addingTimeInterval(-86400 * 188)),
        FamilyMember(
          userRecordName: "_demo-sam", displayName: "Sam", role: .child,
          enrolledAt: now.addingTimeInterval(-86400 * 92)),
      ]
      LockCodeManager.shared.seedForScreenshots([FamilyLockCode(code: "0000")])
      HeartbeatManager.shared.monitoredDevices = [
        MonitoredDevice(
          deviceIdentifier: "demo-device-emma", deviceName: "Emma's iPhone",
          childUserRecordName: "_demo-emma", lastSeenAt: now.addingTimeInterval(-300),
          isSuppressed: false, notificationIdentifier: nil, authorizationStatus: "approved",
          authRevokedNotifiedAt: nil),
        MonitoredDevice(
          deviceIdentifier: "demo-device-sam", deviceName: "Sam's iPhone",
          childUserRecordName: "_demo-sam", lastSeenAt: now.addingTimeInterval(-1500),
          isSuppressed: false, notificationIdentifier: nil, authorizationStatus: "approved",
          authRevokedNotifiedAt: nil),
      ]

      let mode: AppMode = ScreenshotDemoMode.scenario == .parentDashboard ? .parent : .individual
      AppModeManager.shared.selectMode(mode)
      UserDefaults.standard.set(true, forKey: "family_foqos_has_completed_onboarding")
      UserDefaults.standard.set(false, forKey: "family_foqos_show_intro_screen")
      UserDefaults.standard.set(false, forKey: "family_foqos_show_mode_selection")
    }
  }
#endif
```
Note: if `BlockedProfiles.init` label order differs, match the real signature (name → selectedActivity → ... → order → ... → isManaged → managedByChildId); the compiler enforces it.

- [ ] **Step 5: Wire into FoqosApp**

In `FoqosApp` `.onAppear` (before the reminder-scheduler calls):
```swift
          #if DEBUG
            if ScreenshotDemoMode.isActive {
              do {
                try ScreenshotDemoSeeder.seed(container: container)
              } catch {
                Log.error("Demo seed failed: \(error.localizedDescription)", category: .app)
              }
            }
          #endif
```
Also wrap the `PreActivationReminderScheduler` triple-call in `.onAppear` with `if !ScreenshotDemoMode.isActive { ... }` (no notification scheduling in demo launches).

- [ ] **Step 6: Run tests to verify they pass, then run the FULL suite**

Run: `xcodebuild test ... -only-testing:FoqosTests/ScreenshotDemoSeederTests | xcpretty` → 3 PASS.
Run the full suite → green (singleton resets in tearDown must hold).

- [ ] **Step 7: Commit**

```bash
git add Foqos/Utils/ScreenshotDemoSeeder.swift Foqos/Utils/LockCodeManager.swift Foqos/FoqosApp.swift FoqosTests/ScreenshotDemoSeederTests.swift FamilyFoqos.xcodeproj/project.pbxproj
git commit -m "feat: screenshot demo seeder — profiles, active session, family fixtures"
```

---

### Task 8: App-selection count seam (TDD)

**Files:**
- Modify: `Foqos/Utils/FamilyActivityUtil.swift` (`countSelectedActivities` line ~15)
- Test: `FoqosTests/FamilyActivityUtilDemoTests.swift`

**Interfaces:**
- Consumes: `ScreenshotDemoMode` (Task 5).
- Produces: in demo mode, an empty `FamilyActivitySelection` counts as 6 (so "6 items selected" renders in the editor and card stats). Real (non-empty) selections keep their true count.

Context for the implementer: real `ApplicationToken`s cannot be constructed on a simulator, and the app renders selected apps ONLY as counts — `BlockedProfileAppSelector` → `FamilyActivityUtil.getCountDisplayText` → `countSelectedActivities` (no `Label(token)` icon rows exist anywhere in the repo). Seaming the one count function therefore fakes everything visible.

- [ ] **Step 1: Write the failing test**

```swift
import FamilyControls
import XCTest

@testable import FamilyFoqos

final class FamilyActivityUtilDemoTests: XCTestCase {
  override func tearDown() {
    ScreenshotDemoMode.overrideForTesting = nil
    super.tearDown()
  }

  func testGivenDemoMode_WhenCountingEmptySelection_ThenFakeCountReturned() {
    ScreenshotDemoMode.overrideForTesting = true
    let count = FamilyActivityUtil.countSelectedActivities(FamilyActivitySelection())
    XCTAssertEqual(count, 6)
    XCTAssertEqual(
      FamilyActivityUtil.getCountDisplayText(FamilyActivitySelection()), "6 items")
  }

  func testGivenNormalMode_WhenCountingEmptySelection_ThenZero() {
    XCTAssertEqual(
      FamilyActivityUtil.countSelectedActivities(FamilyActivitySelection()), 0)
  }
}
```

- [ ] **Step 2: Run to verify failure** (`-only-testing:FoqosTests/FamilyActivityUtilDemoTests`) — first test FAILS (returns 0).

- [ ] **Step 3: Implement**

In `FamilyActivityUtil.countSelectedActivities`:
```swift
  static func countSelectedActivities(_ selection: FamilyActivitySelection, allowMode: Bool = false)
    -> Int
  {
    let realCount =
      selection.categories.count + selection.applications.count + selection.webDomains.count
    #if DEBUG
      // Screenshot demo: tokens can't exist on a simulator, so empty selections
      // present a plausible count. Real selections keep their true count.
      if ScreenshotDemoMode.isActive && realCount == 0 { return 6 }
    #endif
    return realCount
  }
```
Then grep for other count surfaces that bypass this util (`grep -rn "applications.count\|categories.count" Foqos/`) — known bypasses `AppSelectionPrompt.swift` and `DebugView.swift` are not screenshot surfaces; leave them. If `BlockedProfileCardData`'s stats row counts via a different path, route it through `FamilyActivityUtil.countSelectedActivities` rather than duplicating the seam.

- [ ] **Step 4: Run tests** — both PASS; run full suite — green.

- [ ] **Step 5: Commit**

```bash
git add Foqos/Utils/FamilyActivityUtil.swift FoqosTests/FamilyActivityUtilDemoTests.swift FamilyFoqos.xcodeproj/project.pbxproj
git commit -m "feat: demo-mode app-selection count seam"
```

---

### Task 9: Scenario auto-presentation in HomeView

**Files:**
- Modify: `Foqos/Views/HomeView.swift` (`.onAppear`, ~line 618-630 region; state vars `profileToEdit` line 29, `showParentDashboard` line 50)

**Interfaces:**
- Consumes: `ScreenshotDemoMode.scenario` (Task 5); seeded profiles (Task 7).
- Produces: launching with `--demo-scenario profile-editor` opens the editor sheet on the first profile; `parent-dashboard` opens the dashboard sheet; `home-active` stays on Home with the seeded session's timer running.

- [ ] **Step 1: Add the hook**

In HomeView's `.onAppear`, after the existing `loadActiveSession` call:
```swift
      #if DEBUG
        if let scenario = ScreenshotDemoMode.scenario {
          // Slight delay so the seeded @SafeQuery results are populated before presenting.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            switch scenario {
            case .profileEditor:
              profileToEdit = profiles.valid.first
            case .parentDashboard:
              showParentDashboard = true
            case .homeActive:
              break
            }
          }
        }
      #endif
```
Verify while here: `loadActiveSession` on a seeded active session must also start the elapsed-time timer (check `StrategyManager.loadActiveSession` — if it does not call `startTimer()` for an active session, add `if strategyManager.isBlocking { strategyManager.startTimer() }` inside the demo hook).

- [ ] **Step 2: Manual verification on the booted simulator**

Run (installs and launches with args):
```bash
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug -destination 'platform=iOS Simulator,id=<UUID>' build | xcpretty
xcrun simctl install <UUID> <path-to-built .app from DerivedData>
xcrun simctl launch <UUID> com.cynexia.family-foqos --screenshot-demo --demo-scenario parent-dashboard
```
Expected: app opens straight to Home (no intro/mode-selection covers), then presents the Family Controls dashboard showing "Lock Code Set", Alex/Emma/Sam, two device-status cards, no iCloud warning, full opacity. Repeat for `home-active` (Homework card active with ~00:40:00 timer) and `profile-editor` (editor sheet, "6 items selected"). Take `xcrun simctl io <UUID> screenshot /tmp/demo-check.png` for each and eyeball.

- [ ] **Step 3: Run full unit suite** — green (hook is scenario-gated; scenario is nil in tests).

- [ ] **Step 4: Commit**

```bash
git add Foqos/Views/HomeView.swift
git commit -m "feat: demo scenario auto-presentation in HomeView"
```

---

### Task 10: FoqosUITests sources + screenshots scheme/test plan

**Files:**
- Create: `FoqosUITests/SnapshotHelper.swift` (fastlane-provided)
- Create: `FoqosUITests/ScreenshotTests.swift`
- Create: `FoqosScreenshots.xctestplan`
- Modify: `FamilyFoqos.xctestplan` (remove the FoqosUITests entry so the fast unit loop never boots UI tests)
- Create: `FamilyFoqos.xcodeproj/xcshareddata/xcschemes/FoqosScreenshots.xcscheme`
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj` (add the two source files to the existing sourceless `FoqosUITests` target, id `801B20AF2CB363A20073E9E2`)

**Interfaces:**
- Consumes: launch args contract from Tasks 5/9 (`--screenshot-demo`, `--demo-scenario <raw>`).
- Produces: shared scheme `FoqosScreenshots` whose Test action runs only `FoqosUITests`; snapshot names `01-home-active`, `02-profile-editor`, `03-parent-dashboard` (Task 11's frameit titles key off these).

- [ ] **Step 1: Get SnapshotHelper**

Run: `bundle exec fastlane snapshot init` in the repo root — this writes `fastlane/Snapfile` (keep for Task 11) and `SnapshotHelper.swift`. Move the helper: `mkdir -p FoqosUITests && mv SnapshotHelper.swift FoqosUITests/` (path may be `fastlane/SnapshotHelper.swift` depending on fastlane version — check `git status`).

- [ ] **Step 2: Write ScreenshotTests**

`FoqosUITests/ScreenshotTests.swift`:
```swift
import XCTest

final class ScreenshotTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(scenario: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["--screenshot-demo", "--demo-scenario", scenario]
    setupSnapshot(app)
    app.launch()
    return app
  }

  @MainActor
  func testHomeActiveScreenshot() throws {
    let app = launch(scenario: "home-active")
    XCTAssertTrue(app.staticTexts["Homework"].waitForExistence(timeout: 15))
    sleep(3)  // let the 1 Hz elapsed timer tick to ~00:40:0x
    snapshot("01-home-active")
  }

  @MainActor
  func testProfileEditorScreenshot() throws {
    let app = launch(scenario: "profile-editor")
    XCTAssertTrue(app.staticTexts["Select Apps to Restrict"].waitForExistence(timeout: 15))
    sleep(1)
    snapshot("02-profile-editor")
  }

  @MainActor
  func testParentDashboardScreenshot() throws {
    let app = launch(scenario: "parent-dashboard")
    XCTAssertTrue(app.staticTexts["Lock Code Set"].waitForExistence(timeout: 15))
    sleep(1)
    snapshot("03-parent-dashboard")
  }
}
```

- [ ] **Step 3: Wire the files into the FoqosUITests target**

pbxproj edits (target `801B20AF2CB363A20073E9E2` exists but has no sources): add two PBXFileReference entries, a `FoqosUITests` PBXGroup (path `FoqosUITests`) under the main group alongside `FoqosTests`, two PBXBuildFile entries, and add both to the target's PBXSourcesBuildPhase (find it via the `buildPhases` list in the PBXNativeTarget block at ~line 358). New UUIDs: `uuidgen | tr -d '-' | cut -c1-24` (uppercase). Verify with `xcodebuild -project FamilyFoqos.xcodeproj -list` still parsing.

- [ ] **Step 4: Test plans + scheme**

`FoqosScreenshots.xctestplan` (repo root, next to the existing plan):
```json
{
  "configurations" : [
    {
      "id" : "8F0C2B4E-0000-4000-9000-FoqosShots01",
      "name" : "Screenshots",
      "options" : { }
    }
  ],
  "defaultOptions" : {
    "targetForVariableExpansion" : {
      "containerPath" : "container:FamilyFoqos.xcodeproj",
      "identifier" : "801B20942CB363A10073E9E2",
      "name" : "FamilyFoqos"
    }
  },
  "testTargets" : [
    {
      "target" : {
        "containerPath" : "container:FamilyFoqos.xcodeproj",
        "identifier" : "801B20AF2CB363A20073E9E2",
        "name" : "FoqosUITests"
      }
    }
  ],
  "version" : 1
}
```
(Replace the configuration `id` with a real `uuidgen` value.)

Edit `FamilyFoqos.xctestplan`: delete the `FoqosUITests` entry from `testTargets` (keeps the 2–3 s unit loop pure).

`FoqosScreenshots.xcscheme`: copy `FamilyFoqos.xcscheme`, rename, and change the TestPlans block to reference `container:FoqosScreenshots.xctestplan`; also register both plans in the pbxproj if the existing plan registration pattern requires it (check how `FamilyFoqos.xctestplan` is referenced — it is container-relative in the scheme only, so no pbxproj change is expected).

- [ ] **Step 5: Verify both directions**

Run unit plan: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty` → green, and log shows NO FoqosUITests execution.
Run screenshots plan once directly: `xcodebuild test -project FamilyFoqos.xcodeproj -scheme FoqosScreenshots -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty` → 3 UI tests pass (screenshots land in test attachments; file output comes via snapshot in Task 11).

- [ ] **Step 6: Commit**

```bash
git add FoqosUITests/ FoqosScreenshots.xctestplan FamilyFoqos.xctestplan FamilyFoqos.xcodeproj/project.pbxproj FamilyFoqos.xcodeproj/xcshareddata/xcschemes/FoqosScreenshots.xcscheme
git commit -m "test: screenshot UI tests + dedicated FoqosScreenshots scheme/test plan"
```

---

### Task 11: Snapfile, `screenshots` lane, surgical sim cleanup, frameit

**Files:**
- Modify: `fastlane/Snapfile` (generated in Task 10 Step 1)
- Modify: `fastlane/Fastfile`
- Create: `fastlane/screenshots/Framefile.json`
- Create: `fastlane/screenshots/en-US/title.strings`

**Interfaces:**
- Consumes: `FoqosScreenshots` scheme (Task 10); snapshot names `01-…`/`02-…`/`03-…`.
- Produces: `lane :screenshots` → framed marketing images under `fastlane/screenshots/`.

- [ ] **Step 1: Snapfile**

```ruby
devices([
  "iPhone 17 Pro Max"  # 6.9" — the ASC-required size
])
# 6.5"-class (1242×2688) simulators no longer exist in current Xcode runtimes.
# ASC scales the 6.9" set for smaller devices; if a 6.5/6.7-compatible runtime is
# available at run time (e.g. an iPhone 13 Pro Max sim), add it here.

languages(["en-US"])  # align with the live listing after Task 12's metadata pull

scheme("FoqosScreenshots")
project("FamilyFoqos.xcodeproj")
output_directory("./fastlane/screenshots")
clear_previous_screenshots(true)
override_status_bar(true)
stop_after_first_error(true)
concurrent_simulators(false)  # shared machine: one sim at a time
reinstall_app(true)
```

- [ ] **Step 2: Add the screenshots lane with surgical cleanup**

```ruby
  XCTEST_DEVICES_DIR = File.expand_path("~/Library/Developer/XCTestDevices")

  desc "Regenerate all App Store screenshots (demo mode + snapshot + frameit)"
  lane :screenshots do
    before = Dir.exist?(XCTEST_DEVICES_DIR) ? Dir.children(XCTEST_DEVICES_DIR) : []
    begin
      snapshot
    ensure
      after = Dir.exist?(XCTEST_DEVICES_DIR) ? Dir.children(XCTEST_DEVICES_DIR) : []
      created = after - before
      created.each do |udid|
        # Delete ONLY simulators this run cloned. Never touch pre-existing entries
        # or the main simulator set — other projects use this machine.
        sh("xcrun simctl --set '#{XCTEST_DEVICES_DIR}' shutdown '#{udid}' || true", log: false)
        sh("xcrun simctl --set '#{XCTEST_DEVICES_DIR}' delete '#{udid}' || true", log: false)
        UI.message("Removed run-created test simulator #{udid}")
      end
    end
    # frameit needs a background image; it's gitignored (*.png), so generate it.
    bg = "fastlane/screenshots/background.png"
    sh("magick -size 1320x2868 xc:'#1a1a2e' '#{bg}'") unless File.exist?(bg)
    frameit(path: "./fastlane/screenshots")
  end
```

- [ ] **Step 3: Frameit config**

`fastlane/screenshots/Framefile.json`:
```json
{
  "device_frame_version": "latest",
  "default": {
    "background": "./background.png",
    "padding": 60,
    "show_complete_frame": true,
    "stack_title": false,
    "title": {
      "color": "#FFFFFF",
      "font_size": 96
    }
  }
}
```
`fastlane/screenshots/en-US/title.strings` (keys match snapshot filename substrings):
```
"01-home-active" = "Block distracting apps, on your terms";
"02-profile-editor" = "Pick the strategy that works for you";
"03-parent-dashboard" = "Manage the lock code from any parent device";
```
One-time dependency: `brew install imagemagick` (frameit requirement; add to the spec's one-time steps if missing).

- [ ] **Step 4: Run end-to-end**

Run: `bundle exec fastlane screenshots`
Expected: 3 framed 6.9" images in `fastlane/screenshots/en-US/`, no leftover run-created entries in `~/Library/Developer/XCTestDevices` (verify: `ls ~/Library/Developer/XCTestDevices` before/after — count unchanged), and pre-existing simulators untouched (`xcrun simctl list devices | head`). Visually inspect all three images.

- [ ] **Step 5: Commit**

```bash
git add fastlane/Snapfile fastlane/Fastfile fastlane/screenshots/Framefile.json fastlane/screenshots/en-US/title.strings
git commit -m "build: screenshots lane — snapshot, surgical sim cleanup, frameit captions"
```

---

### Task 12: Metadata under version control (deliver)

**Files:**
- Create: `fastlane/Deliverfile`
- Create: `fastlane/metadata/**` (seeded by deliver)

**Interfaces:**
- Consumes: `asc_api_key` (Task 2).
- Produces: repo-versioned listing text; `deliver` configured to never auto-submit outside the `release` lane.

- [ ] **Step 1: Deliverfile**

```ruby
app_identifier("com.cynexia.family-foqos")
submit_for_review(false)
automatic_release(false)
force(false)  # always show the HTML preview & require confirmation
precheck_include_in_app_purchases(false)
```

- [ ] **Step 2: Seed metadata from the live listing**

Add a small lane and run it (`bundle exec fastlane pull_metadata`):
```ruby
  desc "Pull current App Store metadata into fastlane/metadata"
  lane :pull_metadata do
    api_key = asc_api_key
    deliver(api_key: api_key, skip_binary_upload: true, skip_screenshots: true,
            download_metadata: true)
  end
```
(If the installed fastlane version rejects `download_metadata:` as a deliver param, use `bundle exec fastlane deliver download_metadata` directly — it reads the Appfile + `.env` key vars `APP_STORE_CONNECT_API_KEY_KEY_ID` etc.; set them in `.env` mirroring the ASC_ ones if needed.)
Expected: `fastlane/metadata/<locale>/…` populated with the live V1 listing text. Record the locale — update `Snapfile languages` and the `title.strings` directory name from Task 11 if it is not `en-US`.

- [ ] **Step 3: Commit (V1 copy is the correct baseline — V2 rewrite is a later, reviewable diff)**

```bash
git add fastlane/Deliverfile fastlane/metadata fastlane/Fastfile
git commit -m "build: deliver config + live listing metadata under version control"
```

---

### Task 13: `release` lane

**Files:**
- Modify: `fastlane/Fastfile`

**Interfaces:**
- Consumes: everything — `preflight`, `assert_no_release_blockers`, `asc_api_key`, gym config from Task 4, `store_archive`, metadata (Task 12), screenshots (Task 11).
- Produces: `lane :release` — the App Store submission command.

- [ ] **Step 1: Add the release lane**

```ruby
  desc "Build, upload metadata+screenshots+binary, and (after confirmation) submit for review"
  lane :release do
    preflight
    assert_no_release_blockers
    api_key = asc_api_key
    build = derived_build_number
    gym(
      project: XCODEPROJ,
      scheme: SCHEME,
      configuration: "Release",
      export_method: "app-store",
      xcargs: "CURRENT_PROJECT_VERSION=#{build} -allowProvisioningUpdates " \
              "-authenticationKeyPath #{File.expand_path(ENV.fetch('ASC_KEY_PATH'))} " \
              "-authenticationKeyID #{ENV.fetch('ASC_KEY_ID')} " \
              "-authenticationKeyIssuerID #{ENV.fetch('ASC_ISSUER_ID')}"
    )
    unless UI.confirm("Submit this build for App Store review?")
      UI.user_error!("Submission cancelled by user")
    end
    deliver(
      api_key: api_key,
      submit_for_review: true,
      automatic_release: false,
      screenshots_path: "./fastlane/screenshots",
      metadata_path: "./fastlane/metadata"
    )
    store_archive(prerelease: false)
  end
```

- [ ] **Step 2: Verify gate wiring (cannot run the lane end-to-end while blockers are open — that is the point)**

Run: `bundle exec fastlane release`
Expected: aborts at `assert_no_release_blockers` listing #345/#346 BEFORE any build starts. That failing run is this task's passing test. Full end-to-end happens at V2 launch when the blockers close.

- [ ] **Step 3: Commit**

```bash
git add fastlane/Fastfile
git commit -m "build: release lane — gated App Store submission"
```

---

## Verification summary (whole feature)

1. Unit suite green throughout; tripwire test enforces demo-mode containment forever.
2. `fastlane beta` shipped a real TestFlight build (Task 4 checkpoint).
3. `fastlane screenshots` produced three framed images and left other projects' simulators untouched.
4. `fastlane release` refuses to run while #345/#346 are open and while the production schema lacks the V2 record types — both gates observed firing against the real systems.
5. Archives exist in `~/Archives/family-foqos/` and as GitHub release assets for every uploaded build.

## Out of scope (per spec)

CI, widget/Live Activity screenshots, V1 branch, multi-locale, `match`, the actual #345/#346 work, CloudKit schema deployment itself.
