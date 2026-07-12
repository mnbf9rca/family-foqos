# Epic #263 tail (H, G, #331, J1, #240) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This plan is **self-contained** — it assumes no prior Claude session/project memory (the implementer may be Codex). Read `AGENTS.md` at the repo root first; it overrides everything here.

**Goal:** Ship the final five epic-#263 clean-up bundles as ONE branch / ONE PR (the "F+I bundle" pattern — five self-contained mini-plans, executed and reviewed in sequence, merged together):
- **Mini-plan H — logging & privacy** (`#252`, `#247`, `#250`): stop writing family-share participants' real names/emails to exportable logs (`#252`); stop leaking the physical-unblock NFC UID through Debug Mode in Child mode (`#247`); route all processes' logs to the shared app-group container so Export Logs actually includes extension logs (`#250`).
- **Mini-plan G — widget / Live Activity freshness** (`#238`, `#249`): reload the home-screen widget's timelines when the monitor extension starts/stops a scheduled session (`#238`); end-and-recreate the Live Activity on a profile switch so it stops showing the previous profile's name (`#249`).
- **Mini-plan #331 — parent dashboard honesty for old-version children** (`#331`): during the V1→V2 rollout a V2 parent with a V1 child sees two lies on `ParentDashboardView` — both reset commands report success at CKRecord-save time (a V1 child has no command reader, so it never applies), and Device Status shows "No Devices" for an actively-blocking V1 child (V1 never heartbeats). Make the reset UI honest ("Sent — waiting for child to confirm", flipping to confirmed only when the child deletes the command record on processing) and rewrite the empty Device-Status copy to acknowledge older app versions.
- **Mini-plan J1 — README corrections** (`#253`, `#254`): correct the minimum OS/toolchain and dead TODO links (`#253`); rewrite the removed-V1 "Blocking Strategies" section against the V2 trigger model (`#254`).
- **Mini-plan #240 — threat-model comment swap**: replace the apologetic PBKDF2/Argon2 TODO in `FamilyLockCode.swift` with the maintainer's ruled threat model (comment-only).

**Architecture:** Each mini-plan is a focused, TDD-first change on `main` at base commit `e7ac000`. The five are code-independent (different subsystems: logging/privacy, DeviceActivity/widgets/ActivityKit, parent-dashboard family UI + FamilyCommand CloudKit, docs, a single code comment). **This bundle implements LAST in the epic-#263 queue** — after `#302`/`#301`/`#298`, B2, and D3+E2 — so many citations in this document will have drifted by implementation time. **Every mini-plan opens with a mandatory Task 0 citation-refresh** that re-derives its citations by symbol against the then-current `main` and records the SHA it verified against. **Implementation order within the bundle: H → G → #331 → J1 + #240** (H, G, and #331 carry runtime surface and device-acceptance rows — #331 needs a V1-child + V2-parent pair — so they lead; the docs and the comment ride last). Commit each mini-plan's tasks under its own `(#N)` scope.

> **#331 was added by the 2026-07-12 refresh (ridden via PR #327).** It is the newest mini-plan — a V1→V2 upgrade-audit finding (PR #327, scenarios B3/B4) bundled into this tail per the maintainer's 2026-07-12 decision (no further V1 releases; all mixed-version remediation is V2-side). Because it landed after the plan's `e7ac000` base, its citations are grounded against the **then-current** `main` at refresh time — **`e6c3eb2`** ("Fix B2 family command and heartbeat plumbing (#325)"), i.e. **B2 / PR #325 is already merged**. Task 331.0 re-grounds every citation against whatever `git rev-parse HEAD` reports and reconciles with #325's command plumbing (see that task).

**Tech Stack:** Swift 6, SwiftUI, SwiftData (`cloudKitDatabase: .none`), CloudKit `CKSyncEngine`, `DeviceActivity` / `FamilyControls`, `ActivityKit`, `WidgetKit`, XCTest, Xcode 26. Test simulator: boot an iPhone 17 sim **ONCE** by UUID (see AGENTS.md — never by device name) and reuse it.

## Global Constraints

Every task's requirements implicitly include this section. Values copied verbatim from `AGENTS.md`.

- **Base commit `e7ac000`** (`main` tip: "A3′ sync conflict semantics (#306)"). This bundle implements **after** `#302`/`#301`/`#298`, B2, and D3+E2 merge, so re-verify every citation before writing code — each mini-plan's **Task 0** re-derives citations by symbol (fixed-string grep) and records the SHA it verified against. If a citation diverged, STOP and reconcile before writing code.
- **NEVER force-commit or amend.** New commits only; `git revert` to undo. **Request code review before merging** (AGENTS.md).
- **One implementation stream per machine.** Do not run parallel builds/tests. This is one bundle/PR.
- **`@SafeQuery`, never raw `@Query`** (pre-commit hook rejects `@Query`).
- **`swift-format` clean** (pre-commit auto-formats staged Swift). 2-space indent, ~100–120 col. `swift-format` does not touch `.md` (Mini-plan J1).
- **`Log` for all logging** (never `print`). Categories `.sync`/`.timer`/`.ui`/`.cloudKit`/`.strategy` etc. per AGENTS.md. **Never log lock codes or personal identifiers** (real names, emails); UUIDs, timestamps, and user-defined profile names are acceptable. (Mini-plan H1 enforces exactly this rule.)
- **No new SwiftData schema** in any mini-plan. Do not add `@Attribute`/`@Relationship`. New persisted UI state uses `@AppStorage` with the `family_foqos_` key prefix (Mini-plan G2).
- **Lock-check / mode rule:** gate child-only behaviour on `appModeManager.currentMode == .child`, **never** `!= .parent` (Mini-plan H2).
- **Standing threat model (calibrates H and #240):** friction, not DRM; the lock code is a **low-stakes secret, proportionately protected** (maintainer rulings on #240 (2026-07-10) and #203). No crypto/KDF/obfuscation/attempt-gating is in scope for this bundle.
- **Pin time in tests:** capture a single `let now = Date()` per test and derive all other dates from it; inject `now:` where the method under test accepts it.
- **Do not create GitHub labels** (repo rule; noted for parity).
- **PR wording:** the plan-only PR that INTRODUCED this document was titled **"plans the fix for #238, #249, #252, #247, #250, #253, #254, #240"**, never "fixes"; the 2026-07-12 refresh that ADDS Mini-plan #331 rides **PR #327** and its title likewise says **"plans"**, not "fixes" (it adds `#331` to the covered set). When each mini-plan is later IMPLEMENTED, its commits use conventional-commit types scoped to the issue (`fix(#N)`/`feat(#N)`/`test(#N)`/`refactor(#N)`/`docs(#N)`).

---
## Mini-plan H — logging & privacy (#252, #247, #250)

> **Tail-bundle position.** This mini-plan implements **last** in the tail bundle (order H → G → #331 → J1+#240), on `main` at base commit `e7ac000`, **after** #302/#301/#298, B2, and D3+E2 have merged. None of those bundles is known to touch the four files H edits (`CloudKitNetworkService+FamilyMembers.swift`, `ProfileDebugCard.swift`, `DebugView.swift`, `Packages/FoqosShared/Sources/FoqosShared/Log.swift`), but citations **may still drift** — each sub-part opens with a mandatory Task 0 that re-derives every citation **by symbol** (fixed-string grep) and records the SHA it verified against. All line numbers below were verified against `e7ac000`; where a Task-0 grep reports a shifted line, use the fresh number.

H is three **code-independent** privacy/logging fixes. Implement them in order H1 → H2 → H3 (H3 is the heaviest), each a self-contained TDD change with its own `(#N)` commit scope. They share no types and can be reviewed independently.

**Global constraints that bind every task here** (from `AGENTS.md`): NEVER force-commit/amend — new commits only; request review before merge. `swift-format` clean, 2-space indent, ~100–120 col. Use `Log`, never `print`. **Never log personal identifiers** (real names, emails); UUIDs, `userRecordName` (opaque CK record ids), timestamps, and user-defined profile names are acceptable — this is the exact rule H1/H2 enforce. Lock-check gate is `currentMode == .child`, never `!= .parent` (H2 mirrors this). Pin time in tests (single `let now = Date()`). Test simulator: boot an iPhone 17 **once by UUID** (never by device name) and reuse it; command form:
```
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/<Class> | xcpretty
```

---

### H1 · #252 — personal identifiers (real names / emails) written to exportable logs

#### Problem (device-observed)

Family-member management logs the member's **real display name** (e.g. "Emma", "Dad") and, on participant removal, the member's **name or email address** at `.info` level. Because `fileLoggingEnabled == true` (`Log.swift:104`), these lines are persisted to the on-device log file and travel out through **Export Logs** (Home version footer → Debug Mode → Export Logs; Settings → Diagnostics → Debug Mode → Export Logs). A user who exports and shares their logs for support therefore leaks their children's/family members' real names and email addresses — a direct violation of the `AGENTS.md` privacy rule ("Never log … personal identifiers"). Four log sites in `Foqos/CloudKit/CloudKitNetworkService+FamilyMembers.swift` are affected.

#### Grounding (verified at `e7ac000`)

Four PII-leaking log sites in `Foqos/CloudKit/CloudKitNetworkService+FamilyMembers.swift`:

```swift
:9-11   Log.info(
          "Saving family member '\(member.displayName)' as \(member.role.displayName)",
          category: .cloudKit)
:20     Log.info("Saved family member: \(member.displayName)", category: .cloudKit)
:36     Log.info("Deleted family member: \(member.displayName)", category: .cloudKit)
:61-64  let name =
          participant.userIdentity.nameComponents?.formatted()
          ?? participant.userIdentity.lookupInfo?.emailAddress ?? "Unknown"
        Log.info("Removed participant '\(name)' from share", category: .cloudKit)
```

`member.displayName` **is a real person name** — `Foqos/Models/FamilyMember.swift:43`:
```swift
var displayName: String  // Name (e.g., "Emma", "Dad")
```
`member.role.displayName` (`FamilyMember.swift:11-18`, the `FamilyRole.displayName` computed property) returns only `"Parent"`/`"Child"` — **not PII; keep it.**

The **correct pattern already exists** in the same file — `revokeShareAccess` (`:97`) logs only the opaque CK record name:
```swift
:97  Log.info("Revoked share access for \(userRecordName)", category: .cloudKit)
```
`userRecordName` is a `CKRecord.ID.recordName` (opaque id, AGENTS-permitted), not PII. `revokeShareAccess` is **not part of this fix** — it is the reference. `removeShareParticipant`'s `participant` has **no `FamilyMember.id`**, but it does carry `participant.userIdentity.userRecordID?.recordName` — the same stable opaque id `revokeShareAccess` matches on at `:92`.

`FamilyMember` (`FamilyMember.swift:40-64`) is a `struct` with `var id: UUID` (`:41`), `var userRecordName: String` (`:42`), `var displayName: String` (`:43`), `var role: FamilyRole` (`:44`). Its memberwise-style `init` (`:48-62`) is `init(id: UUID = UUID(), userRecordName:, displayName:, role:, enrolledAt: Date = Date(), isActive: Bool = true)` — the shape the H1 test constructs. The four methods live in `extension CloudKitNetworkService`. Nearest existing test file for structure reference: `FoqosTests/FamilyCommandSaveOutcomeTests.swift`.

#### MAINTAINER DECISIONS

**None.** The proportionate fix is fully determined by the `AGENTS.md` rule: replace the PII interpolation with an allowed non-PII identifier (`member.id.uuidString` for `FamilyMember`; `participant.userIdentity.userRecordID?.recordName` for the participant, matching the already-shipped `revokeShareAccess` precedent). `member.role.displayName` stays (it is not PII). No maintainer fork exists — this is a straight conformance fix to an existing, ruled-on privacy invariant.

#### Task H1-0: Citation refresh (MANDATORY — do this first, no code)

- [ ] **Step 1: Record the base SHA.** `git rev-parse HEAD` — confirm `e7ac000` (or note the newer tail-bundle SHA and re-grep everything below against it).
- [ ] **Step 2: Confirm the four PII log sites by symbol:**
```bash
grep -nF -e "Saving family member '\(member.displayName)'" \
  -e 'Saved family member: \(member.displayName)' \
  -e 'Deleted family member: \(member.displayName)' \
  -e 'Removed participant' \
  Foqos/CloudKit/CloudKitNetworkService+FamilyMembers.swift
grep -nF -e 'nameComponents?.formatted()' -e 'lookupInfo?.emailAddress' \
  Foqos/CloudKit/CloudKitNetworkService+FamilyMembers.swift
```
Expected: the three `member.displayName` interpolations (`~:9-11`, `:20`, `:36`) and the `name = …nameComponents…emailAddress…` build + `Removed participant '\(name)'` log (`~:61-64`).
- [ ] **Step 3: Confirm the reference pattern (NOT edited) and the participant id accessor:**
```bash
grep -nF -e 'Revoked share access for \(userRecordName)' \
  -e 'userIdentity.userRecordID?.recordName == userRecordName' \
  Foqos/CloudKit/CloudKitNetworkService+FamilyMembers.swift
```
Expected: `:97` (reference log) and `:92` (the participant-id accessor to mirror).
- [ ] **Step 4: Confirm `FamilyMember` shape** for the helper and the test init: `grep -nF -e 'var id: UUID' -e 'var displayName: String' -e 'var userRecordName: String' -e 'var role: FamilyRole' Foqos/Models/FamilyMember.swift` (expect `:41`, `:43`, `:42`, `:44`). Record the fresh line numbers before editing.

#### Task H1-1: Add a PII-safe member log label and redact the four sites

**Files:**
- Modify: `Foqos/Models/FamilyMember.swift` (add the pure `redactedLogLabel` helper)
- Modify: `Foqos/CloudKit/CloudKitNetworkService+FamilyMembers.swift` (four sites)
- Test: **create** `FoqosTests/FamilyMemberLogRedactionTests.swift`

**Interfaces:**
- Produces: `FamilyMember.redactedLogLabel: String` → `id.uuidString` (satisfies the requested "PII-safe member label" helper as an instance computed property; internal access, visible to tests via `@testable import`; testable with no CloudKit).

- [ ] **Step 1: Write the failing test** (create `FoqosTests/FamilyMemberLogRedactionTests.swift`):
```swift
import XCTest

@testable import FamilyFoqos

final class FamilyMemberLogRedactionTests: XCTestCase {
  // #252: the log label must be the (non-PII) UUID, never the real display name.
  func testGivenMember_WhenRedactedLogLabel_ThenIsUUIDAndContainsNoName() {
    let id = UUID()
    let member = FamilyMember(
      id: id, userRecordName: "urn_abc", displayName: "Emma", role: .child)
    XCTAssertEqual(member.redactedLogLabel, id.uuidString)
    XCTAssertFalse(member.redactedLogLabel.contains("Emma"), "must not leak displayName")
  }
}
```
- [ ] **Step 2: Run → FAIL** (`-only-testing:FoqosTests/FamilyMemberLogRedactionTests`): `value of type 'FamilyMember' has no member 'redactedLogLabel'`.
- [ ] **Step 3: Add the helper** to `Foqos/Models/FamilyMember.swift` as a new extension (or fold into an existing `extension FamilyMember` — either compiles):
```swift
extension FamilyMember {
  /// PII-SAFE LOG (#252): the ONLY value permitted in log lines that reference a family member.
  /// Returns the non-PII UUID — never `displayName` (a real person name) or any email. Greppable
  /// marker `PII-SAFE LOG` lets privacy audits catch regressions that reintroduce name/email logging.
  var redactedLogLabel: String { id.uuidString }
}
```
- [ ] **Step 4: Redact the four sites** in `Foqos/CloudKit/CloudKitNetworkService+FamilyMembers.swift`.

  a. `:9-11` — keep the (non-PII) role, drop the name:
```swift
    // PII-SAFE LOG (#252): log the UUID + role, never member.displayName.
    Log.info(
      "Saving family member \(member.redactedLogLabel) as \(member.role.displayName)",
      category: .cloudKit)
```
  b. `:20`:
```swift
      Log.info("Saved family member: \(member.redactedLogLabel)", category: .cloudKit)
```
  c. `:36`:
```swift
      Log.info("Deleted family member: \(member.redactedLogLabel)", category: .cloudKit)
```
  d. `:61-64` — the participant has no `FamilyMember.id`; log the opaque CK record name exactly as `revokeShareAccess:97` does, and **delete** the `name = …nameComponents…emailAddress…` build:
```swift
    let participantId = participant.userIdentity.userRecordID?.recordName ?? "unknown"
    // PII-SAFE LOG (#252): log only the opaque CK record name, never nameComponents/email.
    Log.info("Removed participant \(participantId) from share", category: .cloudKit)
```
- [ ] **Step 5: Run the test + build the target** (edits touch a non-UI service — a compile is the second check):
```
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/FamilyMemberLogRedactionTests | xcpretty
```
Then confirm **no PII interpolation remains** (note: the fixed string `member.displayName` does NOT match the retained, non-PII `member.role.displayName`, so this grep is a clean tripwire):
```bash
grep -nF -e 'member.displayName' -e 'nameComponents?.formatted()' -e 'lookupInfo?.emailAddress' \
  Foqos/CloudKit/CloudKitNetworkService+FamilyMembers.swift
```
Expected: PASS, and the grep returns **nothing**.
- [ ] **Step 6: Commit**
```bash
git add Foqos/Models/FamilyMember.swift \
        Foqos/CloudKit/CloudKitNetworkService+FamilyMembers.swift FoqosTests/
git commit -m "fix(#252): redact family-member names/emails from exportable logs (PII-safe labels)"
```

---

### H2 · #247 — Debug Mode in child mode leaks the physical-unblock NFC UID

#### Problem (device-observed)

On a **child** device, the parent-set physical-unblock **NFC tag UID is the live credential** that unlocks a blocked profile (`NFCTimerBlockingStrategy.swift:68-69` compares the scanned tag id against `session.blockedProfile.physicalUnblockNFCTagId` — a raw string inequality gate; whoever knows the UID can craft/clone a tag and defeat the block). Yet Debug Mode is reachable on the child's own device with **no mode gate**, and it both **displays** that UID on screen (`ProfileDebugCard.swift:55`) and **copies it into the exported markdown** (`DebugView.swift:181-183`). A child opening Debug Mode reads the exact answer key to their own restriction. (The QR value is a SHA-256 digest — less sensitive — but Option A redacts it too for consistency.)

#### Grounding (verified at `e7ac000`)

On-screen leak — `Foqos/Components/Debug/ProfileDebugCard.swift:55-56`:
```swift
:55  DebugRow(label: "NFC Tag ID", value: profile.physicalUnblockNFCTagId ?? "nil")
:56  DebugRow(label: "QR Code ID", value: profile.physicalUnblockQRCodeId ?? "nil")
```
`ProfileDebugCard` is `struct ProfileDebugCard: View { let profile: BlockedProfiles }` (`:4-5`) — **no mode access.**

Export leak — `Foqos/Views/DebugView.swift`, inside `private func copyToMarkdown()` (declared `:147`, invoked from a `Button(action:)` at `:120`):
```swift
:181-183  if let nfcTagId = profile.physicalUnblockNFCTagId {
            markdown += "- **Physical Unlock NFC Tag ID:** \(nfcTagId)\n"
          }
:185-187  if let qrCodeId = profile.physicalUnblockQRCodeId {
            markdown += "- **Physical Unlock QR Code ID:** \(qrCodeId)\n"
          }
```
`DebugView` has **no `appModeManager` property** (`:6-14` — only `modelContext`, `dismiss`, `strategyManager`, and three `@State`).

Ungated entry points (no mode/lock check anywhere on the path):
- `HomeView.swift:47` `@State showingDebugMode`; `:235` sets `showingDebugMode = true` from the `VersionFooter` tap; `:349-350` `.sheet(isPresented: $showingDebugMode) { DebugView() }`. (`VersionFooter` gates its tap on `profileIsActive`, not mode.)
- `SettingsView.swift:22` `@State showDebugView`; Diagnostics `Section` Button (`~:328`) → `showDebugView = true` (`:329`); `:432-433` `.sheet(isPresented: $showDebugView) { DebugView() }`.

The credential gate — `Foqos/Models/Strategies/NFCTimerBlockingStrategy.swift:68-69`:
```swift
if let physicalUnblockNFCTagId = session.blockedProfile.physicalUnblockNFCTagId,
  physicalUnblockNFCTagId != tag
```

Mode manager already in scope at both entry hosts: `HomeView.swift:67` and `SettingsView.swift:14` both hold `@ObservedObject … AppModeManager.shared`. `AppMode` (`Foqos/Models/AppMode.swift:4-12`) has cases `individual`/`parent`/`child`; `AppModeManager` is `@MainActor` (`AppMode.swift:49-51`). Child-gate pattern to mirror (`== .child`, never `!= .parent`): `LockCodeManager` (`Foqos/Utils/LockCodeManager.swift:244`, `:368` — `mode == .child`) and `SavedLocation.requiresLockCodeToModify` (`Foqos/Models/SavedLocation.swift:117` — `isLocked && mode == .child && canVerifyCode`); see their tests `FoqosTests/LockCodeEditGateTests.swift`, `FoqosTests/SavedLocationLockGateTests.swift`.

#### MAINTAINER DECISION — MD-H2 (ESCALATE; recommend Option A)

The physical-unblock UID is the exact credential the child would need to defeat the block, and it is being shown to the child. This is a genuine product-proportionality fork not settled by any existing invariant, so it is escalated:

- **Option A (RECOMMENDED): redact only the sensitive fields (`physicalUnblockNFCTagId` + `physicalUnblockQRCodeId`) in child mode**, both on-screen and in the export. Surgical; keeps Debug Mode fully usable for legitimate support/diagnostics on a child device (device activities, schedule, session state) while blanking only the credential the child must not learn.
- **Option B: hide the entire Debug entry in child mode.** Broader friction — removes all diagnostics from the child device to suppress one leaked field.

**Recommendation: A.** The credential is the specific answer key; blanking exactly that field is the minimal, proportionate response and preserves diagnostics. **This is friction-consistency (a low-stakes secret proportionately hidden), NOT crypto** — no KDF/obfuscation/attempt-gating is proposed; the raw string simply isn't shown when `currentMode == .child`. **Maintainer, please confirm A vs B.** The tasks below implement **A** and are the default that proceeds; if the maintainer picks B, replace Task H2-2 with a `currentMode == .child`-gated `if` around the two `.sheet { DebugView() }` presentations at `HomeView.swift:349` and `SettingsView.swift:432` and drop H2-1/H2-2's field-level redaction.

#### Task H2-0: Citation refresh (MANDATORY — no code)

- [ ] **Step 1: Record base SHA** (`git rev-parse HEAD`, expect `e7ac000`).
- [ ] **Step 2: Confirm the two leak sites by symbol:**
```bash
grep -nF -e 'DebugRow(label: "NFC Tag ID"' -e 'DebugRow(label: "QR Code ID"' \
  Foqos/Components/Debug/ProfileDebugCard.swift
grep -nF -e 'Physical Unlock NFC Tag ID' -e 'Physical Unlock QR Code ID' \
  -e 'profile.physicalUnblockNFCTagId' -e 'profile.physicalUnblockQRCodeId' \
  Foqos/Views/DebugView.swift
```
Expected: `ProfileDebugCard.swift:55/56`; `DebugView.swift:181-187`.
- [ ] **Step 3: Confirm the `== .child` gate precedent + AppMode cases** so H2-1 mirrors it:
```bash
grep -nF -e 'case individual' -e 'case parent' -e 'case child' Foqos/Models/AppMode.swift
grep -rnF 'mode == .child' Foqos/Utils/LockCodeManager.swift Foqos/Models/SavedLocation.swift
```
- [ ] **Step 4: Confirm mode manager scope at the hosts** (not edited, but verifies the credential surface stays reachable for support in parent/individual): `grep -nF 'AppModeManager.shared' Foqos/Views/HomeView.swift Foqos/Views/SettingsView.swift`. Record fresh line numbers.

#### Task H2-1: Add a pure child-mode redaction helper (testable)

**Files:**
- Create: `Foqos/Components/Debug/DebugRedaction.swift`
- Test: **create** `FoqosTests/DebugRedactionTests.swift`

**Interfaces:**
- Produces: `DebugRedaction.redactedInChildMode(_ raw: String?, mode: AppMode) -> String?` — returns the placeholder in `.child`, the raw value otherwise, `nil` when `raw == nil`. Consumed by both `ProfileDebugCard` and `DebugView.copyToMarkdown` (Task H2-2).

- [ ] **Step 1: Write the failing tests** (create `FoqosTests/DebugRedactionTests.swift`, mirroring `LockCodeEditGateTests` structure):
```swift
import XCTest

@testable import FamilyFoqos

final class DebugRedactionTests: XCTestCase {
  private let secret = "ABC123DEF456"

  // Child mode: the live credential is hidden.
  func testGivenNFCId_WhenChildMode_ThenRedacted() {
    XCTAssertEqual(
      DebugRedaction.redactedInChildMode(secret, mode: .child),
      DebugRedaction.childRedactionPlaceholder)
  }

  // Parent mode: full value (support/diagnostics keep working).
  func testGivenNFCId_WhenParentMode_ThenRaw() {
    XCTAssertEqual(DebugRedaction.redactedInChildMode(secret, mode: .parent), secret)
  }

  // AGENTS.md invariant: gate on `== .child`, NOT `!= .parent` — Individual must NOT be redacted.
  func testGivenNFCId_WhenIndividualMode_ThenRaw() {
    XCTAssertEqual(DebugRedaction.redactedInChildMode(secret, mode: .individual), secret)
  }

  // Nothing to hide when the field is absent.
  func testGivenNilId_WhenChildMode_ThenNil() {
    XCTAssertNil(DebugRedaction.redactedInChildMode(nil, mode: .child))
  }
}
```
- [ ] **Step 2: Run → FAIL** (`-only-testing:FoqosTests/DebugRedactionTests`): `cannot find 'DebugRedaction' in scope`.
- [ ] **Step 3: Implement** (create `Foqos/Components/Debug/DebugRedaction.swift`):
```swift
import Foundation

/// #247: field-level redaction for Debug Mode. The physical-unblock NFC UID (and QR digest) is
/// the live credential that defeats a block on a child device, and Debug Mode is reachable on the
/// child's own device — so these fields are blanked when `mode == .child`. Friction-consistent, not
/// crypto: the raw string is simply withheld from the child; parent/individual devices are unchanged.
enum DebugRedaction {
  static let childRedactionPlaceholder = "•••• (hidden in Child mode)"

  /// Returns the placeholder for a present value in Child mode, the raw value in any other mode,
  /// and `nil` when there is nothing to show. Gate is `== .child` (AGENTS.md), never `!= .parent`.
  static func redactedInChildMode(_ raw: String?, mode: AppMode) -> String? {
    guard let raw else { return nil }
    return mode == .child ? childRedactionPlaceholder : raw
  }
}
```
- [ ] **Step 4: Run → PASS** (`-only-testing:FoqosTests/DebugRedactionTests`).
- [ ] **Step 5: Commit**
```bash
git add Foqos/Components/Debug/DebugRedaction.swift FoqosTests/
git commit -m "feat(#247): pure child-mode Debug redaction helper (NFC/QR credential)"
```

#### Task H2-2: Apply redaction in both Debug surfaces

**Files:**
- Modify: `Foqos/Components/Debug/ProfileDebugCard.swift` (`:55-56`)
- Modify: `Foqos/Views/DebugView.swift` (`copyToMarkdown` `:181-187`)

**Interfaces:**
- Consumes: `DebugRedaction.redactedInChildMode(_:mode:)` (Task H2-1) and `AppModeManager.shared.currentMode`.

> Both surfaces are SwiftUI presentation (not unit-testable directly). The **decision** lives in the pure helper (tested in H2-1); these steps are exact wiring, verified by compile + the H2-3 device/inspection gate. **Concurrency note:** reading the `@MainActor` `AppModeManager.shared.currentMode` is already permitted in both contexts. `ProfileDebugCard.body` is `@MainActor` (`View.body`). `DebugView.copyToMarkdown` **already reads main-actor-isolated state today** — it accesses `strategyManager.activeSession` / `activeProfile` at `:148-149`, where `StrategyManager` is `@MainActor` — so the method's existing isolation context accepts the identical-kind `AppModeManager.shared.currentMode` access with no new annotation. (If a future refactor makes the build complain, thread the mode in as a parameter; not needed at `e7ac000`.)

- [ ] **Step 1: `ProfileDebugCard.swift`** — redact both credential rows (`:55-56`):
```swift
        DebugRow(
          label: "NFC Tag ID",
          value: DebugRedaction.redactedInChildMode(
            profile.physicalUnblockNFCTagId, mode: AppModeManager.shared.currentMode) ?? "nil")
        DebugRow(
          label: "QR Code ID",
          value: DebugRedaction.redactedInChildMode(
            profile.physicalUnblockQRCodeId, mode: AppModeManager.shared.currentMode) ?? "nil")
```
- [ ] **Step 2: `DebugView.swift`** — redact both export lines (`:181-187`). The `if let` now binds the **redacted** value, so in child mode the markdown shows the placeholder instead of the raw credential (the field label is retained for support context):
```swift
    if let nfcTagId = DebugRedaction.redactedInChildMode(
      profile.physicalUnblockNFCTagId, mode: AppModeManager.shared.currentMode) {
      markdown += "- **Physical Unlock NFC Tag ID:** \(nfcTagId)\n"
    }

    if let qrCodeId = DebugRedaction.redactedInChildMode(
      profile.physicalUnblockQRCodeId, mode: AppModeManager.shared.currentMode) {
      markdown += "- **Physical Unlock QR Code ID:** \(qrCodeId)\n"
    }
```
- [ ] **Step 3: Build** (view edits, no direct unit test):
```
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug -destination 'generic/platform=iOS Simulator' build | xcpretty
```
Expected: `BUILD SUCCEEDED`. Then confirm **no raw credential reaches either surface unredacted**:
```bash
grep -nF -e 'profile.physicalUnblockNFCTagId ?? "nil"' Foqos/Components/Debug/ProfileDebugCard.swift
grep -nF -e 'markdown += "- **Physical Unlock NFC Tag ID:** \(nfcTagId)' Foqos/Views/DebugView.swift
```
The first grep must return **nothing** (the raw on-screen row is gone — the `?? "nil"` now binds to the `redactedInChildMode(...)` call, not to `profile.physicalUnblockNFCTagId` directly). The second still matches, but `nfcTagId` is now the redacted binding — confirm by reading the surrounding `if let`.
- [ ] **Step 4: Commit**
```bash
git add Foqos/Components/Debug/ProfileDebugCard.swift Foqos/Views/DebugView.swift
git commit -m "fix(#247): redact physical-unblock NFC/QR credential in Debug Mode on child devices"
```

#### Task H2-3: Device / inspection acceptance (gate before merge)

- [ ] **DEVICE GATE (required, no debugger):** on a **child** device with a profile that has a physical-unblock NFC tag set, open Debug Mode via **both** entry points (Home version footer while a profile is active; Settings → Diagnostics). Confirm the "NFC Tag ID" and "QR Code ID" rows show `•••• (hidden in Child mode)`, and that **Copy as Markdown → paste** contains the placeholder, not the raw UID. Then switch the device to **parent** (or test on a parent/individual device) and confirm the raw values reappear (support path intact). Attach the redacted exported markdown to the PR (verify no raw UID string is present).

---

### H3 · #250 — extension logs never included in Export Logs (app-group log dir)

#### Problem (device-observed)

The DeviceActivity monitor extension (`FoqosDeviceMonitor`), the widget (`FoqosWidget`), and the shield-config extension all persist logs through the same `Log` singleton (`Log.shared`, per-process). But `logDirectory` is rooted at `.applicationSupportDirectory` — a **per-process sandbox** — and every process writes the **same basename `foqos.log`** into its *own* sandbox. Consequences:
1. **Export Logs (main app) never sees extension logs.** `copyLogFilesToStagingDirectory` enumerates only the main app's sandbox, so a support bundle silently omits the extension logs that explain schedule/monitoring failures — the exact diagnostics the export exists to capture.
2. If the directory *were* shared as-is, every process writing `foqos.log` would **collide** — concurrent appends plus `moveItem` rotations on one shared file, no coordination.

The fix roots the log directory in the **shared app-group container** (entitled to every process) and gives each process a **distinct basename**, so processes never contend on a file, and export enumerates *all* of them.

#### Grounding (verified at `e7ac000`)

`Packages/FoqosShared/Sources/FoqosShared/Log.swift`:
- `:106-118` `logDirectory` uses `.applicationSupportDirectory` (per-process sandbox).
- `:120-122` `currentLogFile` = `foqos.log` (identical in every process).
- `:284-301` `_getLogFileURLsUnsafe()` + `:303-306` `getLogFileURLs()` hardcode `foqos.log` + `foqos.\(i).log` (single-process enumeration).
- `:313-322` `copyLogFilesToStagingDirectory`; dest naming (`:317`) assumes ONE process — `index == 0 ? "foqos-current.log" : "foqos-\(index).log"` — so two processes' current files would **collide** on `foqos-current.log`.
- `:250-269` `rotateLogFiles` moves `foqos.\(i).log`; `:223-248` `writeToFile` opens a **fresh** `FileHandle(forWritingTo:)` per call and closes it (`:239-242`) — **no long-lived handle held across writes**; `:374-388` `clearLogs` removes every `pathExtension == "log"` in `logDirectory`; `:391-406` `getTotalLogSize`; `:341-371` `getLogContentTail`; `:325-338` `getLogContent`.
- `Log.shared` is a per-process singleton with its own serial `queue` (`:91`); `fileLoggingEnabled = true` (`:104`); no `flock`. `Log` is `public final class Log: @unchecked Sendable` (`:88`).

Export callers: `Foqos/Utils/LogExportManager.swift:42` (`copyLogFilesToStagingDirectory`), `:85` (`getLogFileURLs().count` → "File Count"); `Foqos/Views/LogExportView.swift:132` (`getLogFileURLs()`).

App-group `group.com.cynexia.family-foqos` is entitled to the main app (`Foqos/foqos.entitlements:27`) **and** the monitor (`FoqosDeviceMonitor/FoqosDeviceMonitor.entitlements:9`); the widget/shield targets share it too. The reusable container accessor pattern already exists — `SharedData.swift:37-38` — but it is a **`private static let`**, so `Log` must call `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` itself:
```swift
private static let containerURL: URL? = FileManager.default.containerURL(  // SAFETY: same app group as `suite`
  forSecurityApplicationGroupIdentifier: "group.com.cynexia.family-foqos")
```
`SharedData`'s DEBUG override pattern (`configureLockPath` `:46`/`resetLockPath` `:52`) is the precedent for a test seam, if one is wanted (not required here — see MD note below).

Per-process bundle identifiers (from `FamilyFoqos.xcodeproj/project.pbxproj`, confirmed): main `com.cynexia.family-foqos`; monitor `…FoqosDeviceMonitor`; widget `…FoqosWidget`; shield `…FoqosShieldConfig`. **In an app extension, `Bundle.main.bundleIdentifier` returns the extension's own bundle id** (not the host app), so the per-process tag resolves correctly in each process.

Test target: `FoqosTests/LogTailTests.swift` exercises `getLogFileURLs` (`:69`, `:104`) and `copyLogFilesToStagingDirectory` (`:107`). **These tests assert on logged *markers* and file *counts*, never on hard-coded filenames** (verified: no `"foqos.log"`/`"foqos-current.log"` literal appears in the test), so the rename below does not break them. There is **no SPM test target** under `Packages/FoqosShared`, so all tests live in `FoqosTests` (`@testable import FamilyFoqos`; `Log`'s `public` symbols are visible through the app's import of `FoqosShared`).

#### MAINTAINER DECISIONS

**No genuine maintainer fork — the design is determined by the entitlement + the collision constraint.** Three design points, all prescribed (not escalated):

- **Test seam.** The multi-file enumeration and staging-name logic are extracted into **pure static helpers** (`allLogFileURLs(inDirectory:using:)`, `stagingDestinationName(for:)`, `logBaseName(forBundleIdentifier:)`) that take an explicit directory / bundle id and are unit-tested against a temp directory — **no singleton override needed**. This is lighter than `SharedData`'s DEBUG-override seam and is the seam the prompt asks for. (A DEBUG `configureLogDirectory` override on the instance is intentionally **not** added — the pure helpers cover the deterministic tests, and the existing `LogTailTests` keep running against whatever directory the host resolves.)
- **Cross-process locking.** Giving each process a **distinct basename** structurally eliminates the shared-file append/rotation race (no two processes ever touch the same file), so **no `flock`/`NSFileCoordinator` is added for writes** — that is the whole point of the per-process naming, and adding locks would be over-engineering. `writeToFile` opens a **fresh** handle per call (`:239`), so a file deleted by `clearLogs` between writes is simply recreated on the next write — no stale-handle corruption. **One cross-process *read* path needs care (Skeptic Pass finding H-1):** `copyLogFilesToStagingDirectory` now enumerates every process's files, so a sibling can rotate/remove its own file between enumeration and copy — resolved by the **best-effort per-file copy** in Task H3-2 Step 5 (skip a vanished source, never abort the whole export). A **torn last line** on a file being concurrently appended is an **accepted best-effort residual** (a diagnostics snapshot, not a transaction) — the read helpers already `try?`-skip unreadable files (`getLogContent:331`, `getLogContentTail:352`, `getTotalLogSize:397`).
- **Legacy `foqos.log` orphaning.** Moving to the container abandons any pre-existing `.applicationSupportDirectory/Logs/foqos.log`. Per project memory (**no live users — pre-release**), a one-time orphaning is acceptable; **no migration is written** (listed in Out-of-scope). If the maintainer wants the old file swept in, that is a separate follow-up.

#### Task H3-0: Citation refresh (MANDATORY — no code)

- [ ] **Step 1: Record base SHA** (`git rev-parse HEAD`, expect `e7ac000`).
- [ ] **Step 2: Confirm every `Log.swift` symbol this task rewrites:**
```bash
grep -nF -e 'private var logDirectory' -e 'applicationSupportDirectory' \
  -e 'private var currentLogFile' -e '"foqos.log"' \
  -e 'func _getLogFileURLsUnsafe' -e 'func getLogFileURLs' \
  -e 'func copyLogFilesToStagingDirectory' -e 'foqos-current.log' \
  -e 'private func rotateLogFiles' -e 'private func writeToFile' \
  -e 'func clearLogs' -e 'func getTotalLogSize' \
  Packages/FoqosShared/Sources/FoqosShared/Log.swift
```
Record the fresh line numbers.
- [ ] **Step 3: Confirm the app-group id is entitled to both processes and the container accessor precedent:**
```bash
grep -nF 'group.com.cynexia.family-foqos' Foqos/foqos.entitlements \
  FoqosDeviceMonitor/FoqosDeviceMonitor.entitlements
grep -nF 'containerURL(' Packages/FoqosShared/Sources/FoqosShared/SharedData.swift
```
- [ ] **Step 4: Confirm the four product bundle identifiers** (so `logBaseName` maps every real process):
```bash
grep -nF 'PRODUCT_BUNDLE_IDENTIFIER = "com.cynexia.family-foqos' FamilyFoqos.xcodeproj/project.pbxproj | sort -u
```
Expected: `com.cynexia.family-foqos`, `…FoqosDeviceMonitor`, `…FoqosWidget`, `…FoqosShieldConfig`.
- [ ] **Step 5: Confirm export callers unchanged by symbol** (they call `getLogFileURLs`/`copyLogFilesToStagingDirectory` — widening those functions fixes them with no caller edit): `grep -nF -e 'copyLogFilesToStagingDirectory' -e 'getLogFileURLs()' Foqos/Utils/LogExportManager.swift Foqos/Views/LogExportView.swift`.

#### Task H3-1: Pure helpers — per-process basename, multi-file enumeration, collision-free staging name

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/Log.swift` (add three `public static` helpers)
- Test: **create** `FoqosTests/LogFileEnumerationTests.swift`

**Interfaces:**
- Produces (all `public static` on `Log`):
  - `logBaseName(forBundleIdentifier: String?) -> String` → per-process tag (`"app"`/`"monitor"`/`"widget"`/`"shield"`, sanitized fallback otherwise).
  - `allLogFileURLs(inDirectory: URL, using: FileManager) -> [URL]` → every `foqos-*.log` in the dir, newest-first, deterministic tie-break.
  - `stagingDestinationName(for: URL) -> String` → the file's own basename (collision-free).
- Consumed by the instance methods in Task H3-2.

- [ ] **Step 1: Write the failing tests** (create `FoqosTests/LogFileEnumerationTests.swift`). These are fully deterministic — pure functions over a temp directory, no singleton, no real container:
```swift
import XCTest

@testable import FamilyFoqos

final class LogFileEnumerationTests: XCTestCase {

  // --- per-process basename ---

  func testGivenMainAppBundleId_WhenLogBaseName_ThenApp() {
    XCTAssertEqual(Log.logBaseName(forBundleIdentifier: "com.cynexia.family-foqos"), "app")
  }

  func testGivenMonitorBundleId_WhenLogBaseName_ThenMonitor() {
    XCTAssertEqual(
      Log.logBaseName(forBundleIdentifier: "com.cynexia.family-foqos.FoqosDeviceMonitor"),
      "monitor")
  }

  func testGivenWidgetBundleId_WhenLogBaseName_ThenWidget() {
    XCTAssertEqual(
      Log.logBaseName(forBundleIdentifier: "com.cynexia.family-foqos.FoqosWidget"), "widget")
  }

  func testGivenShieldBundleId_WhenLogBaseName_ThenShield() {
    XCTAssertEqual(
      Log.logBaseName(forBundleIdentifier: "com.cynexia.family-foqos.FoqosShieldConfig"),
      "shield")
  }

  // Unknown/future process must NOT collapse onto "app" (that would collide + corrupt).
  func testGivenUnknownBundleId_WhenLogBaseName_ThenSanitizedAndDistinct() {
    let tag = Log.logBaseName(forBundleIdentifier: "com.cynexia.family-FoqosTests")
    XCTAssertNotEqual(tag, "app")
    XCTAssertFalse(tag.contains("."))          // sanitized to filename-safe
    XCTAssertEqual(tag, "com-cynexia-family-foqostests")
  }

  func testGivenNilBundleId_WhenLogBaseName_ThenApp() {
    XCTAssertEqual(Log.logBaseName(forBundleIdentifier: nil), "app")
  }

  // --- multi-file enumeration ---

  func testGivenMultiProcessFiles_WhenEnumerating_ThenAllIncludedLegacyExcluded() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("LogEnum-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let expected = ["foqos-app.log", "foqos-monitor.log", "foqos-monitor.1.log"]
    for name in expected {
      try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    // These must be EXCLUDED: legacy single-process file (no dash) and a non-log file.
    try "x".write(to: dir.appendingPathComponent("foqos.log"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

    let names = Set(Log.allLogFileURLs(inDirectory: dir, using: fm).map { $0.lastPathComponent })
    XCTAssertEqual(names, Set(expected))
  }

  // --- collision-free staging names (the :317 bug) ---

  func testGivenTwoProcessCurrentFiles_WhenStagingName_ThenDistinct() {
    let a = URL(fileURLWithPath: "/tmp/foqos-app.log")
    let b = URL(fileURLWithPath: "/tmp/foqos-monitor.log")
    XCTAssertEqual(Log.stagingDestinationName(for: a), "foqos-app.log")
    XCTAssertNotEqual(
      Log.stagingDestinationName(for: a), Log.stagingDestinationName(for: b))
  }
}
```
- [ ] **Step 2: Run → FAIL** (`-only-testing:FoqosTests/LogFileEnumerationTests`): `type 'Log' has no member 'logBaseName'` etc.
- [ ] **Step 3: Implement the three helpers** in `Log.swift` (add inside `public final class Log`, e.g. just above `logDirectory`):
```swift
  // MARK: - Per-process log file naming (#250)

  static let appGroupIdentifier = "group.com.cynexia.family-foqos"

  /// #250: a distinct per-process basename tag so the app, monitor, widget, and shield extensions
  /// never write to the SAME file in the shared container (which would corrupt appends/rotations).
  /// Known targets map to short tags; any unknown/future process falls back to its sanitized bundle
  /// id so it can never collide with a known tag. Pure + testable.
  public static func logBaseName(forBundleIdentifier bundleID: String?) -> String {
    guard let bundleID, !bundleID.isEmpty else { return "app" }
    if bundleID.hasSuffix(".FoqosDeviceMonitor") { return "monitor" }
    if bundleID.hasSuffix(".FoqosWidget") { return "widget" }
    if bundleID.hasSuffix(".FoqosShieldConfig") { return "shield" }
    if bundleID == "com.cynexia.family-foqos" { return "app" }
    return bundleID.lowercased()
      .replacingOccurrences(of: ".", with: "-")
      .replacingOccurrences(of: "_", with: "-")
      .replacingOccurrences(of: "/", with: "-")
  }

  /// #250: every per-process log file (`foqos-<tag>.log` + rotated `foqos-<tag>.N.log`) in the
  /// shared directory, newest-first (deterministic filename tie-break). The `foqos-` prefix excludes
  /// any legacy single-process `foqos.log`. Pure + testable.
  public static func allLogFileURLs(inDirectory dir: URL, using fileManager: FileManager) -> [URL] {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return [] }
    let logFiles = entries.filter {
      $0.lastPathComponent.hasPrefix("foqos-") && $0.pathExtension == "log"
    }
    return logFiles.sorted { lhs, rhs in
      let lDate =
        (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        ?? .distantPast
      let rDate =
        (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        ?? .distantPast
      if lDate != rDate { return lDate > rDate }  // newest first
      return lhs.lastPathComponent < rhs.lastPathComponent  // deterministic tie-break
    }
  }

  /// #250: staging destination name for a log file = its own (already-unique) basename. Fixes the
  /// old index-based naming that collided two processes' current files onto `foqos-current.log`.
  public static func stagingDestinationName(for fileURL: URL) -> String {
    fileURL.lastPathComponent
  }
```
- [ ] **Step 4: Run → PASS** (`-only-testing:FoqosTests/LogFileEnumerationTests`).
- [ ] **Step 5: Commit**
```bash
git add Packages/FoqosShared/Sources/FoqosShared/Log.swift FoqosTests/
git commit -m "feat(#250): pure helpers for per-process log basenames + shared-container enumeration"
```

#### Task H3-2: Root the log directory in the app-group container and wire the helpers

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/Log.swift` (`logDirectory`, `currentLogFile`, `rotateLogFiles`, `_getLogFileURLsUnsafe`, `copyLogFilesToStagingDirectory`)

**Interfaces:**
- Consumes: the three helpers from Task H3-1.
- Note: `getLogFileURLs`, `getTotalLogSize`, `getLogContent`, `getLogContentTail` all delegate to `_getLogFileURLsUnsafe()` and therefore inherit multi-process spanning **with no change**; export callers (`LogExportManager`, `LogExportView`) are unchanged.

> There is no direct unit test for the instance's real-container behaviour (it depends on the app-group entitlement). The **enumeration/naming logic is covered by H3-1's pure tests**; the existing `LogTailTests` continue to exercise the instance end-to-end against whatever directory the host resolves (in the app-hosted test process, `Bundle.main` is the host app → tag `"app"` → `foqos-app.log`); the multi-process integration is verified by the H3-3 device gate. Keep the `.applicationSupportDirectory` fallback so previews/tests without the entitlement still log.

- [ ] **Step 1: `logDirectory`** (`:106-118`) — prefer the shared container, fall back to app-support:
```swift
  private var logDirectory: URL? {
    let baseDir: URL
    if let container = fileManager.containerURL(
      forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
      baseDir = container  // #250: shared across app + extensions
    } else if let appSupport = fileManager.urls(
      for: .applicationSupportDirectory, in: .userDomainMask).first {
      baseDir = appSupport  // fallback: previews/tests without the app-group entitlement
    } else {
      return nil
    }
    let logsDir = baseDir.appendingPathComponent("Logs", isDirectory: true)
    if !fileManager.fileExists(atPath: logsDir.path) {
      try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }
    return logsDir
  }
```
- [ ] **Step 2: `currentLogFile`** (`:120-122`) — per-process basename (compute the tag once):
```swift
  private static let processLogTag = logBaseName(forBundleIdentifier: Bundle.main.bundleIdentifier)

  private var currentLogFile: URL? {
    logDirectory?.appendingPathComponent("foqos-\(Self.processLogTag).log")
  }
```
- [ ] **Step 3: `rotateLogFiles`** (`:250-269`) — rotate only THIS process's files:
```swift
  private func rotateLogFiles() {
    guard let logDir = logDirectory, let currentFile = currentLogFile else { return }
    let tag = Self.processLogTag

    for i in stride(from: maxLogFiles - 1, through: 1, by: -1) {
      let oldFile = logDir.appendingPathComponent("foqos-\(tag).\(i).log")
      let newFile = logDir.appendingPathComponent("foqos-\(tag).\(i + 1).log")
      if fileManager.fileExists(atPath: oldFile.path) {
        if i == maxLogFiles - 1 {
          try? fileManager.removeItem(at: oldFile)
        } else {
          try? fileManager.moveItem(at: oldFile, to: newFile)
        }
      }
    }

    let rotatedFile = logDir.appendingPathComponent("foqos-\(tag).1.log")
    try? fileManager.moveItem(at: currentFile, to: rotatedFile)
  }
```
- [ ] **Step 4: `_getLogFileURLsUnsafe`** (`:284-301`) — delegate to the pure enumerator (now spans ALL processes' files):
```swift
  /// Get all log file URLs (every process's files in the shared container) — MUST be called from
  /// within `queue` (or `queue.sync`).
  private func _getLogFileURLsUnsafe() -> [URL] {
    guard let logDir = logDirectory else { return [] }
    return Self.allLogFileURLs(inDirectory: logDir, using: fileManager)
  }
```
- [ ] **Step 5: `copyLogFilesToStagingDirectory`** (`:313-322`) — use collision-free basenames **and copy best-effort per file** (see Skeptic Pass finding H-1). Now that export enumerates **every** process's files, a sibling process (e.g. the monitor) may rotate/remove *its own* file in the window between `_getLogFileURLsUnsafe()` and `copyItem` — our `queue.sync` only serializes **this** process, not siblings. A throwing `copyItem` would abort the **whole** export (the caller rethrows and the share sheet never appears), silently dropping even the successfully-enumerated `foqos-app.log`. Skip a vanished source instead; the caller's existing `guard !copiedFiles.isEmpty` (`LogExportManager.swift:47`) still surfaces `noLogsAvailable` if *every* file fails. This matches the method's own doc-comment ("best-effort snapshot … not an all-or-nothing filesystem transaction", `Log.swift:308-310`).
```swift
  public func copyLogFilesToStagingDirectory(_ stagingDir: URL) throws {
    queue.sync {
      let urls = _getLogFileURLsUnsafe()
      for url in urls {
        let destURL = stagingDir.appendingPathComponent(Self.stagingDestinationName(for: url))
        // #250 best-effort: a sibling process may rotate/remove ITS OWN file between
        // enumeration and copy (cross-process — our serial queue only orders THIS process).
        // Skip such a file rather than aborting the whole export.
        try? fileManager.copyItem(at: url, to: destURL)
      }
    }
  }
```
  Keep the `throws` on the signature so the two `try` call sites (`LogExportManager.swift:42`, `LogTailTests.swift:107`) compile unchanged, even though the body no longer throws.
- [ ] **Step 6: Verify `clearLogs`/`getTotalLogSize`/`getLogContent`/`getLogContentTail` need no edit.** `clearLogs` (`:374-388`) already removes every `pathExtension == "log"` in `logDirectory` — now correctly clears **all** processes' files in the shared container (intended: "Clear all"). The other three call `_getLogFileURLsUnsafe()` and inherit spanning. Then confirm no hardcoded single-process basename remains anywhere (note the corrected `-e` form — every pattern is passed via `-e`):
```bash
grep -nF -e '"foqos.log"' -e 'foqos.\(' Packages/FoqosShared/Sources/FoqosShared/Log.swift
```
Expected: **nothing** (all references now go through `foqos-\(tag)…` or the `foqos-` prefix filter).
- [ ] **Step 7: Run the log tests + build the whole target** (the instance suite must stay green; the widened enumeration must not regress single-process behaviour):
```
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/LogTailTests -only-testing:FoqosTests/LogFileEnumerationTests | xcpretty
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug -destination 'generic/platform=iOS Simulator' build | xcpretty
```
Expected: all green + `BUILD SUCCEEDED`.
- [ ] **Step 8: `swift-format lint`** the touched package file (Log.swift is under `Packages/`, still covered by the repo config): `swift-format lint Packages/FoqosShared/Sources/FoqosShared/Log.swift`.
- [ ] **Step 9: Commit**
```bash
git add Packages/FoqosShared/Sources/FoqosShared/Log.swift
git commit -m "fix(#250): root logs in app-group container with per-process basenames (extension logs now export)"
```

#### Task H3-3: Device / integration acceptance (gate before merge)

- [ ] **DEVICE GATE (required, no debugger):** on a real device, (i) run the app so it logs, and (ii) trigger the **monitor extension** to log (e.g. let a scheduled profile's DeviceActivity interval fire, or otherwise exercise `FoqosDeviceMonitor`). Then **Export Logs** from the main app and open the resulting archive. Confirm it contains **both** `foqos-app.log` **and** `foqos-monitor.log` (and `foqos-widget.log` if the widget was rendered) — i.e. extension logs are now included, with **no filename collisions**. Confirm the app still logs and reads its own tail normally (in-app log viewer unaffected). Attach the archive's file listing to the PR (real commit SHA in the version footer, no `+wip`).
- [ ] **CODE-INSPECTION acceptance (no live users):** confirm no migration of the legacy `.applicationSupportDirectory/Logs/foqos.log` is attempted (that file is intentionally orphaned — Out-of-scope).

---

### Mini-plan H — final checks (before requesting review)

- [ ] **Full suite green** on the booted sim (single UUID boot):
```
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
```
- [ ] **`swift-format lint --recursive .` clean.**
- [ ] **PII / leak audit greps return nothing** (regression tripwires):
```bash
grep -rnF -e 'member.displayName' -e 'nameComponents?.formatted()' -e 'lookupInfo?.emailAddress' \
  Foqos/CloudKit/CloudKitNetworkService+FamilyMembers.swift   # H1: no PII log interpolation
grep -nF 'profile.physicalUnblockNFCTagId ?? "nil"' Foqos/Components/Debug/ProfileDebugCard.swift  # H2: no raw on-screen UID
grep -nF '"foqos.log"' Packages/FoqosShared/Sources/FoqosShared/Log.swift   # H3: no single-process basename
```
All three must return **nothing**. (`member.role.displayName`, the retained non-PII role, does not match the H1 pattern.)
- [ ] **Request code review** (AGENTS.md: review before merge). Reference #252, #247, #250 and epic #263. Note MD-H2 (Option A recommended) awaits maintainer confirmation; H1 and H3 have no maintainer fork.

### Out of scope (do NOT do here)
- **#252:** any change to `revokeShareAccess` (already PII-safe — the reference pattern); auditing non-family-member log sites (this fix is scoped to the four `FamilyMembers` sites).
- **#247:** hiding the whole Debug entry (Option B — only if the maintainer overrides MD-H2); any crypto/obfuscation/attempt-gating on the UID (threat model is friction, not DRM); redacting non-credential Debug fields.
- **#250:** migrating/sweeping the legacy `.applicationSupportDirectory/Logs/foqos.log` (pre-release, no live users); adding `flock`/`NSFileCoordinator` write-locks (per-process basenames make them unnecessary); cross-process chronological merge of tailed content (the tail is a best-effort preview; the export includes all files, which is the requirement).


---

## Skeptic Pass — Mini-plan H (maintainer-directed, PR #309)

Focus attacked hardest per maintainer direction: #250's cross-process app-group log writing (H3). Grounded at `e7ac000`-identical files.

1. *(major, export-resilience)* **`copyLogFilesToStagingDirectory` can abort the ENTIRE export when a sibling process rotates/removes its own file between enumeration and copy — and the plan's MD affirmatively (and incompletely) calls cross-process reads "safe".** After H3-2, export enumerates ALL processes' files (`_getLogFileURLsUnsafe` → `allLogFileURLs`, plan lines 621-628) and copies each with a throwing `try fileManager.copyItem` inside `queue.sync` (plan lines 632-640, unchanged loop structure from `Log.swift:313-322`). The app's `queue` (`Log.swift:91`) only serializes the **app's own** writes/rotations — it does NOT block the monitor process. Window: `allLogFileURLs` returns `[…, foqos-monitor.log, foqos-monitor.1.log]`; the monitor then crosses 5 MB and runs `rotateLogFiles` → `moveItem(foqos-monitor.log → foqos-monitor.1.log)` (plan lines 617-618); the app's next `copyItem(at: foqos-monitor.log …)` throws (source gone). Because `copyLogFilesToStagingDirectory` propagates the throw, `LogExportManager.createLogArchive()` (`LogExportManager.swift:42`) rethrows and `shareLogArchive` (`:163-165`) swallows it — the user gets **no share sheet at all**, dropping even the successfully-enumerated `foqos-app.log`. Note this exact hazard did NOT exist single-process: `queue.sync` fully serialized copy-vs-rotate in one process; per-process basenames create a NEW cross-process read hazard on the export path that the MD (plan line 384: "only cross-process operations are read-only enumeration and clearLogs; both are safe") does not cover. The `clearLogs`/writeToFile fresh-handle reasoning is correct for the WRITER but says nothing about the READER's throwing `copyItem`. Rotation requires a single process's file to exceed 5 MB so it is **rare**, but the failure is a wholesale silent export failure precisely in the high-log-volume situations where the logs matter most. -> **Plan-body edit to H3-2 Step 5** (applied to H3-2 Step 5 above): make the copy loop best-effort per-file (`try?`/continue), matching the method's own doc-comment framing ("consistent snapshot … does not provide an all-or-nothing filesystem transaction", `Log.swift:308-310`). The caller's existing `guard !copiedFiles.isEmpty` (`LogExportManager.swift:47`) still surfaces `noLogsAvailable` if every file fails, so swallowing per-file errors is safe. Not a maintainer fork — the proportionate resolution is determined.

2. *(minor, non-issue — confirmed sound)* **Per-process basename structurally eliminates concurrent SAME-file writes and cross-process rotation collisions — the maintainer's primary concern dissolves.** Each process computes `processLogTag` once from `Bundle.main.bundleIdentifier` (plan line 593); in an app extension `Bundle.main.bundleIdentifier` returns the extension's own id (plan line 375, correct), so app→`foqos-app.log`, monitor→`foqos-monitor.log`, widget→`foqos-widget.log`, shield→`foqos-shield.log`. No two processes ever open, append to, or `moveItem`-rotate the same path. `logBaseName`'s unknown-id fallback (plan lines 518-522) sanitizes to a distinct tag rather than collapsing onto `"app"`, so a future/unknown process cannot collide either (test at plan lines 459-464 pins this). -> No `flock`/`NSFileCoordinator` for writes is correct; adding them would be over-engineering. Confirmed dissolved.

3. *(minor, accepted-residual — should be named)* **Export mid-APPEND yields at worst a torn trailing line, which is acceptable, but the plan never states it.** If the app's `copyItem` runs while the monitor is mid-`handle.write` (`Log.swift:239-242`), the copy captures whatever bytes are flushed — a possibly-partial last line. For diagnostics this is fine, and the read paths that use `try?` (`getLogContent:331`, `getLogContentTail:352`, `getTotalLogSize:397`) silently skip a vanished/unreadable file. Only the copy path (finding 1) hard-fails. -> Add one sentence to H3's MD/Out-of-scope: "torn last line on a concurrently-appended file is an accepted best-effort residual (diagnostics snapshot)." Documentation-only; no code beyond finding 1.

4. *(minor, non-issue — confirmed)* **Directory-creation race across processes is benign.** `logDirectory` calls `createDirectory(at:withIntermediateDirectories: true)` wrapped in `try?` (plan lines 585-587). With `withIntermediateDirectories: true`, an already-existing directory is a success, not an error, so two processes creating the shared `Logs/` concurrently cannot corrupt or throw meaningfully. No coordination needed. Confirmed.

5. *(minor, non-issue — confirmed)* **Intra-process rotation vs enumeration cannot interleave.** All file ops funnel through the serial `queue`: writes via `log → queue.async → processEntry → writeToFile → rotateLogFiles` (`Log.swift:200-219,235`), and every reader (`getLogFileURLs`, `copyLogFilesToStagingDirectory`, `getTotalLogSize`, `getLogContent`, `getLogContentTail`) via `queue.sync`. So within one process a rotation and an enumeration are strictly ordered. The plan's serial-queue premise (plan line 384) holds for same-process operations. Confirmed safe.

6. *(minor, citation/sweep — clean)* **H1/H2 citations are accurate and the drift note is adequately handled.** H1: the four PII sites verified verbatim — `member.displayName` at `CloudKitNetworkService+FamilyMembers.swift:10,20,36`, the `nameComponents/emailAddress` build + `Removed participant '\(name)'` at `:61-64`; the reference `Revoked share access for \(userRecordName)` at `:97`; the participant accessor `userIdentity.userRecordID?.recordName` mirrored from `:92`; `member.id.uuidString` is already proven usable in the same file at `:32`. H2: `ProfileDebugCard.swift:55-56` confirmed verbatim; DebugView's `copyToMarkdown` drift (the `#if DEBUG` reset button shifting lines ~+6) is neutralized because every H2-0 grep is a fixed-string symbol grep (plan lines 208-212), not a line-number lookup — the drift the maintainer flagged is covered, not a defect. The H2-2 concurrency premise (plan line 299 — `copyToMarkdown` already reads `@MainActor` `strategyManager` state today, so an additional `@MainActor AppModeManager.shared.currentMode` read compiles) is sound *conditional on that premise holding at build time*, and the plan already hedges with "thread the mode in as a parameter" if the build complains — an adequate fallback. -> No change.

**Not challenged (the sound core):** The central #250 design is correct and proportionate — rooting logs in the app-group container (`group.com.cynexia.family-foqos`, entitled to app `foqos.entitlements` + monitor, plan lines 368-375) with per-process basenames is the right structural fix and needs no write-side locking (findings 2/4/5). The three pure helpers (`logBaseName`, `allLogFileURLs`, `stagingDestinationName`) are a genuinely lighter test seam than a singleton DEBUG override and their tests are deterministic (plan lines 427-499); the `foqos-` prefix filter correctly orphans legacy `foqos.log` (no-live-users ruling makes that acceptable); the `:317` collision bug (`foqos-current.log` for two processes) is real and correctly fixed by per-file basenames. H1 is a straight conformance fix to the AGENTS.md privacy rule with no maintainer fork. H2's MD-H2 (Option A field-level redaction, `== .child` gate mirroring `LockCodeManager`/`SavedLocation`) is correctly escalated with the right recommendation and is friction-consistency, not crypto. Only finding 1 requires a plan-body change; everything else is confirmation or a one-line documentation add.

---

## Mini-plan G — widget / Live Activity freshness (#238, #249)

> **Tail-bundle ordering.** This mini-plan implements **LAST** (order H → G → #331 → J1+#240),
> AFTER #302/#301/#298, B2, and D3+E2 have merged. Every line number below is **provisional** —
> the two Task 0s re-derive every citation by SYMBOL (fixed-string grep) and record the SHA
> verified against. Grounding here was verified against this worktree's HEAD **`e7ac000`**
> (`A3′ sync conflict semantics (#306)`) — the bare epic-263 tail base. (An earlier draft cited
> `e6f60e1`; that commit is the #216 geofence fix living on branch `a4-location-sync-integrity`
> and is **not** an ancestor of this worktree — every citation below was re-verified against
> `e7ac000` and matches.) Because this bundle merges last, the real base will be newer once H and
> the other bundles land; Task 0 confirms the actual base with `git rev-parse HEAD` and re-greps
> if it differs.

Two independent freshness defects on the "app is not foregrounded" path:
- **G1 · #238** — the DeviceActivity monitor extension registers/tears down blocking on a
  scheduled event but never asks WidgetKit to reload the home-screen widget, so a killed app's
  widget shows stale state.
- **G2 · #249** — the Live Activity's profile name lives in immutable `ActivityAttributes`, so a
  session switch (manual → scheduled) `update`s the existing activity and the banner keeps showing
  the PREVIOUS profile's name.

They touch disjoint files (`TimerActivityUtil`/monitor extension vs `LiveActivityManager`) and can
be implemented in either order. Commit each sub-part under its own `(#238)` / `(#249)` scope.

**Global constraints (copied from `AGENTS.md`, apply to every task):** NEVER force-commit/amend —
new commits only, `git revert` to undo; request code review before merge. `Log` for all logging
(never `print`); never log lock codes / personal identifiers (UUIDs, timestamps, profile names are
acceptable). `swift-format` clean, 2-space indent, ~100–120 col. Pin time in tests (one
`let now = Date()` per test, derive the rest). Boot ONE iPhone 17 simulator **by UUID** (never by
name) and reuse it:
```
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/<Class> | xcpretty
```

---

### G1 · #238 — the monitor extension never reloads widget timelines

#### Problem (device-observed)

With the app **killed**, a scheduled profile stop fires `intervalDidEnd(for:)` in the
`DeviceActivityMonitor` extension, which tears down the blocking via
`TimerActivityUtil.stopTimerActivity(for:)`
(`FoqosDeviceMonitor/DeviceActivityMonitorExtension.swift:42`). The home-screen
**`ProfileControlWidget`** is never reloaded, so it keeps showing the profile as active/blocking
until something in the main app happens to run `WidgetCenter.shared.reloadTimelines`. Same on the
start edge (`:34`, `intervalDidStart` → `startTimerActivity`).

#### Grounding (verified at `e7ac000`)

The extension routes every interval event through `TimerActivityUtil`, and neither the extension
nor any FoqosShared timer type touches WidgetKit:

`FoqosDeviceMonitor/DeviceActivityMonitorExtension.swift:30-44`:
```swift
  override func intervalDidStart(for activity: DeviceActivityName) {
    super.intervalDidStart(for: activity)

    log.info("intervalDidStart for activity: \(activity.rawValue)")
    TimerActivityUtil.startTimerActivity(for: activity)
    reconcileAfterWake()
  }

  override func intervalDidEnd(for activity: DeviceActivityName) {
    super.intervalDidEnd(for: activity)

    log.info("intervalDidEnd for activity: \(activity.rawValue)")
    TimerActivityUtil.stopTimerActivity(for: activity)
    reconcileAfterWake()
  }
```

`Packages/FoqosShared/Sources/FoqosShared/Timers/TimerActivityUtil.swift:4-26` (both funnels early-
return via `guard` when the timer type / profile snapshot is missing — note this for the
"unconditional" requirement below):
```swift
  public static func startTimerActivity(for activity: DeviceActivityName) {
    let parts = getTimerParts(from: activity)

    guard let timerActivity = getTimerActivity(for: parts.deviceActivityId),
      let profile = getProfile(for: parts.profileId)
    else {
      return
    }

    timerActivity.start(for: profile)
  }
  // …stopTimerActivity(for:) is symmetric (:16-26)…
```

**Confirmed by grep at `e7ac000`:**
- `grep -rn "WidgetKit\|WidgetCenter\|reloadTimelines" Packages/FoqosShared FoqosDeviceMonitor
  FoqosShieldConfig` → **zero hits**. `import WidgetKit` in the FoqosShared/extension link-set does
  not exist; it appears in the `FoqosWidget` target (`FoqosWidgetLiveActivity.swift:4`) and in the
  main app's `StrategyManager.swift` / `EmergencyUnblockManager.swift`.
- `WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")` appears **only in the main
  app**: `StrategyManager.swift:211,843,880,974,1016` and `EmergencyUnblockManager.swift:359`.
- The widget kind string is authoritative: `FoqosWidget/Widgets/ProfileControlWidget.swift:14`
  `let kind: String = "ProfileControlWidget"`.
- The **only** callers of `TimerActivityUtil.start/stopTimerActivity` are the two monitor-extension
  overrides above (`grep -rnF 'TimerActivityUtil.startTimerActivity' … 'TimerActivityUtil.stopTimerActivity'`
  across `Foqos FoqosDeviceMonitor FoqosShieldConfig Packages FoqosWidget` → exactly 2 hits, both
  in `DeviceActivityMonitorExtension.swift:34,42`). ⇒ a reload placed inside those two
  `TimerActivityUtil` funnels fires **exactly once per scheduled event, from the extension only** —
  no double-reload with the main app's own calls.

**Key enabling fact (from the task brief, treat as given — NOT verified from this repo's code):**
`WidgetCenter` is callable from a `DeviceActivityMonitor` app extension, and
`reloadTimelines(ofKind:)` reloads the *whole* kind (all profiles) — so **one** call per event
fully satisfies "coalesce per event, not per profile". Task G1-1 Step 6 empirically confirms the
link by building every FoqosShared consumer; the fallback there covers the (unexpected) case where
an extension cannot link WidgetKit.

#### MAINTAINER DECISIONS — none needed (two design choices resolved and justified)

Both open design choices have a proportionate, provable answer, so this sub-part prescribes them;
**no maintainer decision is required.** Recorded here for the implementer:

- **(a) Coalesce point — resolved: inside `TimerActivityUtil.start/stopTimerActivity` via an
  injected seam, NOT in the extension's `intervalDidStart/intervalDidEnd`.** Placing the reload in
  the extension would be marginally lower-risk as an *import site*, but the extension override is
  **not reachable from `FoqosTests`** (it lives in the `FoqosDeviceMonitor` target, instantiated by
  the OS), so it cannot carry a unit test. The two `TimerActivityUtil` funnels are the extension's
  *sole* entry points (grep above) — putting the seam there gives **identical runtime coverage** AND
  a testable seam, with **no edit to the extension at all**. This is strictly better; we take it.
- **(b) Fire unconditionally per event vs only-on-state-change — resolved: unconditionally
  (idempotent).** `reloadTimelines(ofKind:)` is cheap and idempotent; a `defer` at the top of each
  funnel fires the reload on **every** exit path, including the `guard` early-returns (missing
  snapshot). This is the simplest correct behaviour and needs no state tracking.

#### Testability

`WidgetCenter.shared` has no injectable seam and is not observable in unit tests. We add an
**injected reload closure** on `TimerActivityUtil` (`static var reloadWidgets`) whose default calls
the real `WidgetCenter`; a unit test overrides it with a spy and asserts it fired. The spy test runs
in `FoqosTests/ScheduleTimerActivityTests.swift` (already `import FoqosShared` — NOT `@testable`,
the seam is `public` — and configures `SharedData` via a per-test `UserDefaults` suite in `setUp`,
so `TimerActivityUtil` is fully exercisable there). The end-to-end "killed app" behaviour is
device-only (DEVICE ACCEPTANCE row).

#### Task G1-0: Citation refresh (MANDATORY — do this first, no code)

- [ ] **Step 1: Record the base SHA.** `git rev-parse HEAD` — expect the tail-bundle base (grounded
  against `e7ac000`; will be newer once H and the other bundles merge). Record it in the Task G1-1
  commit body. If it differs, re-run every grep below and reconcile line numbers before writing code.
- [ ] **Step 2: Confirm the seam target + funnels + extension callers (symbol greps):**
```bash
grep -nF -e 'public static func startTimerActivity(for activity: DeviceActivityName)' \
  -e 'public static func stopTimerActivity(for activity: DeviceActivityName)' \
  -e 'import WidgetKit' -e 'reloadWidgets' \
  Packages/FoqosShared/Sources/FoqosShared/Timers/TimerActivityUtil.swift
grep -nF -e 'TimerActivityUtil.startTimerActivity(for: activity)' \
  -e 'TimerActivityUtil.stopTimerActivity(for: activity)' \
  FoqosDeviceMonitor/DeviceActivityMonitorExtension.swift
grep -rnF 'TimerActivityUtil.startTimerActivity' FoqosDeviceMonitor Foqos FoqosShieldConfig Packages FoqosWidget
grep -rnF 'TimerActivityUtil.stopTimerActivity'  FoqosDeviceMonitor Foqos FoqosShieldConfig Packages FoqosWidget
```
  Assert: the two funnel signatures are unchanged; the extension still routes through them; and the
  ONLY callers are the two extension overrides (at `e7ac000`: `DeviceActivityMonitorExtension.swift:34,42`).
  If a new caller appeared, note it — the reload is idempotent so extra callers are harmless, but
  record it.
- [ ] **Step 3: Confirm the widget kind string** is still `"ProfileControlWidget"`:
```bash
grep -nF 'let kind: String = "ProfileControlWidget"' FoqosWidget/Widgets/ProfileControlWidget.swift
grep -rnF 'reloadTimelines(ofKind: "ProfileControlWidget")' Foqos
```
  If the kind string changed, use the new literal everywhere below.
- [ ] **Step 4: Confirm the test host** — `FoqosTests/ScheduleTimerActivityTests.swift` exists,
  `import FoqosShared`, and sets `SharedData.configure(suite:)` in `setUp`
  (`grep -n 'SharedData.configure' FoqosTests/ScheduleTimerActivityTests.swift`). Also confirm
  `public static let id` on `ScheduleTimerActivity` (used by the spy test's activity name):
  `grep -nF 'public static let id' Packages/FoqosShared/Sources/FoqosShared/Timers/ScheduleTimerActivity.swift`.
  This is where G1's spy test lands.

#### Task G1-1: Add the injectable `reloadWidgets` seam and fire it once per interval event

**Files:**
- Modify: `Packages/FoqosShared/Sources/FoqosShared/Timers/TimerActivityUtil.swift`
- Test: `FoqosTests/ScheduleTimerActivityTests.swift`

**Interfaces:**
- Produces: `TimerActivityUtil.reloadWidgets: @Sendable () -> Void` (public, overridable static
  seam; default reloads the `"ProfileControlWidget"` kind). Fired via `defer` at the top of both
  `startTimerActivity` and `stopTimerActivity`.

- [ ] **Step 1: Write the failing spy test** (append to `ScheduleTimerActivityTests.swift`). **Add `import DeviceActivity` to the top of the test file** (Skeptic Pass finding G-1): the spy calls `DeviceActivityName(rawValue:)`, but the file today imports only `FoqosShared` + `XCTest` and `FoqosShared` does **not** `@_exported`-re-export `DeviceActivity`, so `DeviceActivityName` is not in scope — the sibling `C2BackstopRoutingTests.swift:1` imports `DeviceActivity` for exactly this reason. Without it the two tests fail with `cannot find 'DeviceActivityName' in scope` and never reach the intended Step-2 failure. The seam itself is `public` (no `@testable` needed). Add a tiny `@unchecked Sendable` counter
  (the seam closure is `@Sendable`; it is invoked synchronously on the caller's thread via `defer`,
  so there is no real concurrency). Two cases, both exercising the `guard` early-return path (no
  `SharedData` snapshot is configured for the random id, so both funnels early-return) — this
  directly proves the reload is **unconditional per event**: (1) a start funnel fires exactly one
  reload; (2) a stop funnel fires exactly one reload.

```swift
// #238: the DeviceActivityMonitor extension routes every interval event through
// TimerActivityUtil.start/stopTimerActivity, so a reload fired there refreshes the home-screen
// widget after a scheduled start/stop even while the app is killed. reloadWidgets is the seam.
// Both cases use a random profile id with NO snapshot, so each funnel hits its `guard … else
// { return }` — proving the reload still fires (unconditional/idempotent per event).
private final class ReloadSpy: @unchecked Sendable {
  private(set) var count = 0
  func fire() { count += 1 }
}

func testGivenStartFunnelWithNoSnapshot_WhenInvoked_ThenWidgetReloadFiredOnce() {
  let original = TimerActivityUtil.reloadWidgets
  defer { TimerActivityUtil.reloadWidgets = original }
  let spy = ReloadSpy()
  TimerActivityUtil.reloadWidgets = { spy.fire() }

  // "type:profileId" form — the current DeviceActivityName encoding (TimerActivityUtil getTimerParts).
  let activity = DeviceActivityName(
    rawValue: "\(ScheduleTimerActivity.id):\(UUID().uuidString)")
  TimerActivityUtil.startTimerActivity(for: activity)

  XCTAssertEqual(
    spy.count, 1, "each start funnel must request exactly one widget reload (#238)")
}

func testGivenStopFunnelWithNoSnapshot_WhenInvoked_ThenWidgetReloadFiredOnce() {
  let original = TimerActivityUtil.reloadWidgets
  defer { TimerActivityUtil.reloadWidgets = original }
  let spy = ReloadSpy()
  TimerActivityUtil.reloadWidgets = { spy.fire() }

  TimerActivityUtil.stopTimerActivity(
    for: DeviceActivityName(rawValue: "\(ScheduleTimerActivity.id):\(UUID().uuidString)"))

  XCTAssertEqual(spy.count, 1)
}
```

- [ ] **Step 2: Run to verify it FAILS to compile** (`reloadWidgets` undefined). Boot the sim once
  (see AGENTS.md), then:
```
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/ScheduleTimerActivityTests | xcpretty
```
  Expected: **compile error** — `type 'TimerActivityUtil' has no member 'reloadWidgets'`.

- [ ] **Step 3: Add the seam** — edit `TimerActivityUtil.swift`. Add the `WidgetKit` import and the
  static seam. `nonisolated(unsafe)` is the codebase-standard escape hatch for an overridable
  static under Swift 6 strict concurrency (the codebase uses it for statics in `Foqos/Intents/*.swift`,
  though those are documented "immutable after init"; here the var is deliberately reassigned in
  tests, so the closure is `@Sendable` and `WidgetCenter.shared.reloadTimelines` is safe from any
  thread).

  a. Change the imports (top of file) from `import DeviceActivity` to:
```swift
import DeviceActivity
import WidgetKit
```
  b. Add the seam as the first member of `public class TimerActivityUtil {`:
```swift
  /// #238: reload the home-screen widget after every scheduled interval event. The
  /// DeviceActivityMonitor extension CAN call WidgetKit, and reloadTimelines(ofKind:) reloads the
  /// whole kind (all profiles) — one call per event fully covers it. Overridable for unit tests;
  /// the default hits the real WidgetCenter (kind string authoritative in
  /// FoqosWidget/Widgets/ProfileControlWidget.swift:14).
  public nonisolated(unsafe) static var reloadWidgets: @Sendable () -> Void = {
    WidgetCenter.shared.reloadTimelines(ofKind: "ProfileControlWidget")
  }
```

- [ ] **Step 4: Fire it unconditionally per event.** Add `defer { Self.reloadWidgets() }` as the
  **first** line of both funnels so it runs on every exit path (including the `guard` return):
```swift
  public static func startTimerActivity(for activity: DeviceActivityName) {
    defer { Self.reloadWidgets() }  // #238: refresh the widget on every interval event
    let parts = getTimerParts(from: activity)

    guard let timerActivity = getTimerActivity(for: parts.deviceActivityId),
      let profile = getProfile(for: parts.profileId)
    else {
      return
    }

    timerActivity.start(for: profile)
  }

  public static func stopTimerActivity(for activity: DeviceActivityName) {
    defer { Self.reloadWidgets() }  // #238: refresh the widget on every interval event
    let parts = getTimerParts(from: activity)

    guard let timerActivity = getTimerActivity(for: parts.deviceActivityId),
      let profile = getProfile(for: parts.profileId)
    else {
      return
    }

    timerActivity.stop(for: profile)
  }
```
  **No edit to `DeviceActivityMonitorExtension.swift` is needed** — it already routes both interval
  events through these funnels (grounding grep). Do not add a WidgetKit call in the extension too
  (would double-reload; harmless but noise).

- [ ] **Step 5: Run to verify the two tests PASS:**
```
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/ScheduleTimerActivityTests | xcpretty
```
  Expected: green.

- [ ] **Step 6: Build EVERY target that links `FoqosShared`** — the new `import WidgetKit` in a
  FoqosShared file must link in the app, the monitor extension, the shield-config extension, and the
  widget. Build the whole scheme:
```
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug -destination 'generic/platform=iOS Simulator' build | xcpretty
```
  Expected: `BUILD SUCCEEDED`. **If any extension target fails to link WidgetKit** (unexpected —
  WidgetKit is a system framework available to app extensions), fall back to keeping the seam's
  default as a no-op in FoqosShared (`public nonisolated(unsafe) static var reloadWidgets:
  @Sendable () -> Void = {}`, drop `import WidgetKit`) and set the real closure in the extension's
  `init` (`DeviceActivityMonitorExtension.swift`, which may `import WidgetKit`):
  `TimerActivityUtil.reloadWidgets = { WidgetCenter.shared.reloadTimelines(ofKind:
  "ProfileControlWidget") }`. Prefer the direct import; use the fallback only if the build forces it.

- [ ] **Step 7: `swift-format lint --recursive .`** — clean.

- [ ] **Step 8: Commit**
```bash
git add Packages/FoqosShared/Sources/FoqosShared/Timers/TimerActivityUtil.swift FoqosTests/ScheduleTimerActivityTests.swift
git commit -m "fix(#238): reload ProfileControlWidget timelines on every DeviceActivity interval event"
```

#### DEVICE ACCEPTANCE (gate before merge — device-only)

- [ ] **DEVICE GATE (required, no debugger):** create a scheduled profile so it is active/blocking,
  add the `ProfileControlWidget` to the home screen, and **force-quit the app**. When the schedule's
  **stop** interval arrives (app still killed), the home-screen widget updates to the stopped/idle
  state **without** re-launching the app. Repeat for the **start** edge (widget flips to
  active/blocking). Capture an exported log (Settings footer must show a real commit SHA, no `+wip`)
  on the PR.

---

### G2 · #249 — Live Activity shows the previous profile's name after a session switch

#### Problem (device-observed)

After a session switch while backgrounded (a manual session is taken over by a scheduled profile, or
vice-versa), the Live Activity banner keeps showing the **previous** profile's name. The name is
carried in immutable `ActivityAttributes`, but the switch path only `update`s the existing
activity's `ContentState`, which cannot change the name.

#### Grounding (verified at `e7ac000`)

The name is an **attribute**, not part of `ContentState`, so it is fixed at `Activity.request` time
and can never change via `.update`:

`FoqosWidget/FoqosWidgetLiveActivity.swift:6-30`:
```swift
struct FoqosWidgetAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable, BreakDurationCalculable {
    var startTime: Date
    var isBreakActive: Bool = false
    // …no name here…
  }

  var name: String      // :28 — immutable after Activity.request
  var message: String   // :29
}
```

`Foqos/Utils/LiveActivityManager.swift:57-79` — the switch hits the `currentActivity != nil` branch
and `update`s (keeping the old name); the `enableLiveActivity == false` guard is **below** that
early return, so a switched-in *disabled* profile also gets updated instead of ended:
```swift
  func startSessionActivity(session: BlockedProfileSession) {
    // Check if Live Activities are supported
    guard isSupported else {
      Log.info("Live Activities are not supported on this device", category: .liveActivity)
      return
    }

    // Check if we can restore an existing activity first
    if currentActivity == nil {
      restoreExistingActivity()
    }

    // Check if we already have an activity running
    if currentActivity != nil {
      Log.info("Live Activity is already running, will update instead", category: .liveActivity)
      updateSessionActivity(session: session)   // ← keeps the OLD profile's name (#249)
      return
    }

    if session.blockedProfile.enableLiveActivity == false {   // ← MIS-PLACED: below the update return
      Log.info("Activity is disabled for profile", category: .liveActivity)
      return
    }
    // …request path (:81-108) builds attributes with the incoming name…
```

- Only the activity **id** is persisted (`:11`
  `@AppStorage("family_foqos_current_activity_id")`) — there is no record of *which profile* the
  current activity belongs to, so the switch cannot detect a profile change.
- `endSessionActivity()` (`:179-199`) dispatches the system end **async** (`Task { … endActivity }`,
  `:191-194`) but clears the local reference and stored id **synchronously** (`removeActivityId()`
  `:197`, `currentActivity = nil` `:198`).
- `updateBreakState`/`updateOneMoreMinuteState` (`:133`, `:156`) correctly stay as `update`s and are
  **out of scope** (same profile).
- Switch entry points both call `startSessionActivity` with **no profile compare and no preceding
  end**: `StrategyManager.swift:110` (inside `loadActiveSession`, `:94`) and
  `StrategyManager.swift:834` (inside `activateSession`, `:821`). Neither needs changing — the fix
  is entirely inside `LiveActivityManager` (verified: `grep -rnF 'startSessionActivity(session:' Foqos`
  → only these two call sites plus the definition).
- `isSupported` (`:20-25`, `ActivityAuthorizationInfo().areActivitiesEnabled`) is **false on the
  simulator**, so `startSessionActivity`'s real ActivityKit path cannot be exercised in a unit test.
  Imports present: `ActivityKit`, `Foundation`, `SwiftUI`. **No existing `LiveActivityManager` test
  file** (`ls FoqosTests | grep -i liveactivity` → nothing).

#### MAINTAINER DECISIONS — none needed (fix shape is determined)

The fix is mechanical and proportionate; nothing to escalate:
1. Persist the current activity's **profile id** alongside its id (a second `@AppStorage` key with
   the `family_foqos_` prefix).
2. In `startSessionActivity`, before touching the existing activity, decide from
   `(currentProfileId, incomingProfileId, enableLiveActivity, hasCurrentActivity)`:
   same profile + enabled ⇒ `update`; **different** profile + enabled ⇒ **end + re-request**
   (fixes #249); disabled + has activity ⇒ **end** (the mis-placed guard, now moved above the update
   branch, so a switched-in disabled profile is torn down not updated); disabled + no activity ⇒
   `skip`; no activity + enabled ⇒ `start`.
3. Sequence the recreate as `end` (clears `currentActivity` synchronously) **then**
   `Activity.request` — the system end is async but the local state is already clear, so the new
   request is safe.

> **Behavioral note (prescribed, not escalated):** the `.end` outcome for a switched-in **disabled**
> profile changes today's behaviour (which updates the stale activity) to tearing it down. This is
> the only correct resolution — a profile configured with `enableLiveActivity == false` must not
> display a Live Activity — so it is prescribed here rather than raised as a maintainer decision.

#### Testability

`ActivityKit` cannot run on the simulator, so `startSessionActivity`'s imperative body is
**code-inspection / device-only**. We extract the branch logic into a **pure** static helper
`LiveActivityManager.decideAction(...)` that takes only value inputs (no ActivityKit) and unit-test
it **exhaustively** over the input space (new file `FoqosTests/LiveActivityManagerTests.swift`,
`@testable import FamilyFoqos` — the codebase-standard app-module test import). The end-to-end
name-refresh is the DEVICE ACCEPTANCE row.

> **Note on the enum:** the task brief sketches `enum LiveActivityAction { case start, update,
> recreate, skip }`. Faithfully encoding "a switched-in **disabled** profile must be **ended**, not
> updated" needs one more outcome — tearing an activity **down without re-requesting** — which is
> neither `recreate` (that re-requests) nor `skip` (that does nothing). We therefore add a fifth
> case `.end`. This keeps the decision total and each outcome distinct (the brief's list was "e.g.").

#### Task G2-0: Citation refresh (MANDATORY — do this first, no code)

- [ ] **Step 1: Record the base SHA** (`git rev-parse HEAD`; grounded against `e7ac000`). Put it in
  the Task G2-1 commit body; re-grep if it differs.
- [ ] **Step 2: Confirm the `LiveActivityManager` seams by symbol:**
```bash
grep -nF -e '@AppStorage("family_foqos_current_activity_id")' \
  -e 'func startSessionActivity(session: BlockedProfileSession)' \
  -e 'if currentActivity != nil {' \
  -e 'if session.blockedProfile.enableLiveActivity == false {' \
  -e 'func endSessionActivity()' -e 'private func removeActivityId()' \
  -e 'private func saveActivityId(' \
  Foqos/Utils/LiveActivityManager.swift
grep -nF -e 'var name: String' -e 'struct ContentState' FoqosWidget/FoqosWidgetLiveActivity.swift
grep -rnF 'startSessionActivity(session:' Foqos   # confirm the two switch call sites unchanged
```
  Assert: the update-before-guard ordering still exists (the defect), only the activity **id** is
  stored, `name` is still an attribute (not in `ContentState`), and the switch call sites are still
  `StrategyManager.swift:110` (`loadActiveSession`) + `:834` (`activateSession`).
- [ ] **Step 3: Confirm no `LiveActivityManager` test file exists yet**
  (`ls FoqosTests | grep -i liveactivity` → nothing) — Task G2-1 creates it.

#### Task G2-1: Extract the pure `decideAction` helper and unit-test it exhaustively

**Files:**
- Modify: `Foqos/Utils/LiveActivityManager.swift`
- Test: `FoqosTests/LiveActivityManagerTests.swift` (create)

**Interfaces:**
- Produces: file-scope `enum LiveActivityAction { case start, update, recreate, end, skip }`
  (`: Equatable`) and `LiveActivityManager.decideAction(currentProfileId: UUID?,
  incomingProfileId: UUID, enableLiveActivity: Bool, hasCurrentActivity: Bool) -> LiveActivityAction`.
  Task G2-2 consumes it. (`BlockedProfiles.id` is `UUID`, `enableLiveActivity` is `Bool` — both
  match the parameter types.)

- [ ] **Step 1: Write the failing exhaustive test** (create `FoqosTests/LiveActivityManagerTests.swift`).
  The helper is pure — no ActivityKit, no SwiftData, no `SharedData`; just UUIDs and Bools.

```swift
import Foundation
import XCTest

@testable import FamilyFoqos

final class LiveActivityManagerTests: XCTestCase {
  // #249: decideAction is the pure switch-logic seam extracted from startSessionActivity, so the
  // "different profile ⇒ recreate (new name)" and "disabled ⇒ end" rules can be tested without
  // ActivityKit (unavailable on the simulator).

  func testGivenNoActivityAndEnabled_WhenDecide_ThenStart() {
    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: nil, incomingProfileId: UUID(),
        enableLiveActivity: true, hasCurrentActivity: false),
      .start)
  }

  func testGivenNoActivityAndDisabled_WhenDecide_ThenSkip() {
    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: nil, incomingProfileId: UUID(),
        enableLiveActivity: false, hasCurrentActivity: false),
      .skip)
  }

  func testGivenActivityForSameProfileEnabled_WhenDecide_ThenUpdate() {
    let pid = UUID()
    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: pid, incomingProfileId: pid,
        enableLiveActivity: true, hasCurrentActivity: true),
      .update)
  }

  func testGivenActivityForDifferentProfileEnabled_WhenDecide_ThenRecreate() {
    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: UUID(), incomingProfileId: UUID(),
        enableLiveActivity: true, hasCurrentActivity: true),
      .recreate)  // #249: new profile ⇒ end old + re-request so the NEW name shows
  }

  func testGivenActivityForDifferentProfileDisabled_WhenDecide_ThenEnd() {
    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: UUID(), incomingProfileId: UUID(),
        enableLiveActivity: false, hasCurrentActivity: true),
      .end)  // switched-in disabled profile ⇒ tear down the stale activity, do not update
  }

  func testGivenActivityForSameProfileDisabled_WhenDecide_ThenEnd() {
    let pid = UUID()
    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: pid, incomingProfileId: pid,
        enableLiveActivity: false, hasCurrentActivity: true),
      .end)
  }

  func testGivenActivityButUnknownProfileEnabled_WhenDecide_ThenRecreate() {
    // Restored from a pre-#249 build: an activity exists but its profile id was never stored.
    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: nil, incomingProfileId: UUID(),
        enableLiveActivity: true, hasCurrentActivity: true),
      .recreate)  // can't confirm the name matches ⇒ recreate to guarantee correctness
  }

  func testGivenActivityButUnknownProfileDisabled_WhenDecide_ThenEnd() {
    XCTAssertEqual(
      LiveActivityManager.decideAction(
        currentProfileId: nil, incomingProfileId: UUID(),
        enableLiveActivity: false, hasCurrentActivity: true),
      .end)
  }
}
```
  These eight cases cover the full input space:
  `hasCurrentActivity ∈ {false,true} × enableLiveActivity ∈ {false,true} ×
  currentProfileId ∈ {nil, ==incoming, !=incoming}` (the `currentProfileId` axis is irrelevant when
  `hasCurrentActivity == false`).

- [ ] **Step 2: Run to verify it FAILS** (`decideAction` / `LiveActivityAction` undefined):
```
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/LiveActivityManagerTests | xcpretty
```
  Expected: compile error.

- [ ] **Step 3: Add the enum + pure helper** to `LiveActivityManager.swift`. Put the enum at file
  scope (top of file, after the imports) and the helper as a `nonisolated static func` inside the
  `@MainActor class` (pure over value inputs, so `nonisolated` keeps tests off the main actor):

  a. File scope, after the imports:
```swift
/// #249: the action startSessionActivity must take, decided from value inputs only (no ActivityKit)
/// so it is unit-testable on the simulator.
enum LiveActivityAction: Equatable {
  case start     // no current activity, enabled ⇒ request a new one
  case update    // current activity for the SAME profile, enabled ⇒ update in place
  case recreate  // current activity for a DIFFERENT/unknown profile, enabled ⇒ end + re-request
  case end       // disabled but an activity exists ⇒ tear it down (no re-request)
  case skip      // disabled and no activity ⇒ nothing to do
}
```
  b. Inside `class LiveActivityManager`:
```swift
  /// #249: pure decision for startSessionActivity. A switch to a DIFFERENT profile must recreate
  /// (the name is an immutable ActivityAttribute — an update keeps the old name). A disabled
  /// profile with a live activity must end it. Unknown stored profile (pre-#249 restore) ⇒ recreate
  /// to guarantee the name is correct.
  nonisolated static func decideAction(
    currentProfileId: UUID?,
    incomingProfileId: UUID,
    enableLiveActivity: Bool,
    hasCurrentActivity: Bool
  ) -> LiveActivityAction {
    guard enableLiveActivity else {
      return hasCurrentActivity ? .end : .skip
    }
    guard hasCurrentActivity else {
      return .start
    }
    return currentProfileId == incomingProfileId ? .update : .recreate
  }
```

- [ ] **Step 4: Run to verify all eight tests PASS** (same `-only-testing` command). Expected: green.

- [ ] **Step 5: Commit**
```bash
git add Foqos/Utils/LiveActivityManager.swift FoqosTests/LiveActivityManagerTests.swift
git commit -m "feat(#249): pure decideAction seam for Live Activity session-switch handling"
```

#### Task G2-2: Wire `decideAction` into `startSessionActivity`; persist the profile id

**Files:**
- Modify: `Foqos/Utils/LiveActivityManager.swift`

**Interfaces:**
- Consumes: `decideAction` (G2-1). Adds a second `@AppStorage` key
  `family_foqos_current_activity_profile_id` and a private `currentActivityProfileId: UUID?`
  computed accessor. Stores the profile id on every successful request; clears it on end.

> This task is a **non-injectable ActivityKit presentation surface** — acceptance is
> code-inspection + the DEVICE ACCEPTANCE row. The compile + G2-1's exhaustive helper tests are the
> automated checks; do not add a unit test that requires `Activity.request` (ActivityKit is
> unavailable on the simulator).

- [ ] **Step 1: Add the profile-id storage** — next to the existing activity-id `@AppStorage`
  (`:11`):
```swift
  // Persist WHICH profile the current activity belongs to, so a session switch can detect a
  // profile change and recreate the activity (its name attribute is immutable). #249.
  @AppStorage("family_foqos_current_activity_profile_id")
  private var storedActivityProfileId: String = ""

  private var currentActivityProfileId: UUID? {
    storedActivityProfileId.isEmpty ? nil : UUID(uuidString: storedActivityProfileId)
  }
```

- [ ] **Step 2: Clear the profile id whenever the activity id is cleared.** In `removeActivityId()`
  (`:33-35`), also clear the profile id:
```swift
  private func removeActivityId() {
    storedActivityId = ""
    storedActivityProfileId = ""   // #249: keep the profile id in lockstep with the activity id
  }
```
  (`endSessionActivity()` already calls `removeActivityId()` at `:197`, and
  `restoreExistingActivity()` calls it when the saved id no longer resolves — both now clear the
  profile id too, which is correct. `restoreExistingActivity` does NOT clear it when the id resolves,
  so a post-#249 relaunch keeps the persisted profile id in lockstep with the restored activity.)

- [ ] **Step 3: Extract the request path into a helper** so `recreate` and `start` share it. Add a
  private method holding the current create block (`:81-108`), and set the profile id on success.
  The `ContentState` initializer here is copied verbatim from the existing create block (`:85-92`):
```swift
  private func requestActivity(session: BlockedProfileSession) {
    let profileName = session.blockedProfile.name
    let message = FocusMessages.getRandomMessage()
    let attributes = FoqosWidgetAttributes(name: profileName, message: message)
    let contentState = FoqosWidgetAttributes.ContentState(
      startTime: session.startTime,
      isBreakActive: session.isBreakActive,
      breakStartTime: session.breakStartTime,
      breakEndTime: session.breakEndTime,
      isOneMoreMinuteActive: false,
      oneMoreMinuteStartTime: nil
    )

    do {
      let content = ActivityContent(state: contentState, staleDate: nil)
      let activity = try Activity.request(attributes: attributes, content: content)
      currentActivity = activity
      saveActivityId(activity.id)
      storedActivityProfileId = session.blockedProfile.id.uuidString  // #249
      Log.info(
        "Started Live Activity with ID: \(activity.id) for profile: \(profileName)",
        category: .liveActivity)
    } catch {
      Log.info("Error starting Live Activity: \(error.localizedDescription)", category: .liveActivity)
    }
  }
```

- [ ] **Step 4: Rewrite `startSessionActivity` to route through `decideAction`.** Replace the body
  from the `if currentActivity != nil { … }` block through the end of the old create block (`:69-108`)
  with:
```swift
  func startSessionActivity(session: BlockedProfileSession) {
    // Check if Live Activities are supported
    guard isSupported else {
      Log.info("Live Activities are not supported on this device", category: .liveActivity)
      return
    }

    // Restore any system-side activity so hasCurrentActivity is accurate.
    if currentActivity == nil {
      restoreExistingActivity()
    }

    let action = Self.decideAction(
      currentProfileId: currentActivityProfileId,
      incomingProfileId: session.blockedProfile.id,
      enableLiveActivity: session.blockedProfile.enableLiveActivity,
      hasCurrentActivity: currentActivity != nil)

    switch action {
    case .skip:
      Log.info("Live Activity disabled for profile, nothing to do", category: .liveActivity)
      return
    case .update:
      Log.info("Live Activity already running for this profile, updating", category: .liveActivity)
      updateSessionActivity(session: session)
      return
    case .end:
      // #249: a switched-in DISABLED profile (or a same-profile activity that should not exist) —
      // tear the stale activity down instead of updating it.
      Log.info("Live Activity disabled for switched-in profile, ending", category: .liveActivity)
      endSessionActivity()
      return
    case .recreate:
      // #249: a DIFFERENT profile — the name is an immutable attribute, so end the old activity
      // (clears currentActivity synchronously; the system end is async) and request a fresh one.
      Log.info("Profile switched, recreating Live Activity for new name", category: .liveActivity)
      endSessionActivity()
      requestActivity(session: session)
      return
    case .start:
      requestActivity(session: session)
      return
    }
  }
```
  Delete the now-obsolete inline blocks (`if currentActivity != nil { updateSessionActivity… }`, the
  mis-placed `enableLiveActivity == false` guard, and the old create block `:81-108`) — their logic
  now lives in `decideAction` + `requestActivity`.

- [ ] **Step 5: Build the whole scheme** (this is a presentation-surface edit with no new unit test):
```
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug -destination 'generic/platform=iOS Simulator' build | xcpretty
```
  Expected: `BUILD SUCCEEDED`. Then re-run G2-1's helper tests to confirm no regression:
```
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/LiveActivityManagerTests | xcpretty
```

- [ ] **Step 6: `swift-format lint --recursive .`** — clean.

- [ ] **Step 7: Commit**
```bash
git add Foqos/Utils/LiveActivityManager.swift
git commit -m "fix(#249): recreate Live Activity on profile switch so the new name shows"
```

#### DEVICE ACCEPTANCE (gate before merge — device-only)

- [ ] **DEVICE GATE (required, no debugger):** start a **manual** session for profile A (Live
  Activity shows A's name), background the app, and let a **scheduled** profile B take over (via the
  monitor extension). On the next foreground / when the switch completes, the Live Activity shows
  **B's name**, not A's. Then repeat the reverse (scheduled → manual). Also verify a switched-in
  profile with Live Activity **disabled** ends the banner rather than leaving A's stale activity up.
  Capture an exported log (real commit SHA, no `+wip`) on the PR.

---

### Mini-plan G — verification summary (whole sub-bundle)

- [ ] **Full suite green** on the booted sim (single boot, UUID destination):
```
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
```
- [ ] **`swift-format lint --recursive .`** clean.
- [ ] **G1 no-regression grep:** `grep -rn "reloadTimelines(ofKind: \"ProfileControlWidget\")"
  Packages/FoqosShared` returns exactly the one default-closure hit in `TimerActivityUtil.swift`;
  the two monitor-extension overrides are unchanged.
- [ ] **G1 DEVICE GATE** (killed-app widget refresh on scheduled start/stop) — logged on the PR.
- [ ] **G2 DEVICE GATE** (manual↔scheduled switch shows the new profile's name; disabled switched-in
  ends the banner) — logged on the PR.
- [ ] **Request code review** (AGENTS.md: review before merge). Reference #238, #249, and epic #263.

#### Out of scope (do NOT do here)
- **G1:** any change to `reconcileAfterWake` or the C2 backstop routing; adding a WidgetKit call
  inside the monitor extension override (the seam lives in `TimerActivityUtil`, which the extension
  already funnels through); reloading per-profile (kind-level reload already covers all profiles).
- **G2:** `updateBreakState`/`updateOneMoreMinuteState` (correctly stay as same-profile updates);
  changing the `message` re-randomization on recreate (acceptable per the brief); any change to the
  two `StrategyManager` switch call sites (the fix is entirely inside `LiveActivityManager`).


---

## Skeptic Pass — Mini-plan G (maintainer-directed, PR #309)

1. *(major, test-compile)* The G1-1 Step 1 spy test constructs `DeviceActivityName(rawValue: …)`, but the file it appends to — `FoqosTests/ScheduleTimerActivityTests.swift` — imports only `FoqosShared` and `XCTest` (verified: `ScheduleTimerActivityTests.swift:1-2`), and `FoqosShared` does **not** `@_exported import DeviceActivity` (grep `@_exported` across `Packages/FoqosShared/Sources/FoqosShared` → zero hits). `DeviceActivityName` is therefore not in scope, and the existing file never names it (no `DeviceActivityName`/`startTimerActivity` usage in the current test — grep → none), so this is the first use. The plan explicitly reasons "it uses plain `import FoqosShared`, and the seam is `public`" and concludes no further import is needed — wrong. As written, the two spy tests fail with `cannot find 'DeviceActivityName' in scope`, which persists past Step 3, so Step 5's "verify PASS / green" never happens. -> Add `import DeviceActivity` to the top of `ScheduleTimerActivityTests.swift` (applied to G1-1 Step 1 above). One line; everything else in the seam/spy design is sound.

2. *(non-issue, reload-storm — maintainer focus)* "Can a burst of DeviceActivity events cause a reload storm?" A burst is possible: each `intervalDidStart`/`intervalDidEnd` routes through `TimerActivityUtil.start/stopTimerActivity` (`DeviceActivityMonitorExtension.swift:34,42`), the `defer` fires exactly one reload per funnel call (`TimerActivityUtil.swift:4,16`), and multiple `DeviceActivityName` intervals (a start+stop pair, several profiles, or C2 backstop cases `TimerActivityUtil.swift:56-59`) can elapse in one wake → N reloads. But `reloadTimelines(ofKind:)` is a whole-kind, idempotent *request* to the WidgetKit daemon, which coalesces rapid same-kind requests and runs the timeline provider at most once per coalesced batch. N-per-wake is bounded, best-effort, and not harmful (a monitor extension fires on scheduled boundaries a handful of times/day — nowhere near the widget reload budget). -> Confirmed sound; the plan's "coalesce per event, not per profile" is the correct altitude. A per-wake debounce/coalesce would be over-engineering against friction-not-DRM proportionality. No plan-body change.

3. *(non-issue, cross-process)* "What happens when the extension calls WidgetCenter while the app is also reloading?" `WidgetCenter.shared` in each process is an XPC proxy to the shared widget daemon; `reloadTimelines` posts a request with no shared mutable state between processes. Concurrent app + extension calls serialize/coalesce at the daemon — benign, no corruption, no race. Grounding confirms the app already calls the identical `reloadTimelines(ofKind: "ProfileControlWidget")` from `StrategyManager.swift:211,843,880,974,1016` and `EmergencyUnblockManager.swift:359`; adding the extension caller is the same operation from another process. -> No concern.

4. *(non-issue, linkage/testability)* WidgetKit is a system framework and is linkable/callable from a `DeviceActivityMonitor` app extension; putting the default seam closure (calling `WidgetCenter`) in `FoqosShared` and importing WidgetKit there is fine — the plan's Step 6 builds every FoqosShared consumer to prove it, with a no-op-default + extension-`init` fallback if linkage ever failed (belt-and-suspenders, appropriately labelled "unexpected"). The spy test genuinely proves the call fires without a device: the seam is a `public` overridable static, the `defer` invokes it synchronously on exit even through the `guard` early-return (constructed name `"ScheduleTimerActivity:<randomUUID>"` resolves a valid `getTimerActivity` but `SharedData.snapshot(for:)` returns nil for the random id → guard returns → `defer` still fires), so `count == 1` holds. `ScheduleTimerActivity.id` is `public` (`ScheduleTimerActivity.swift:5`) and `SharedData.configure(suite:)` runs in `setUp` (`ScheduleTimerActivityTests.swift:10`). -> Sound (subject to finding 1's import).

5. *(minor, ordering — non-issue on inspection)* The G1 `defer` fires the reload at funnel *scope exit* (after `timerActivity.start/stop`), but that is still **before** the extension's subsequent `reconcileAfterWake()` (`DeviceActivityMonitorExtension.swift:35,43`), which may further mutate SharedData/apply restrictions. Because `reloadTimelines` is an async request and the provider reads SharedData at daemon-scheduled execution time — after the synchronous `reconcileAfterWake` has returned — the eventual timeline reflects the final reconciled state. -> Benign; no change. Worth one sentence in the PR's device-gate notes, not a code edit.

6. *(non-issue, unconditional-reload)* Firing the reload on the `guard` early-return (missing snapshot, nothing actually started/stopped) is a deliberate, justified choice (decision (b)): a whole-kind reload is idempotent and cheap, so an occasional redundant request is harmless and avoids state-tracking. -> Correct call; not a defect.

7. *(non-issue, G2 recreate ordering)* The `.recreate` path calls `endSessionActivity()` (clears `currentActivity`/stored ids **synchronously**, `LiveActivityManager.swift:197-198`; system `.end` dispatched async in a `Task`, `:191-194`) then `requestActivity(session:)`. There is no `await` between the synchronous clear and the new `Activity.request`, so no interleaving; the async end captured the OLD id already. Two system activities momentarily coexist (old ending `.immediate`, new requested) — iOS permits multiple activities, so this is benign. The plan's behavioral note is accurate. -> No change.

8. *(non-issue, coverage)* `decideAction`'s 8 tests are genuinely exhaustive over the stated space: `hasCurrentActivity=false` → {enabled→start, disabled→skip} (profile axis irrelevant); `hasCurrentActivity=true` → enabled×{==,≠,nil} = {update, recreate, recreate} and disabled×{==,≠,nil} = {end, end, end}. The `decideAction` body (`guard enableLiveActivity … ; guard hasCurrentActivity … ; currentProfileId == incomingProfileId ? .update : .recreate`) matches all 8 assertions. File-scope `enum LiveActivityAction`/internal `nonisolated static func` are reachable via `@testable import FamilyFoqos` (the codebase standard — 120 files). `BlockedProfiles.id` is `UUID` and `enableLiveActivity` is `Bool` (`BlockedProfiles.swift:10,26`), matching the parameter types. -> Sound.

**Not challenged (the sound core):** the diagnosis of both defects is correct and grounded byte-for-byte — G1: neither `FoqosShared` nor the extensions touch WidgetKit (grep → zero hits), the two `TimerActivityUtil` funnels are the extension's *sole* interval entry points (`DeviceActivityMonitorExtension.swift:34,42`), so the seam gives identical runtime coverage plus a testable seam with zero edits to the untestable extension — strictly better, correctly chosen. G2: `name` is an immutable `ActivityAttribute` not in `ContentState` (`FoqosWidgetLiveActivity.swift:28` vs `:7-26`), the switch hits the `currentActivity != nil` update branch above the mis-placed `enableLiveActivity == false` guard (`LiveActivityManager.swift:70-79`), only the activity **id** is persisted (`:11`), and both switch call sites (`StrategyManager.swift:110,834`) need no change. The pure-helper extraction, profile-id persistence in lockstep with the activity id (clearing in `removeActivityId`), the `.end` fifth case for switched-in-disabled, and the pre-#249-restore→`.recreate` safety fallback are all proportionate and correct. `nonisolated(unsafe) static var` has real precedent in `Foqos/Intents/*` (verified). Every line-number citation checked landed on the cited symbol.

---

## Mini-plan #331 — parent dashboard honesty for old-version children (#331)

> **Tail-bundle position.** This mini-plan implements **third** in the tail bundle (order H → G →
> **#331** → J1+#240), on `main` **after** #302/#301/#298, B2, and D3+E2 have merged. It is the
> newest mini-plan (a V1→V2 upgrade-audit finding, PR #327 scenarios B3/B4, bundled 2026-07-12), so
> its citations are grounded against the then-current `main` — **`e6c3eb2`** ("Fix B2 family command
> and heartbeat plumbing (#325)"), i.e. **B2 / PR #325 is already merged**. Because #325 touches the
> FamilyCommand plumbing and the child's delete-on-process, **Task 331.0 must re-ground every citation
> against whatever `git rev-parse HEAD` reports and reconcile with #325's changes** (the child's
> delete-on-process moved into `LockCodeManager.processCommand`, and command application is now
> idempotent via a persisted ledger — see Task 331.0). All line numbers below were verified against
> `e6c3eb2`; where a Task-0 grep reports a shifted line, use the fresh number.

`#331` is the honesty fix for a V2 parent whose child is still on the App Store V1 build during the
rollout. V1 has family enrollment and lock-code sync — only the **command reader** and **heartbeats**
are V2-only — so `ParentDashboardView` tells two lies:
- **#331a — reset commands report success that never happens.** "Reset Emergency Count" and "Reset
  PIN Attempts" flip to a green "success" checkmark the instant the `FamilyCommand` record **saves**
  to CloudKit (`ParentDashboardView.swift:1114→1118` and `:1154→1158` — BOTH paths), not when the
  child applies it. A V1 child has no command reader, so nothing ever happens; the parent is told it
  did.
- **#331b — an active child shows as no child.** Device Status renders "No Devices" / "Child devices
  will appear here when they activate a profile" (`:550-554`) because it is driven by heartbeats,
  which V1 never sends. An enrolled, actively-blocking V1 child renders as nothing.

The fix is **UI honesty, V2-side only** (no V1 release, no schema change): a reset command shows
"Sent — waiting for child to confirm", flipping to confirmed only when the child **deletes the
command record on processing** (V2 children already delete-on-process — the delete is the truthful
signal); and the empty Device-Status copy acknowledges that a child on an older app version won't
appear. Implement in order 331.1 → 331.2 → 331.3 → 331.4, each a self-contained change with its own
`(#331)` commit scope. **Not blocked on #307** — the truth sources are the command record and the
heartbeat list, not the CKSyncEngine `state` field.

**Global constraints that bind every task here** (from `AGENTS.md`): NEVER force-commit/amend — new
commits only; request code review before merge. `swift-format` clean, 2-space indent, ~100–120 col.
Use `Log`, never `print`; never log lock codes / personal identifiers (UUIDs, `userRecordName`
opaque CK ids, timestamps, user-defined profile names are acceptable). Lock-check gate is
`currentMode == .child`, never `!= .parent` (not exercised here — the reset menu already gates on
`member.role == .child`). Pin time in tests. Test simulator: boot an iPhone 17 **once by UUID**
(never by device name) and reuse it:
```
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/<Class> | xcpretty
```

### Problem (device-observed, V1-child + V2-parent pair)

Both defects only appear in a **mixed-version family** (V2 parent, V1 child) — #326's single-device
plan will NOT reproduce them. On such a pair:
1. The parent opens the family dashboard, taps **Reset Emergency Count** (or **Reset PIN Attempts**),
   and immediately sees the green success indicator — but the child's emergency count / PIN throttle
   is never reset, because the V1 build has no code that reads `FamilyCommand` records.
2. Device Status shows the empty "No Devices" card even though the child is enrolled and actively
   blocking, because the card is populated from heartbeats and V1 never emits one.

### Grounding (verified at `e6c3eb2`)

All in `Foqos/Views/Parent/ParentDashboardView.swift` (`import CloudKit` + `import SwiftUI`; `:1`,
`:2`), plus the FamilyCommand CloudKit seam.

**#331a — the two reset paths (in `struct FamilyMemberCard`, `:993`).** Both funnels treat a
successful CKRecord save as success:
```swift
:1096  private func resetEmergencyCount() {
:1105    isResettingEmergency = true
:1114        try await CloudKitManager.shared.sendCommand(command)
:1117          isResettingEmergency = false
:1118          showResetSuccess = true          // ← LIE: save ≠ applied by the child (#331a)
:1136  private func resetLockCodeThrottle() {
:1145    isResettingThrottle = true
:1154        try await CloudKitManager.shared.sendCommand(command)
:1157          isResettingThrottle = false
:1158          showResetSuccess = true          // ← same LIE on the second path
```
The shared status state lives at `:998-1002` (`isResettingEmergency`, `isResettingThrottle`,
`showResetSuccess`, `showResetError`, `resetErrorMessage`). The Menu label renders the state at
`:1060-1071`: `ProgressView` while resetting (`:1060`), a **green `checkmark.circle.fill`** while
`showResetSuccess` (`:1063-1065`), else `ellipsis.circle`. On save success each funnel sets
`showResetSuccess = true`, sleeps 2 s, then `showResetSuccess = false` (`:1118-1124`, `:1158-1164`)
— i.e. a transient green tick that claims the reset happened. The error path (`:1126-1131` /
`:1166-1171`) is already honest (it surfaces the real error via the `.alert` at `:1073-1077`) and is
**out of scope**.

**#331b — the empty Device-Status copy (in `deviceStatusSection`, `:538`).** Driven by heartbeats:
```swift
:550  if heartbeatManager.monitoredDevices.isEmpty {
:551    EmptyMemberCard(
:552      icon: "antenna.radiowaves.left.and.right",
:553      title: "No Devices",
:554      description: "Child devices will appear here when they activate a profile"
```
`EmptyMemberCard` (`:933`) is a dumb presentation component taking `icon`/`title`/`description` —
the copy is passed in here, so only these strings change.

**The confirmation signal — the child deletes the command record on processing.** `sendCommand`
saves the record to the parent's **private** DB in `policyZoneID` with a **deterministic**
`recordName` (`FamilyCommand.recordName(commandType:targetChildId:parentId:)`,
`FamilyCommand.swift:35`) — `CloudKitNetworkService+Commands.swift:19-42` (`privateDatabase.save`,
`:28`). A V2 child processes and then **deletes** it: `LockCodeManager.processCommand` (`:366`) calls
`cloudKitManager.deleteCommand(command)` (`:374`), after `applyCommandIfNeeded` (`:351`, an
idempotent persisted-ledger apply added by #325). `deleteCommand`
(`CloudKitNetworkService+Commands.swift:83-104`) removes it from `sharedDatabase` — the participant
(child) side of the same shared zone — which propagates the delete back to the owner's (parent's)
private DB. So the parent can detect "processed" by re-reading its own record: present ⇒ still
pending; `CKError.unknownItem` ⇒ the child deleted it ⇒ applied. `CloudKitManager.sendCommand`/
`deleteCommand` delegate to the network service (`CloudKitManager.swift:121`, `:129`);
`policyZoneID` and `privateDatabase` are the same instance members `sendCommand` already uses
(`CloudKitNetworkService+Commands.swift:25,28`).

> **#325 reconciliation (mandatory to re-check in Task 331.0).** The issue text cited the child's
> delete-on-process at `LockCodeManager.swift:339`; at `e6c3eb2` (post-#325) `:339` is the
> `applyCommand` switch case (`case .resetEmergencyCount:`, `:337-345`) and the **actual
> `deleteCommand` moved to `processCommand:374`**, with idempotence provided by
> `applyCommandIfNeeded` (`:351`). The confirmation SIGNAL this mini-plan depends on — the command
> **record deletion** — is unchanged by #325; only its call site moved. Task 331.0 re-verifies this
> by symbol.

Nearest test file for structure reference: `FoqosTests/FamilyCommandSaveOutcomeTests.swift`
(`import CloudKit` + `import XCTest` + `@testable import FamilyFoqos`, `@MainActor`).

### MAINTAINER DECISION — MD-331 (ESCALATE; recommend Option A)

The two lies and their honest copy are fully determined (no fork) — **331.1/331.2/331.4 proceed
unconditionally**. The one genuine fork is **how the parent detects the child's confirmation** (the
"flip to confirmed"), which trades UI reactivity against added infrastructure:

- **Option A (RECOMMENDED): a bounded client-side poll after send.** After a successful save, show
  "Sent — waiting for child to confirm", then re-read the command record a bounded number of times
  (Task 331.3, ~5 × 3 s ≈ 15 s while the card is on screen); flip to "Confirmed by child" on the
  first `unknownItem`. A V1 child never deletes the record, so the status honestly stays "waiting"
  (never a false confirmation). No schema, no subscription lifecycle.
- **Option B: ship the honesty COPY only** (331.1 + 331.2 + 331.4) and **drop the confirmation poll**
  (skip 331.3). The reset shows "Sent — waiting for child to confirm" and never auto-flips to
  "Confirmed". This alone removes **both** lies — the only loss is the positive confirmation signal.
  Lowest risk, least code.
- **Option C: a `CKSubscription` on `FamilyCommand` deletions** so the parent flips reactively with
  no polling. More infrastructure (subscription registration + push handling) for a transient UI
  nicety.

**Recommendation: A.** The bounded poll is the proportionate way to restore a *truthful* positive
signal without new persistent infrastructure, and its failure mode is safe (a V1 child simply never
confirms). **Maintainer, please confirm A vs B vs C.** The tasks below implement **A** and are the
default that proceeds; if the maintainer picks **B**, skip Task 331.3 and its network method; if
**C**, replace Task 331.3's poll with a subscription (out of the current scope — a separate follow-up
seam). This is UI honesty, **not** a sync-protocol change — nothing here makes V1 heartbeat or read
commands (impossible without a V1 release, which is ruled out).

### Task 331.0: Citation refresh (MANDATORY — do this first, no code)

- [ ] **Step 1: Record the base SHA.** `git rev-parse HEAD` — expect `e6c3eb2` (the B2/#325-merged
  tip this refresh grounded against), or a **newer** tip since this bundle ships after the other
  mini-plans. Record it in the Task 331.1 commit body. If it differs, re-run every grep below and
  reconcile line numbers before writing code.
- [ ] **Step 2: Confirm the two reset "success-on-save" sites by symbol:**
```bash
grep -nF -e 'private func resetEmergencyCount()' -e 'private func resetLockCodeThrottle()' \
  -e 'try await CloudKitManager.shared.sendCommand(command)' \
  -e 'showResetSuccess = true' -e 'checkmark.circle.fill' \
  Foqos/Views/Parent/ParentDashboardView.swift
```
  Expected: the two funnels (`~:1096`, `~:1136`), two `sendCommand` calls (`~:1114`, `~:1154`), two
  `showResetSuccess = true` (`~:1118`, `~:1158`), and the green-tick label (`~:1063`).
- [ ] **Step 3: Confirm the empty Device-Status copy by symbol:**
```bash
grep -nF -e 'private var deviceStatusSection' -e 'heartbeatManager.monitoredDevices.isEmpty' \
  -e 'title: "No Devices"' \
  -e 'Child devices will appear here when they activate a profile' \
  Foqos/Views/Parent/ParentDashboardView.swift
```
  Expected: `deviceStatusSection` (`~:538`), the `.isEmpty` gate (`~:550`), and the two copy strings
  (`~:553`, `~:554`).
- [ ] **Step 4: Reconcile the confirmation signal with #325 by symbol** (the delete moved; the signal
  did not):
```bash
grep -nF -e 'func processCommand' -e 'cloudKitManager.deleteCommand(command)' \
  -e 'func applyCommandIfNeeded' -e 'func applyCommand' Foqos/Utils/LockCodeManager.swift
grep -nF -e 'func sendCommand' -e 'func deleteCommand' -e 'privateDatabase.save' \
  -e 'policyZoneID' -e 'static func recordName' \
  Foqos/CloudKit/CloudKitNetworkService+Commands.swift Foqos/Models/FamilyCommand.swift
grep -nF -e 'func sendCommand' -e 'func deleteCommand' Foqos/CloudKit/CloudKitManager.swift
```
  Assert: the child still deletes on process (`processCommand` → `deleteCommand`), `sendCommand`
  still saves to `privateDatabase` in `policyZoneID` with the deterministic `recordName`, and the
  `CloudKitManager` wrappers exist. If `#325`'s refactor changed the record id shape or the DB the
  command is saved to, adjust Task 331.3's probe to match (it must query the **same** DB + zone +
  recordName `sendCommand` writes).

### Task 331.1: Pure reset-command status model + honest copy (TDD)

**Files:**
- Create: `Foqos/Views/Parent/ParentResetCommandStatus.swift`
- Test: **create** `FoqosTests/ParentResetCommandStatusTests.swift`

**Interfaces:**
- Produces: `enum ParentResetCommandStatus: Equatable { case idle, awaitingChild, confirmed }` with
  the pure decisions `static let afterSuccessfulSave` (== `.awaitingChild`) and
  `static func afterConfirmationProbe(commandStillPending: Bool) -> ParentResetCommandStatus`, plus
  `var displayText: String?`. Consumed by `FamilyMemberCard` (Task 331.2) and the confirmation poll
  (Task 331.3). Pure over value inputs — no CloudKit, no SwiftUI — so it is exhaustively unit-testable.

- [ ] **Step 1: Write the failing tests** (create `FoqosTests/ParentResetCommandStatusTests.swift`,
  mirroring `FamilyCommandSaveOutcomeTests` structure):
```swift
import XCTest

@testable import FamilyFoqos

final class ParentResetCommandStatusTests: XCTestCase {
  // #331a: a successful CloudKit SAVE only queues the command — a V1 child never reads it — so
  // save-success must map to "awaiting", NEVER to "confirmed".
  func testAfterSuccessfulSave_IsAwaitingChild_NotConfirmed() {
    XCTAssertEqual(ParentResetCommandStatus.afterSuccessfulSave, .awaitingChild)
    XCTAssertNotEqual(ParentResetCommandStatus.afterSuccessfulSave, .confirmed)
  }

  // The child confirms by DELETING the command record; while it still exists we keep waiting.
  func testConfirmationProbe_StillPending_IsAwaitingChild() {
    XCTAssertEqual(
      ParentResetCommandStatus.afterConfirmationProbe(commandStillPending: true), .awaitingChild)
  }

  // Record gone (unknownItem) ⇒ the child processed + deleted it ⇒ confirmed.
  func testConfirmationProbe_Gone_IsConfirmed() {
    XCTAssertEqual(
      ParentResetCommandStatus.afterConfirmationProbe(commandStillPending: false), .confirmed)
  }

  func testDisplayText_Awaiting_IsHonestAndNotSuccess() {
    XCTAssertEqual(
      ParentResetCommandStatus.awaitingChild.displayText, "Sent — waiting for child to confirm")
    XCTAssertFalse(
      ParentResetCommandStatus.awaitingChild.displayText!.lowercased().contains("success"),
      "must not claim success at save time (#331a)")
  }

  func testDisplayText_Confirmed_And_Idle() {
    XCTAssertEqual(ParentResetCommandStatus.confirmed.displayText, "Confirmed by child")
    XCTAssertNil(ParentResetCommandStatus.idle.displayText)
  }
}
```
- [ ] **Step 2: Run → FAIL** (`-only-testing:FoqosTests/ParentResetCommandStatusTests`): `cannot find
  'ParentResetCommandStatus' in scope`.
- [ ] **Step 3: Implement** (create `Foqos/Views/Parent/ParentResetCommandStatus.swift`):
```swift
import Foundation

/// #331: honest status of a parent→child reset command on the family dashboard. Saving the
/// `FamilyCommand` record to CloudKit only QUEUES it — a V1 child has no command reader and will
/// never process it — so a successful save must NOT claim the reset happened. Confirmation comes
/// only when the child DELETES the command record on processing
/// (`LockCodeManager.processCommand` → `deleteCommand`). Pure value type; unit-testable.
enum ParentResetCommandStatus: Equatable {
  case idle           // no reset in flight (failures use the existing error alert)
  case awaitingChild  // command saved to CloudKit; waiting for the child to process + delete it
  case confirmed      // the child deleted the command record ⇒ the reset was applied

  /// A successful save maps here, NEVER to `.confirmed` (#331a).
  static let afterSuccessfulSave: ParentResetCommandStatus = .awaitingChild

  /// The child confirms by deleting the command record; `false` (CKError.unknownItem) ⇒ processed.
  static func afterConfirmationProbe(commandStillPending: Bool) -> ParentResetCommandStatus {
    commandStillPending ? .awaitingChild : .confirmed
  }

  /// User-facing copy for the family-member card. `nil` renders nothing.
  var displayText: String? {
    switch self {
    case .idle: return nil
    case .awaitingChild: return "Sent — waiting for child to confirm"
    case .confirmed: return "Confirmed by child"
    }
  }
}
```
- [ ] **Step 4: Run → PASS** (`-only-testing:FoqosTests/ParentResetCommandStatusTests`).
- [ ] **Step 5: Commit**
```bash
git add Foqos/Views/Parent/ParentResetCommandStatus.swift FoqosTests/ParentResetCommandStatusTests.swift
git commit -m "feat(#331): pure ParentResetCommandStatus model + honest reset copy"
```

### Task 331.2: Wire the honest status into both reset paths (replace the save-time success)

**Files:**
- Modify: `Foqos/Views/Parent/ParentDashboardView.swift` (`FamilyMemberCard` — state `:1000`, label
  `:1060-1071`, both reset funnels `:1114-1124` / `:1154-1164`)

**Interfaces:**
- Consumes: `ParentResetCommandStatus` (Task 331.1).

> `FamilyMemberCard` is a SwiftUI presentation surface — the **decision** lives in the pure model
> (tested in 331.1); these steps are exact wiring, verified by compile + the 331.5 device gate
> (this mirrors how Mini-plan G handles view-layer changes: pure helper is unit-tested, the SwiftUI
> wiring is code-inspection + a device row). The `isResettingEmergency`/`isResettingThrottle`
> spinners and the existing error `.alert` are **retained unchanged** — only the false save-time
> "success" is replaced.

- [ ] **Step 1: Replace the `showResetSuccess` boolean with the status enum** (`:1000`):
```swift
  @State private var resetStatus: ParentResetCommandStatus = .idle
```
  (Delete `@State private var showResetSuccess = false`.)
- [ ] **Step 2: Render the honest status in the Menu label** (`:1060-1071`) — keep the resetting
  spinner; replace the green-tick-on-save with status-driven icons, and expose the copy to
  VoiceOver:
```swift
        if isResettingEmergency || isResettingThrottle {
          ProgressView()
            .scaleEffect(0.8)
        } else {
          switch resetStatus {
          case .awaitingChild:
            Image(systemName: "paperplane.circle")
              .foregroundColor(.secondary)
          case .confirmed:
            Image(systemName: "checkmark.circle.fill")
              .foregroundColor(.green)
          case .idle:
            Image(systemName: "ellipsis.circle")
              .foregroundColor(.secondary)
          }
        }
```
  Add `.accessibilityLabel(resetStatus.displayText ?? "More")` to the Menu label.
- [ ] **Step 3: Surface the honest copy for sighted users** — add a caption in the member row's
  leading `VStack` (below the `Added <date>` text, `~:1027`):
```swift
        if let statusText = resetStatus.displayText {
          Text(statusText)
            .font(.caption2)
            .foregroundColor(resetStatus == .confirmed ? .green : .secondary)
        }
```
- [ ] **Step 4: Fix `resetEmergencyCount()`** (`:1114-1124`) — on save success set the honest
  "awaiting" status instead of the false success tick, and (Option A) kick off the confirmation poll
  (added in Task 331.3). Clear stale status when a reset starts:
```swift
    resetStatus = .idle
    isResettingEmergency = true

    Task {
      do {
        let command = FamilyCommand(
          commandType: .resetEmergencyCount,
          targetChildId: member.userRecordName,
          createdBy: currentUserRecordName
        )
        try await CloudKitManager.shared.sendCommand(command)

        await MainActor.run {
          isResettingEmergency = false
          resetStatus = .afterSuccessfulSave      // #331a: "Sent — waiting for child to confirm"
        }
        await pollForConfirmation(command)        // Task 331.3 (Option A); omit under MD-331 Option B
      } catch {
        // Failure path unchanged — the existing error alert is already honest.
        ...
      }
    }
```
  Delete the old `showResetSuccess = true` / `try? await Task.sleep(2s)` / `showResetSuccess = false`
  block (`:1118-1124`).
- [ ] **Step 5: Apply the identical change to `resetLockCodeThrottle()`** (`:1154-1164`) with
  `commandType: .resetLockCodeThrottle` and `isResettingThrottle`.
- [ ] **Step 6: Build** (view edits, no direct unit test):
```
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug -destination 'generic/platform=iOS Simulator' build | xcpretty
```
  Expected: `BUILD SUCCEEDED`. Then confirm the save-time lie is gone:
```bash
grep -nF -e 'showResetSuccess' Foqos/Views/Parent/ParentDashboardView.swift
```
  Expected: **nothing** (all references replaced by `resetStatus`).
- [ ] **Step 7: Commit**
```bash
git add Foqos/Views/Parent/ParentDashboardView.swift
git commit -m "fix(#331): reset commands show 'waiting for child to confirm', not save-time success"
```

### Task 331.3: Confirmation probe + bounded poll (implements MD-331 Option A)

> Ships **Option A** (recommended). **Skip this whole task under MD-331 Option B** (honesty copy
> only — the reset then stays "Sent — waiting for child to confirm" and never auto-confirms). Under
> **Option C**, replace the poll with a `CKSubscription` (separate follow-up seam).

**Files:**
- Modify: `Foqos/CloudKit/CloudKitNetworkService+Commands.swift` (add `commandIsPending`)
- Modify: `Foqos/CloudKit/CloudKitManager.swift` (add the delegating wrapper)
- Modify: `Foqos/Views/Parent/ParentDashboardView.swift` (add `pollForConfirmation` to
  `FamilyMemberCard`)

**Interfaces:**
- Produces: `CloudKitNetworkService.commandIsPending(_:) async throws -> Bool` and its
  `CloudKitManager` wrapper. Consumed by `pollForConfirmation`, which feeds
  `ParentResetCommandStatus.afterConfirmationProbe`.

> There is no unit test for the probe or the poll — both are CloudKit / async-timing surfaces
> (`CKDatabase.record(for:)` has no simulator seam), exactly like Mini-plan G's `WidgetCenter`
> reload. The **decision** each feeds (`afterConfirmationProbe`) is tested in 331.1; the probe wiring
> is verified by compile + the 331.5 device gate with a real V2 child (which deletes the record) vs a
> V1 child (which never does).

- [ ] **Step 1: Add the probe** to `CloudKitNetworkService+Commands.swift` — re-read the parent's own
  queued record from the **same DB + zone + recordName** `sendCommand` wrote (`:25-28`):
```swift
  /// #331: true while the parent's queued command record still exists in the private DB. A V2 child
  /// DELETES it on processing (LockCodeManager.processCommand → deleteCommand), so `false`
  /// (CKError.unknownItem) is the parent's honest confirmation that the reset was applied. A V1
  /// child never deletes it ⇒ this stays true and the UI honestly keeps waiting.
  func commandIsPending(_ command: FamilyCommand) async throws -> Bool {
    let recordID = CKRecord.ID(
      recordName: FamilyCommand.recordName(
        commandType: command.commandType, targetChildId: command.targetChildId,
        parentId: command.createdBy),
      zoneID: policyZoneID)
    do {
      _ = try await privateDatabase.record(for: recordID)
      return true
    } catch let error as CKError where error.code == .unknownItem {
      return false
    }
  }
```
- [ ] **Step 2: Add the `CloudKitManager` wrapper** (next to `sendCommand`, `:121`):
```swift
  func commandIsPending(_ command: FamilyCommand) async throws -> Bool {
    try await networkService.commandIsPending(command)
  }
```
- [ ] **Step 3: Add the bounded poll** to `FamilyMemberCard`:
```swift
  /// #331 (MD-331 Option A): after a reset command is queued, poll a bounded number of times for the
  /// child to delete the record (its processing signal). A V1 child never confirms, so the status
  /// honestly stays `.awaitingChild` (never a false confirmation). Stops on the first confirmation,
  /// on a probe error, or when the card leaves the screen (the Task is cancelled).
  private func pollForConfirmation(_ command: FamilyCommand) async {
    for _ in 0..<5 {
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      let stillPending: Bool
      do {
        stillPending = try await CloudKitManager.shared.commandIsPending(command)
      } catch {
        return  // transient probe error — leave the honest "waiting" status in place
      }
      let next = ParentResetCommandStatus.afterConfirmationProbe(commandStillPending: stillPending)
      await MainActor.run { resetStatus = next }
      if next == .confirmed { return }
    }
  }
```
- [ ] **Step 4: Build the whole scheme** (network + view edits):
```
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug -destination 'generic/platform=iOS Simulator' build | xcpretty
```
  Expected: `BUILD SUCCEEDED`. Then re-run 331.1's model tests to confirm no regression:
```
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' -only-testing:FoqosTests/ParentResetCommandStatusTests | xcpretty
```
- [ ] **Step 5: Commit**
```bash
git add Foqos/CloudKit/CloudKitNetworkService+Commands.swift Foqos/CloudKit/CloudKitManager.swift \
        Foqos/Views/Parent/ParentDashboardView.swift
git commit -m "feat(#331): confirm reset commands only when the child deletes the command record"
```

### Task 331.4: Honest empty Device-Status copy (#331b)

**Files:**
- Modify: `Foqos/Views/Parent/ParentDashboardView.swift` (`deviceStatusSection`, `:551-554`)

**Interfaces:** none (SwiftUI copy). Like Mini-plan J1's prose, this is a constant string in a view
with no runtime seam — verified by grep + code-inspection, not a brittle string-assert test.

- [ ] **Step 1: Rewrite the empty-state copy** to acknowledge older app versions (`:551-554`):
```swift
        EmptyMemberCard(
          icon: "antenna.radiowaves.left.and.right",
          title: "No devices reporting",
          description:
            "Devices appear here once they report status. A child on an older app version won't "
            + "appear even while actively blocking — update their app to see it here."
        )
```
- [ ] **Step 2: Verify the old copy is gone:**
```bash
grep -nF -e 'title: "No Devices"' \
  -e 'Child devices will appear here when they activate a profile' \
  Foqos/Views/Parent/ParentDashboardView.swift
```
  Expected: **nothing** (both old strings replaced).
- [ ] **Step 3: Build + `swift-format lint`:**
```
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug -destination 'generic/platform=iOS Simulator' build | xcpretty
swift-format lint Foqos/Views/Parent/ParentDashboardView.swift
```
  Expected: `BUILD SUCCEEDED`, no lint output.
- [ ] **Step 4: Commit**
```bash
git add Foqos/Views/Parent/ParentDashboardView.swift
git commit -m "fix(#331): honest empty Device Status copy for older-version children"
```

### Task 331.5: Device / integration acceptance (gate before merge — mixed-version pair)

- [ ] **DEVICE GATE (required — V1-child + V2-parent pair; #326's single-device plan will NOT
  reproduce this).** On a V2 **parent** device and a **V1** child on the same iCloud family account,
  with the child enrolled and actively blocking a profile:
  1. **#331b:** open the parent dashboard — Device Status shows the new honest empty copy ("No
     devices reporting … a child on an older app version won't appear …"), not "No Devices … when
     they activate a profile".
  2. **#331a:** tap **Reset Emergency Count** — the card shows **"Sent — waiting for child to
     confirm"** (paperplane icon), and it **never** flips to the green "Confirmed by child" tick
     (the V1 child has no command reader). Repeat for **Reset PIN Attempts**.
  3. **Positive path (verifies the confirmation probe):** pair the V2 parent with a **V2** child;
     tap a reset; after the child foregrounds and processes (deleting the command record), the
     parent flips to **"Confirmed by child"** within the poll window.
  Attach screenshots (both empty-state copy and the "waiting" reset state) and an exported log (real
  commit SHA, no `+wip`) to the PR.
- [ ] **CODE-INSPECTION acceptance:** confirm no V1-side change was made (no V1 release exists) and
  the child-side apply/delete logic (`LockCodeManager` / #325) was left untouched — this mini-plan is
  V2 parent-UI + one read-only CloudKit probe only.

### Mini-plan #331 — final checks (before requesting review)

- [ ] **Full suite green** on the booted sim (single UUID boot):
```
xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -destination 'platform=iOS Simulator,id=<UUID>' | xcpretty
```
- [ ] **`swift-format lint --recursive .` clean.**
- [ ] **Honesty tripwire greps return nothing:**
```bash
grep -nF 'showResetSuccess' Foqos/Views/Parent/ParentDashboardView.swift                       # #331a
grep -nF -e 'title: "No Devices"' -e 'when they activate a profile' Foqos/Views/Parent/ParentDashboardView.swift  # #331b
```
  Both must return **nothing**.
- [ ] **331.5 DEVICE GATE** (mixed-version pair: honest empty copy + "waiting" reset that never
  falsely confirms; V2-child positive confirmation) — logged on the PR.
- [ ] **Request code review** (AGENTS.md: review before merge). Reference #331 and epic #263. Note
  MD-331 (Option A recommended) awaits maintainer confirmation; 331.1/331.2/331.4 are unconditional.

### Out of scope (do NOT do here)
- Any **V1-side** change or release (ruled out 2026-07-12 — all mixed-version remediation is
  V2-side); anything that makes V1 heartbeat or read commands (impossible without a V1 release).
- The reset **error** path / the existing error `.alert` (already honest — surfaces the real error).
- The child-side command apply/delete (`LockCodeManager.processCommand` / `applyCommandIfNeeded`) —
  owned by #325; this mini-plan only reads whether the record still exists.
- Any `FamilyCommand` **schema** change; changing `sendCommand`/`deleteCommand`/`fetchPendingCommands`
  behaviour; a `CKSubscription` for command deletion (only under MD-331 Option C, as a follow-up).
- Heartbeat protocol changes (`HeartbeatManager`) — #331b is copy-only; making V1 appear in Device
  Status is impossible without a V1 heartbeat emitter.

---

## Skeptic Pass — Mini-plan #331 (refresh, PR #327)

Grounded at `e6c3eb2` (B2/#325 merged). Attacked hardest: the confirmation-probe CloudKit semantics
and the #325 reconciliation.

1. *(major, CloudKit-semantics — accept with a safe failure mode)* **The confirmation probe assumes a
   participant (child) deleting the shared record propagates back to the owner's (parent's) private
   DB, so `privateDatabase.record(for:)` eventually returns `unknownItem`.** `sendCommand` saves to
   the parent's `privateDatabase` in `policyZoneID` (`CloudKitNetworkService+Commands.swift:25-28`);
   the V2 child deletes via `sharedDatabase.deleteRecord` (`:93`), i.e. the participant side of the
   same shared zone. In CloudKit, a participant with write access deleting a record in a shared zone
   removes it from the owner's private DB — so the probe is sound and the parent will see
   `unknownItem`. **If that semantics were ever different** (e.g. a retained tombstone), the probe
   would simply never observe `unknownItem` and the status would stay `.awaitingChild` — a **safe**
   failure (the parent is told "waiting", never a false "confirmed"). -> Accept; the positive path is
   proven by the 331.5 device gate with a real V2 child. No false-confirmation risk regardless.
2. *(minor, #325 reconciliation — handled)* The issue cited the child delete at
   `LockCodeManager.swift:339`; at `e6c3eb2` that line is the `applyCommand` switch case and the
   actual `deleteCommand` moved to `processCommand:374` (with an idempotent persisted ledger via
   `applyCommandIfNeeded:351`). The **signal** #331 depends on — the record deletion — is unchanged;
   only the call site moved. Task 331.0 Step 4 re-verifies by symbol and adjusts the probe if #325
   changed the saved record's DB/zone/recordName. -> Covered.
3. *(minor, non-issue)* **The bounded poll leaks no timer.** `pollForConfirmation` is an `async`
   sequence of at most 5 × 3 s sleeps started from the card's `Task`; if the parent dismisses the
   sheet, SwiftUI cancels the owning `Task` and the loop's `Task.sleep` throws → the `try?` swallows
   it and the loop exits. No retained `Timer`, no background work. -> Sound.
4. *(minor, non-issue)* **The probe hits the same DB/zone/recordName `sendCommand` writes.** Both use
   `FamilyCommand.recordName(commandType:targetChildId:parentId:)` in `policyZoneID` against
   `privateDatabase` (`:25-28`), so the id matches deterministically — the probe cannot miss the
   record it just queued. `#222`'s deterministic recordName (already relied on for `.alreadyPending`)
   guarantees this. -> Confirmed.
5. *(minor, testability — consistent with the plan)* The empty-state copy (#331b) is a constant
   string in a SwiftUI view; a "README-style" string-assert test would be brittle and low-value, so
   it is verified by grep + code-inspection — exactly the testability posture Mini-plan J1 states for
   docs prose and Mini-plan G2-2 states for presentation surfaces. The **decisions** that carry
   behaviour (`afterSuccessfulSave`, `afterConfirmationProbe`, `displayText`) are all pure and
   exhaustively unit-tested in 331.1. -> No new testing approach invented.
6. *(non-issue, #307 independence)* #331's truth sources are the command **record** (deleted by the
   child) and the heartbeat list — not the CKSyncEngine `state` field — so it is correctly **not
   blocked on #307**, matching the issue. -> Confirmed.

**Not challenged (the sound core):** both lies are real and grounded byte-for-byte — the reset
funnels set `showResetSuccess = true` at save time (`ParentDashboardView.swift:1118`, `:1158`) and
the empty Device-Status card claims children "will appear here when they activate a profile"
(`:554`) while V1 never heartbeats. The fix is UI honesty + a bounded read-only confirmation probe:
no schema, no V1 release, no child-side change, file-disjoint from H (`CloudKitNetworkService+
FamilyMembers.swift` — a **different** `CloudKitNetworkService` extension file), G, J1, and #240. The
pure `ParentResetCommandStatus` seam mirrors G's `decideAction`/`reloadWidgets` pattern (tested
decision + code-inspected wiring + device gate). MD-331's confirmation-mechanism fork is correctly
escalated with a proportionate recommendation (bounded poll), and 331.1/331.2/331.4 ship regardless
of the ruling so implementation is never blocked.

---

## Mini-plan J1 — README corrections (#253, #254) — DOCS ONLY

This mini-plan makes **two documentation-only fixes to `README.md`** — no runtime source, no schema, no tests-under-test. It has two independent sub-parts, each self-contained:

- **J1a · #253** — the README advertises the wrong minimum OS / toolchain (iOS 17.6, Xcode 15, Swift 5.9) and carries three placeholder `TODO` hyperlinks.
- **J1b · #254** — the "Blocking Strategies" section documents the **removed V1 strategy-picker system** (7 strategy classes + `physicalUnblock*`) as if it were the current configuration model, instead of the V2 **start-triggers / stop-conditions** model.

**Bundle position & drift warning.** In the tail bundle this mini-plan implements **LAST** (order: H → G → #331 → J1+#240), *after* #302/#301/#298, B2, and D3+E2. Those bundles touch **Swift** sources, not `README.md` or `FamilyFoqos.xcodeproj/project.pbxproj`, so drift on *these* two files is unlikely — but line numbers are still **provisional**. Each sub-part opens with a mandatory Task 0 that re-derives every citation by **fixed-string grep** and records the SHA it verified against. Do not trust the line numbers printed below.

**Global constraints that apply here** (subset of the bundle's, copied per house rule):
- **Base commit:** `main = e7ac000`. Verified in the worktree at authoring time: `git rev-parse HEAD` → `e7ac00027953…` on branch `worktree-plan-263-tail-ghj240` — i.e. HEAD matches the orchestrator's stated base. Task 0 re-records the real SHA at implementation time (this bundle ships last, so a later tip is possible); re-derive against whatever `git rev-parse HEAD` reports.
- **NEVER force-commit or amend.** New commits only. **Request code review before merging.**
- **`swift-format` does not touch `.md` files** — no formatter step applies here; the pre-commit hook that rejects raw `@Query` is Swift-only and irrelevant to this mini-plan.
- Commit with conventional-commit type `docs(#N)` scoped to the issue.

**TESTABILITY WAIVER (mandatory statement, both sub-parts).** These changes are **prose in a Markdown file with no runtime seam** — there is no function, view, or value type to exercise, and a "README-parsing" unit test (e.g. asserting the file contains the string `iOS 18.6+`) would be **brittle and low-value**: it would break on any innocuous rewording and proves nothing about behaviour. The house TDD "write a failing test first" criterion is therefore **explicitly waived** for J1. The substitute verification is, per sub-part, a **self-review CLAIMS-vs-PROJECT-SETTINGS checklist** (a final task) that diffs each README claim against the authoritative source (`project.pbxproj` for J1a, the models for J1b). State this plainly in the PR: "J1 acceptance is documentation self-review against project settings; no unit test (docs prose has no runtime seam)."

---

### J1a · #253 — README states the wrong minimum OS / toolchain, and has three `TODO` links

#### Problem

`README.md` advertises minimum requirements that are **below** the project's real build settings, which will mislead a contributor into trying to build on an unsupported toolchain (Swift 6 code will not compile under Xcode 15 / Swift 5.9):

- `README.md:39` — `- iOS 17.6+`
- `README.md:74` — `- Xcode 15.0+`
- `README.md:75` — `- iOS 17.0+ SDK`
- `README.md:76` — `- Swift 5.9+`

It also carries three placeholder hyperlinks pointing at the literal string `TODO`:
- `README.md:5` — `<h1 align="center"><a href="TODO">Family Foqos</a></h1>`
- `README.md:47` — `1. Download Foqos from the [App Store](TODO)`
- `README.md:205` — `- [App Store](TODO)`

#### Grounding (verified at worktree HEAD `e7ac000`)

The README's current claims (fixed-string grep, real line numbers):

```
$ grep -nF -e 'iOS 17.6+' -e 'Xcode 15.0+' -e 'iOS 17.0+ SDK' -e 'Swift 5.9+' \
    -e 'href="TODO"' -e '[App Store](TODO)' README.md
5:<h1 align="center"><a href="TODO">Family Foqos</a></h1>
39:- iOS 17.6+
47:1. Download Foqos from the [App Store](TODO)
74:- Xcode 15.0+
75:- iOS 17.0+ SDK
76:- Swift 5.9+
205:- [App Store](TODO)
```

The **authoritative** minimums from `FamilyFoqos.xcodeproj/project.pbxproj` — a **single** deployment target and Swift version, with no lower override anywhere:

```
$ grep -n "IPHONEOS_DEPLOYMENT_TARGET\|SWIFT_VERSION" FamilyFoqos.xcodeproj/project.pbxproj \
    | sort -t= -k2 -u
654:				IPHONEOS_DEPLOYMENT_TARGET = 18.6;
671:				SWIFT_VERSION = 6.0;
$ grep -c "IPHONEOS_DEPLOYMENT_TARGET = 18.6;" FamilyFoqos.xcodeproj/project.pbxproj   # 12
$ grep -c "SWIFT_VERSION = 6.0;"                FamilyFoqos.xcodeproj/project.pbxproj   # 14
```

`sort -u` collapses all occurrences to exactly `IPHONEOS_DEPLOYMENT_TARGET = 18.6;` and `SWIFT_VERSION = 6.0;` — i.e. **every** build configuration targets iOS 18.6 / Swift 6.0 (12 and 14 occurrences respectively). Swift 6.0's language mode requires **Xcode 16 or newer** (Swift 6 shipped with Xcode 16; Xcode 15 tops out at Swift 5.10), so `Xcode 15.0+` is factually wrong, not just conservative.

The repo clone URL (the one real, correct link) is at `README.md:82` — `https://github.com/mnbf9rca/family-foqos.git`. There is **no evidence of a live App Store listing** anywhere in the repo (the only App Store references are the two `TODO` placeholders themselves).

#### MAINTAINER DECISIONS

**MD-J1a-1 — the three `TODO` links (GENUINE — ESCALATE; recommended option first).**
The correct destinations depend on facts only the maintainer holds (is there a public App Store listing? a marketing site for the title link?) — these are **not derivable from the repo**. The version-number fixes (Task J1a-1) are **not** a decision — they are mechanical and prescribed. Only the links need a ruling.

- **Option A (RECOMMENDED):**
  1. Point the title link (`:5`) at the **GitHub repo** — the one destination proven to exist (`README.md:82`): `href="https://github.com/mnbf9rca/family-foqos"`.
  2. Replace both App Store `TODO` links (`:47`, `:205`) with a plain **"not yet on the App Store — build from source"** note (exact text in Task J1a-2), since no listing is evident.
- **Option B:** leave the App Store links as `TODO` and only fix the title link. Rejected: `TODO` in a public README's primary CTA is worse than an honest "not yet published" note.
- **Option C:** the maintainer supplies real App Store / marketing URLs and the implementer substitutes them verbatim. This **supersedes A** if the maintainer provides URLs.

**Recommendation: A**, unless the maintainer supplies real URLs (then C). Task J1a-2 ships Option A's exact text, so **implementation is not blocked** on the ruling; if the maintainer picks C, swap the two placeholder strings for the supplied URLs and keep everything else.

#### Task J1a-0: Citation refresh (MANDATORY — do this first, no code)

- [ ] **Step 1: Record the base SHA.** Run `git rev-parse HEAD`; record it at the top of Task J1a-1's commit body. Expected `e7ac000` (or a later tip, since this bundle ships last). If it differs, re-run every grep below against the actual tip and update the line numbers before editing.
- [ ] **Step 2: Re-derive the README claim lines by fixed string** (line numbers are provisional):
```bash
grep -nF -e 'iOS 17.6+' -e 'Xcode 15.0+' -e 'iOS 17.0+ SDK' -e 'Swift 5.9+' \
  -e 'href="TODO"' -e '[App Store](TODO)' README.md
```
  Expected: the seven lines quoted in Grounding. If any string is **absent** (already fixed by an earlier commit), STOP and re-scope — do not edit a line that no longer matches.
- [ ] **Step 3: Re-derive the authoritative build settings** and confirm they are still single-valued:
```bash
grep -n "IPHONEOS_DEPLOYMENT_TARGET\|SWIFT_VERSION" FamilyFoqos.xcodeproj/project.pbxproj | sort -t= -k2 -u
```
  Expected: exactly two lines — `IPHONEOS_DEPLOYMENT_TARGET = 18.6;` and `SWIFT_VERSION = 6.0;`. **If `sort -u` returns more than one distinct value for either key** (e.g. a new target introduced a lower deployment floor), STOP: the README should then quote the **lowest** value across configs, not `18.6`/`6.0` blindly. Re-derive the lowest and use that.
- [ ] **Step 4: Confirm the repo URL** the title link will point at is still correct: `grep -nF 'github.com/mnbf9rca/family-foqos' README.md` (expected `:82` clone line). Record it.

#### Task J1a-1: Correct the requirements / prerequisites version numbers

**Files:** Modify `README.md` (lines `:39`, `:74`, `:75`, `:76` — re-confirm via Task J1a-0).

**Interfaces:** none (docs).

- [ ] **Step 1: Fix the Requirements bullet (`:39`).**
  Before:
  ```
  - iOS 17.6+
  ```
  After:
  ```
  - iOS 18.6+
  ```

- [ ] **Step 2: Fix the three Prerequisites bullets (`:74`–`:76`).**
  Before:
  ```
  - Xcode 15.0+
  - iOS 17.0+ SDK
  - Swift 5.9+
  ```
  After:
  ```
  - Xcode 16.0+
  - iOS 18.6+ SDK
  - Swift 6.0
  ```
  (Rationale to keep in the diff's commit body: `SWIFT_VERSION = 6.0` across all 14 configs → Swift 6 language mode → Xcode 16+; `IPHONEOS_DEPLOYMENT_TARGET = 18.6` across all 12 configs → iOS 18.6 minimum and 18.6 SDK. `Swift 6.0` is written without a `+` because the project pins exactly the 6.0 language mode.)

- [ ] **Step 3: VERIFY CLAIM AGAINST PROJECT SETTINGS (the substitute for a unit test).** Re-run the authoritative grep and eyeball that each new README number equals the project setting:
```bash
grep -n "IPHONEOS_DEPLOYMENT_TARGET\|SWIFT_VERSION" FamilyFoqos.xcodeproj/project.pbxproj | sort -t= -k2 -u
grep -nF -e 'iOS 18.6+' -e 'Xcode 16.0+' -e 'iOS 18.6+ SDK' -e 'Swift 6.0' README.md
```
  Confirm: README now says `18.6` (matching `IPHONEOS_DEPLOYMENT_TARGET`), `6.0` (matching `SWIFT_VERSION`), Xcode `16.0+` (the minimum Xcode that ships Swift 6.0), and **no** `17.6`/`17.0`/`15.0`/`5.9` strings remain: `grep -nF -e 'iOS 17' -e 'Xcode 15' -e 'Swift 5' README.md` should return nothing in the Requirements/Prerequisites blocks.

- [ ] **Step 4: Commit.**
```bash
git add README.md
git commit -m "docs(#253): correct README minimum OS/toolchain to iOS 18.6 / Xcode 16 / Swift 6.0"
```

#### Task J1a-2: Resolve the three `TODO` links (implements MD-J1a-1 Option A)

> Ships **Option A** (recommended). If the maintainer chose **Option C** (real URLs), substitute the supplied URLs for the placeholder strings below and keep the surrounding text.

**Files:** Modify `README.md` (lines `:5`, `:47`, `:205` — re-confirm via Task J1a-0).

- [ ] **Step 1: Point the title link at the GitHub repo (`:5`).**
  Before:
  ```
  <h1 align="center"><a href="TODO">Family Foqos</a></h1>
  ```
  After:
  ```
  <h1 align="center"><a href="https://github.com/mnbf9rca/family-foqos">Family Foqos</a></h1>
  ```

- [ ] **Step 2: Replace the App Store CTA in Getting Started (`:47`).**
  Before:
  ```
  1. Download Foqos from the [App Store](TODO)
  ```
  After:
  ```
  1. Family Foqos is not yet published on the App Store — build it from source (see the Development section below)
  ```
  (The subsequent numbered steps — grant Screen Time permissions, create a profile — still apply after building, so the list flow stays coherent.)

- [ ] **Step 3: Replace the App Store entry in the Links section (`:205`).**
  Before:
  ```
  - [App Store](TODO)
  ```
  After:
  ```
  - App Store — not yet published (build from source via the GitHub repo above)
  ```

- [ ] **Step 4: VERIFY — no `TODO` links remain.**
```bash
grep -nF 'TODO' README.md
```
  Expected: **no output** (every placeholder link resolved). If any `TODO` remains, it was not one of the three enumerated — re-scope before committing.

- [ ] **Step 5: Commit.**
```bash
git add README.md
git commit -m "docs(#253): resolve placeholder TODO links (title→repo, App Store→not-yet-published)"
```

#### Task J1a-3: Self-review checklist — CLAIMS vs PROJECT SETTINGS (waived-unit-test substitute)

- [ ] Walk this checklist and tick each row against the **authoritative source**, not memory. This is the acceptance for #253 (no unit test — see the waiver).

| README claim (new) | Authoritative source | Match? |
|---|---|---|
| `iOS 18.6+` (`:39`) | `IPHONEOS_DEPLOYMENT_TARGET = 18.6` (pbxproj, all configs) | ☐ |
| `iOS 18.6+ SDK` (`:75`) | same deployment target | ☐ |
| `Swift 6.0` (`:76`) | `SWIFT_VERSION = 6.0` (pbxproj, all configs) | ☐ |
| `Xcode 16.0+` (`:74`) | Swift 6.0 language mode ⇒ Xcode 16 is the minimum shipping it | ☐ |
| title link → repo (`:5`) | `README.md:82` clone URL exists | ☐ |
| no `App Store](TODO)` / `href="TODO"` remain | `grep -nF 'TODO' README.md` empty | ☐ |
| no stale `17.6`/`17.0`/`15.0`/`5.9` in Requirements/Prerequisites | `grep -nF -e 'iOS 17' -e 'Xcode 15' -e 'Swift 5' README.md` empty | ☐ |

- [ ] In the PR body, record the §MD-J1a-1 outcome (Option A shipped, or the maintainer's real URLs under Option C) and paste the two verifying `grep` outputs.

---

### J1b · #254 — the "Blocking Strategies" README section documents the removed V1 system

#### Problem

`README.md` presents the **legacy V1 strategy-picker model** as the app's current configuration mechanism. Two places are wrong:

- `README.md:28` — the feature bullet **`🧩 Mix & Match Strategies: Manual, NFC, QR, NFC + Manual, QR + Manual, NFC + Timer, QR + Timer`** — describes seven pickable "strategies" that no longer have a picker UI in V2.
- `README.md:115`–`:156` — the entire **`## 🔒 Blocking Strategies`** section documents 7 strategy classes (`NFCBlockingStrategy`, `QRCodeBlockingStrategy`, `ManualBlockingStrategy`, `NFCManualBlockingStrategy`, `QRManualBlockingStrategy`, `NFCTimerBlockingStrategy`, `QRTimerBlockingStrategy`) and the `physicalUnblockNFCTagId` / `physicalUnblockQRCodeId` fields as the primary way to configure a profile. In V2 a profile is configured by **start triggers** and **stop conditions**, not by picking a strategy.

The **`### QR deep links`** subsection (`README.md:158`–`:162`) **is accurate** — it documents `BlockedProfiles.getProfileDeepLink(_:)` (real, `BlockedProfiles.swift:514`) and the `https://family-foqos.app/profile/<UUID>` form. **Leave it untouched.**

#### Grounding (verified at worktree HEAD `e7ac000`)

Current README section boundaries (fixed string):
```
$ grep -nF -e 'Mix & Match Strategies' -e '## 🔒 Blocking Strategies' -e '### QR deep links' README.md
28:- **🧩 Mix & Match Strategies**: Manual, NFC, QR, NFC + Manual, QR + Manual, NFC + Timer, QR + Timer
115:## 🔒 Blocking Strategies
158:### QR deep links
```
So the section to rewrite is `:115`–`:156` (the `## 🔒 Blocking Strategies` heading through the last strategy bullet at `:156` — verified `:156` = `- Perfect for time-boxed focus sessions with a physical exit mechanism`; `:157` is blank; `:158` begins the accurate deep-link subsection that stays).

**V2 is the real configuration model, and the legacy classes are migration-compat only:**

- `BlockedProfiles.swift:15-19` marks the picker key legacy:
  ```
  15:  /// Legacy V1 strategy identifier. Retained for:
  16:  /// - Executing unmigrated V1 profiles (migration deferred during active sessions)
  17:  /// - CloudKit sync with V1 devices
  18:  /// Not written for V2-native profiles. See #59 for future removal.
  19:  var blockingStrategyId: String?
  ```
- V2-native profiles are created with **no** strategy id and there is **no strategy-picker UI**: `BlockedProfileView.swift:984` passes `blockingStrategyId: nil` (new-profile path); `:1006` only falls back to `NFCBlockingStrategy.id` on the legacy path. Legacy execution reads `blockingStrategyId` at `StrategyManager.swift:1152` (`definedProfile.blockingStrategyId`) and `:1290` (`session.blockedProfile.blockingStrategyId`). (Verified: no `strategy…picker` construct exists in `BlockedProfileView.swift`.)

**The accurate V2 vocabulary the rewrite MUST use** (verified against the models, not memory):

- `ProfileStartTriggers` (`Foqos/Models/ProfileStartTriggers.swift`): fields `manual`, `anyNFC`, `specificNFC`, `anyQR`, `specificQR`, `schedule`, `deepLink` (`:7-13`); helpers `hasNFC` (`:16`), `hasQR` (`:19`), `isValid` (`:22`).
- `ProfileStopConditions` (**moved to the shared package** — `Packages/FoqosShared/Sources/FoqosShared/ProfileStopConditions.swift`): fields `manual`, `timer`, `anyNFC`, `specificNFC`, `sameNFC`, `anyQR`, `specificQR`, `sameQR`, `schedule`, `deepLink` (`:8-17`); helpers `isValid` (`:44`), `hasNFC` (`:50`), `hasQR` (`:53`), `requiresPhysicalItemOnly` (`:59`).
- Persistence: JSON blobs `startTriggersData` / `stopConditionsData` (`BlockedProfiles.swift:106`, `:109`) surfaced through computed `startTriggers` / `stopConditions` (`:112`, `:132`).
- Specific-item IDs `startNFCTagId` / `startQRCodeId` / `stopNFCTagId` / `stopQRCodeId` (`BlockedProfiles.swift:152`, `:155`, `:158`, `:161`) — these **supersede** the legacy `physicalUnblockNFCTagId` / `physicalUnblockQRCodeId` (which still exist at `BlockedProfiles.swift:35`-`:36` but are read only by the legacy strategy classes).
- `profileSchemaVersion` (`BlockedProfiles.swift:103`, default `1`): `1` = legacy `blockingStrategyId`, `2` = triggers/conditions.
- Legacy strategy classes live in `Foqos/Models/Strategies/` (9 files: the 7 documented + `ShortcutTimerBlockingStrategy.swift` + `BlockingStrategy.swift` protocol) and are resolved for execution via `Foqos/Utils/StartStopActionResolver.swift`. They are **V1-migration-compat only**. Reference #59 for removal **without coupling** the rewrite to it.

#### MAINTAINER DECISIONS

**None.** The replacement content is fully determined by the models (vocabulary verified above), and the deep-link subsection stays. No maintainer decision is needed — proceed directly. (The implementer must still re-verify the vocabulary in Task J1b-0 in case a field was renamed post-authoring.)

#### Task J1b-0: Citation refresh (MANDATORY — do this first, no code)

- [ ] **Step 1: Record the base SHA** (`git rev-parse HEAD`, expected `e7ac000` or later) in Task J1b-1's commit body.
- [ ] **Step 2: Re-derive the README boundaries** (line numbers provisional):
```bash
grep -nF -e 'Mix & Match Strategies' -e '## 🔒 Blocking Strategies' -e '### QR deep links' README.md
```
  Expected: `:28`, `:115`, `:158` (or drifted equivalents). The rewrite spans from the `## 🔒 Blocking Strategies` line **up to but excluding** the `### QR deep links` line.
- [ ] **Step 3: Re-verify the V2 vocabulary against the models** (fixed string — do NOT trust the field list above if these drift):
```bash
grep -nF -e 'var manual' -e 'var anyNFC' -e 'var specificNFC' -e 'var anyQR' -e 'var specificQR' \
  -e 'var schedule' -e 'var deepLink' -e 'var hasNFC' -e 'var hasQR' -e 'var isValid' \
  Foqos/Models/ProfileStartTriggers.swift
grep -nF -e 'var manual' -e 'var timer' -e 'var anyNFC' -e 'var specificNFC' -e 'var sameNFC' \
  -e 'var anyQR' -e 'var specificQR' -e 'var sameQR' -e 'var schedule' -e 'var deepLink' \
  -e 'var isValid' -e 'var hasNFC' -e 'var hasQR' -e 'requiresPhysicalItemOnly' \
  Packages/FoqosShared/Sources/FoqosShared/ProfileStopConditions.swift
grep -nF -e 'var startNFCTagId' -e 'var startQRCodeId' -e 'var stopNFCTagId' -e 'var stopQRCodeId' \
  -e 'var profileSchemaVersion' -e 'var startTriggers' -e 'var stopConditions' \
  Foqos/Models/BlockedProfiles.swift
```
  Any field that no longer matches MUST be corrected in the rewrite text before committing.
- [ ] **Step 4: Confirm the legacy-compat status is still true** (so the "legacy only" note is accurate):
```bash
grep -nF -e 'See #59 for future removal' -e 'var blockingStrategyId' Foqos/Models/BlockedProfiles.swift
grep -nF -e 'blockingStrategyId: nil' Foqos/Views/BlockedProfileView.swift
ls Foqos/Models/Strategies/*.swift
ls Foqos/Utils/StartStopActionResolver.swift
```
  Expected: the `#59` legacy comment at `:18` (block `:15-19`); `blockingStrategyId: nil` at `BlockedProfileView.swift:984`; the strategy class files present; `StartStopActionResolver.swift` present. If `BlockedProfileView` now shows a strategy **picker** (unlikely), STOP and re-scope — the "no picker UI" claim would be false.

#### Task J1b-1: Rewrite the feature bullet (`:28`)

**Files:** Modify `README.md` (line `:28`).

- [ ] **Step 1: Replace the "Mix & Match Strategies" bullet** with V2 vocabulary.
  Before:
  ```
  - **🧩 Mix & Match Strategies**: Manual, NFC, QR, NFC + Manual, QR + Manual, NFC + Timer, QR + Timer
  ```
  After:
  ```
  - **🧩 Start Triggers & Stop Conditions**: Mix and match how each profile *starts* (manual, NFC, QR, schedule, deep link) and how it *stops* (manual, timer, NFC, QR, schedule, deep link) — no fixed "strategy" to pick
  ```

- [ ] **Step 2: VERIFY** the new bullet's verbs exist as trigger/condition fields (the ones named: manual/NFC/QR/schedule/deepLink for start; those + timer for stop) — cross-check against the Task J1b-0 Step 3 output. No invented capability.

- [ ] **Step 3: Commit.**
```bash
git add README.md
git commit -m "docs(#254): reword feature bullet to start-triggers/stop-conditions (V2)"
```

#### Task J1b-2: Rewrite the `## 🔒 Blocking Strategies` section (`:115`–`:156`)

**Files:** Modify `README.md` (replace the `## 🔒 Blocking Strategies` heading through the final strategy bullet at `:156`; **keep** the blank line `:157` and the `### QR deep links` subsection from `:158` onward exactly as-is).

**Interfaces:** none (docs). The section's heading changes from `## 🔒 Blocking Strategies` to `## 🔒 Start Triggers & Stop Conditions`; no other README section links to the old anchor (verified: `grep -nF '(#' README.md` finds no internal-anchor references), so the rename is safe.

- [ ] **Step 1: Replace lines `:115`–`:156`** (heading + all seven strategy bullets) with the following. **Do not** touch `:157` (blank) or `:158`+ (`### QR deep links`).

  Before (the block to remove — confirm its exact extent via Task J1b-0 Step 2; it begins):
  ```
  ## 🔒 Blocking Strategies

  All strategies live in `Foqos/Models/Strategies/` and are orchestrated by `Foqos/Utils/StrategyManager.swift`.

  - **NFC Tags (`NFCBlockingStrategy`)**
  ...
    - Perfect for time-boxed focus sessions with a physical exit mechanism
  ```
  (…the seven strategy bullets, ending at the `QR + Timer` bullet's last line at `:156`.)

  After (the exact replacement markdown):
  ```
  ## 🔒 Start Triggers & Stop Conditions

  A profile in Family Foqos (schema v2) is configured by two independent value types — **how it
  starts** and **how it stops** — rather than by picking a single "strategy". Both are stored as
  JSON on the profile (`startTriggersData` / `stopConditionsData` in
  `Foqos/Models/BlockedProfiles.swift`) and surfaced through the computed `startTriggers` /
  `stopConditions` properties.

  ### Start triggers (`Foqos/Models/ProfileStartTriggers.swift`)

  Any combination of:

  - `manual` — start from within the app
  - `anyNFC` — start by scanning any NFC tag
  - `specificNFC` — start only by scanning the tag stored in `startNFCTagId`
  - `anyQR` — start by scanning any QR code
  - `specificQR` — start only by scanning the code stored in `startQRCodeId`
  - `schedule` — start automatically on the profile's schedule
  - `deepLink` — start via the profile's deep link (see below)

  Helpers: `hasNFC` (any NFC start), `hasQR` (any QR start), `isValid` (at least one trigger set).

  ### Stop conditions (`Packages/FoqosShared/Sources/FoqosShared/ProfileStopConditions.swift`)

  Any combination of:

  - `manual` — stop from within the app
  - `timer` — stop automatically after a chosen duration
  - `anyNFC` — stop by scanning any NFC tag
  - `sameNFC` — stop only by scanning the same tag that started the session
  - `specificNFC` — stop only by scanning the tag stored in `stopNFCTagId`
  - `anyQR` / `sameQR` / `specificQR` — the QR-code equivalents (`stopQRCodeId` holds the specific code)
  - `schedule` — stop automatically on the profile's schedule
  - `deepLink` — stop via the profile's deep link

  Helpers: `isValid`, `hasNFC`, `hasQR`, `requiresPhysicalItemOnly` (true when the only way to stop
  is a physical tag/code — used to warn the user before they start).

  The specific-item IDs `startNFCTagId` / `startQRCodeId` / `stopNFCTagId` / `stopQRCodeId`
  supersede the legacy `physicalUnblockNFCTagId` / `physicalUnblockQRCodeId` fields.

  > **Legacy V1 strategy classes.** The classes in `Foqos/Models/Strategies/` (`NFCBlockingStrategy`,
  > `QRCodeBlockingStrategy`, `ManualBlockingStrategy`, `NFCManualBlockingStrategy`,
  > `QRManualBlockingStrategy`, `NFCTimerBlockingStrategy`, `QRTimerBlockingStrategy`, …) and the
  > `physicalUnblock*` fields exist **only** to execute unmigrated V1 profiles and to sync with V1
  > devices; V1 profiles are resolved to start/stop actions via
  > `Foqos/Utils/StartStopActionResolver.swift`. V2 profiles carry `profileSchemaVersion == 2` and
  > leave `blockingStrategyId` unset — there is no strategy-picker UI. (Removal of the legacy
  > `blockingStrategyId` system is tracked in #59.)
  ```

- [ ] **Step 2: Confirm the deep-link subsection is intact.** After the edit, `### QR deep links` must immediately follow (with one blank line):
```bash
grep -nF -e '## 🔒 Start Triggers & Stop Conditions' -e '### QR deep links' -e 'Blocking Strategies' README.md
```
  Expected: the new heading and `### QR deep links` both present; **`Blocking Strategies` no longer matches** anywhere.

- [ ] **Step 3: VERIFY CLAIM AGAINST THE MODELS (unit-test substitute).** Every field name in the new section must appear in the model greps from Task J1b-0 Step 3, and no removed/renamed field must be introduced. Spot-check the four superseding IDs and the helper most likely to drift:
```bash
grep -nF -e 'startNFCTagId' -e 'stopQRCodeId' Foqos/Models/BlockedProfiles.swift
grep -nF -e 'requiresPhysicalItemOnly' Packages/FoqosShared/Sources/FoqosShared/ProfileStopConditions.swift
```
  All must return a hit. If any field named in the prose is absent from the models, fix the prose.

- [ ] **Step 4: Commit.**
```bash
git add README.md
git commit -m "docs(#254): rewrite Blocking Strategies section around V2 start-triggers/stop-conditions"
```

#### Task J1b-3: Self-review checklist — CLAIMS vs MODELS (waived-unit-test substitute)

- [ ] Tick each row against the **models**, not memory. This is the acceptance for #254 (no unit test — see the waiver).

| README claim (new) | Authoritative source | Match? |
|---|---|---|
| Start-trigger fields `manual/anyNFC/specificNFC/anyQR/specificQR/schedule/deepLink` | `ProfileStartTriggers.swift:7-13` | ☐ |
| Start helpers `hasNFC/hasQR/isValid` | `ProfileStartTriggers.swift:16,19,22` | ☐ |
| Stop-condition fields incl. `timer/sameNFC/sameQR` | `ProfileStopConditions.swift:8-17` | ☐ |
| Stop helper `requiresPhysicalItemOnly` | `ProfileStopConditions.swift:59` | ☐ |
| ProfileStopConditions is in the **shared package** path | `Packages/FoqosShared/.../ProfileStopConditions.swift` exists | ☐ |
| `start/stopNFCTagId` / `start/stopQRCodeId` supersede `physicalUnblock*` | `BlockedProfiles.swift:152-161` (+ `:35-36` legacy) | ☐ |
| V2 = `profileSchemaVersion == 2`, `blockingStrategyId` unset, no picker UI | `BlockedProfiles.swift:15-19,103`; `BlockedProfileView.swift:984` | ☐ |
| Legacy strategy classes = V1-migration-compat via resolver | `Foqos/Models/Strategies/*`, `StartStopActionResolver.swift` | ☐ |
| `### QR deep links` subsection left unchanged | `git diff` shows no edit at/after `:158` | ☐ |
| Feature bullet `:28` reworded, names only real fields | `ProfileStartTriggers` / `ProfileStopConditions` | ☐ |

- [ ] In the PR body, paste the `git diff --stat README.md` and confirm **only** `README.md` changed (no Swift, no pbxproj). Note the #59-decoupling: the rewrite *references* #59 for removal but does not depend on it.

---

**Note on citations that drifted from the task brief.** One correction the implementer should be aware of (already folded into the grounding above): `physicalUnblockNFCTagId` / `physicalUnblockQRCodeId` are **not removed** — they still exist on `BlockedProfiles` (`:35-36`) and are read by the legacy NFC strategy classes; they are **superseded** (not deleted) by `startNFCTagId`/`stopNFCTagId`/etc., so J1b's prose marks them "legacy … superseded by," never "removed." All README line numbers, the pbxproj settings (18.6 / 6.0), the V2 model vocabulary, and the base SHA (`e7ac000`, verified via `git rev-parse HEAD`) were re-verified and match this section.


---

## Mini-plan #240 — replace the apologetic lock-code hashing TODO with the ruled threat model

> **Comment-only change.** This mini-plan touches **exactly three comment lines** in one file. It does **not** change the hashing implementation, does **not** add a KDF (PBKDF2/Argon2), does **not** add attempt-gating or a schema change, and does **not** touch the sync mirror. It IMPLEMENTS LAST in the tail bundle (order: H → G → #331 → J1 → **#240**), so its one citation may have drifted — Task 0 re-locates the anchor by fixed-string grep. **Close #240 on merge.**

### Problem

`Foqos/Models/FamilyLockCode.swift:65-67` carries an apologetic `TODO` above `hashCode(_:salt:)` that frames the current SHA256+salt hashing as a provisional stop-gap ("acceptable for v1 … but could be strengthened for higher-stakes scenarios"). This is now **stale and contradicts the governing maintainer ruling**. The ruling (issue #240, 2026-07-10) is that the lock code is a **low-stakes** secret — parental friction, not a credential guarding high-value data — proportionately protected by the current hashing; a hardening *project* (KDF migration, attempt-gating, server-side verification) is explicitly **out of the threat model**, because an offline brute-force of the stored hash already requires device-level (jailbreak) access. The apologetic comment invites exactly the hardening the maintainer ruled out and reads as an open security debt where none exists. It should be replaced by a comment that records the ruled threat model verbatim. There is no runtime symptom — this is a documentation-in-code defect.

### Grounding

Verified at the worktree tip: `git rev-parse HEAD` = `e7ac00027953dc317362fd9337a0b4cc2b1eff73` (= the tail bundle's declared base `e7ac000`; HEAD and base match at authoring time). The verbatim TODO to delete, `Foqos/Models/FamilyLockCode.swift:65-67`:

```swift
65:  // TODO: Consider using PBKDF2 or Argon2 for hardened security against brute-force
66:  // attacks on 4-digit PINs. SHA256+salt is acceptable for v1 family app use case
67:  // but could be strengthened for higher-stakes scenarios.
68:  private static func hashCode(_ code: String, salt: String) -> String {
69:    let combined = code + salt
70:    let data = Data(combined.utf8)
71:    let hash = SHA256.hash(data: data)
72:    return hash.compactMap { String(format: "%02x", $0) }.joined()
73:  }
```

The comment sits directly above `hashCode` (`:68-73`) and directly below the `generateSalt()` helper (`:59-63`). `hashCode` is **unchanged by this mini-plan** and is called from three sites — `init` (`:41`), `updateCode` (`:47`), `verifyCode` (`:53`) — none of which a comment edit can affect. `toCKRecord(in:)` writes `codeHash`/`codeSalt` (`:125-126`), also untouched.

The `PBKDF2|Argon` string is the **unique** anchor in the entire source tree: `grep -rnE 'PBKDF2|Argon' Foqos Packages` returns **only** `Foqos/Models/FamilyLockCode.swift:65` (verified 2026-07-10 at the SHA above). The sync mirror in `Foqos/CloudKit/CloudKitNetworkService+LockCodes.swift` (which round-trips `codeHash`/`codeSalt` at `:33-34`) is **OUT OF SCOPE** and is not edited.

Existing test coverage: `FoqosTests/LockCodeVerifyTests.swift` and `FoqosTests/LockCodeFailClosedTests.swift` exercise the hashing/verification behaviour (both files present at the SHA above). A comment-only change alters no behaviour and is **not unit-testable**; under the maintainer's comment-only ruling the regression-test criterion is **N/A** (there is no runtime surface to observe — the existing hashing tests must simply continue to pass unchanged).

### MAINTAINER DECISIONS

**None — already ruled.** The governing ruling (issue #240, 2026-07-10, calibrated) is: the lock code is a **low-stakes secret**, proportionately protected; hashing is appropriate and a KDF would be acceptable but is not required; ruled **out** is any hardening *project* (no attempt-gating, no schema change, no server-side verification), because offline brute-force needs device-level access, outside this app's threat model. B3 (the former "harden hashing" bundle) is dissolved. There is no fork to escalate and no proportionate alternative to weigh — the proportionate answer is fixed by the ruling: swap the apologetic comment for the ruled threat model, verbatim, and change nothing else.

The replacement text is the maintainer's calibrated wording (do **not** paraphrase):

```swift
  // The lock code is stored hashed. It is a low-stakes secret — parental friction, not a
  // credential guarding high-value data. Offline brute-force requires device-level access
  // (jailbreak), outside this app's threat model. Current protection is proportionate by
  // maintainer ruling (issue #240, 2026-07-10); no further hardening planned.
```

### Task 0: Citation refresh (MANDATORY — do this first, no code)

Because this mini-plan implements **last** in the tail bundle, the line numbers above may have drifted from earlier bundles (H/G/#331/J1) even though none of them touch `FamilyLockCode.swift`. Re-locate the anchor by fixed string before editing.

- [ ] **Step 1: Record the base SHA.** Run `git rev-parse HEAD` and write the result into the Task 1 commit body (`Verified against <SHA>`). At authoring time HEAD = `e7ac00027953dc317362fd9337a0b4cc2b1eff73` (= declared base `e7ac000`). If HEAD now differs, that is expected (earlier tail bundles merged ahead of this one) — just record the actual SHA.
- [ ] **Step 2: Confirm the anchor is still unique and unchanged.** Run:
```bash
grep -rnE 'PBKDF2|Argon' Foqos Packages
```
Expected: **exactly one** line — `Foqos/Models/FamilyLockCode.swift:65:  // TODO: Consider using PBKDF2 or Argon2 for hardened security against brute-force`. If it returns zero lines, the TODO was already removed by another bundle — STOP and reconcile (the fix may be a no-op; close #240 with a note). If it returns more than one line, a new occurrence appeared — STOP and reconcile scope with the maintainer before editing.
- [ ] **Step 3: Re-derive the exact three-line block and its surrounding context** so the Task 1 `old_string` matches byte-for-byte (including the two leading spaces of indentation):
```bash
grep -nF -e '// TODO: Consider using PBKDF2 or Argon2 for hardened security against brute-force' \
         -e '// attacks on 4-digit PINs. SHA256+salt is acceptable for v1 family app use case' \
         -e '// but could be strengthened for higher-stakes scenarios.' \
         -e 'private static func hashCode(_ code: String, salt: String) -> String' \
  Foqos/Models/FamilyLockCode.swift
```
Expected: three consecutive comment lines (`65-67` at the verified SHA) immediately followed by the `hashCode` signature (`68`). If the wording of any comment line differs from the quoted text, use the **actual** current text as the `old_string` in Task 1 (the three-line TODO block, whatever it now reads), and keep the replacement text exactly as specified in MAINTAINER DECISIONS.
- [ ] **Step 4: Confirm the sync mirror is out of scope and untouched.** Run `grep -nF -e 'codeHash' -e 'codeSalt' Foqos/CloudKit/CloudKitNetworkService+LockCodes.swift` only to confirm it exists (expected: matches at `:33-34`) and is not edited by this task — do **not** modify it.

### Task 1: Swap the apologetic TODO for the ruled threat model (comment-only)

**Files:**
- Modify: `Foqos/Models/FamilyLockCode.swift` (the three-line comment above `hashCode`, `:65-67` at the verified SHA)

**Interfaces:**
- None. No symbol, signature, type, or behaviour changes. `hashCode(_:salt:)` and all three call sites (`init`/`updateCode`/`verifyCode`) are untouched. This task produces and consumes nothing for other tasks.

**No test.** A comment-only edit has no runtime surface — it cannot be unit-tested, and per the maintainer's comment-only ruling the regression-test criterion is **N/A**. The check is (a) `swift-format lint` clean and (b) the existing `LockCodeVerifyTests` / `LockCodeFailClosedTests` still pass unchanged (they must, since no code changed).

- [ ] **Step 1: Apply the Edit.** Replace the three TODO lines with the four ruled-threat-model lines. `old_string` (the exact block confirmed in Task 0 — three lines, two-space indent):
```swift
  // TODO: Consider using PBKDF2 or Argon2 for hardened security against brute-force
  // attacks on 4-digit PINs. SHA256+salt is acceptable for v1 family app use case
  // but could be strengthened for higher-stakes scenarios.
```
`new_string` (maintainer's calibrated wording; two-space indent; each line ≤ ~100 col):
```swift
  // The lock code is stored hashed. It is a low-stakes secret — parental friction, not a
  // credential guarding high-value data. Offline brute-force requires device-level access
  // (jailbreak), outside this app's threat model. Current protection is proportionate by
  // maintainer ruling (issue #240, 2026-07-10); no further hardening planned.
```
Do not touch the `hashCode` signature or body below it (`:68-73`), or the `generateSalt()` helper above it (`:59-63`).

- [ ] **Step 2: Format-lint the file.** The pre-commit hook auto-formats staged Swift; run the check explicitly first so a violation is caught before staging:
```bash
swift-format lint Foqos/Models/FamilyLockCode.swift
```
Expected: no output (clean). If it flags a line-width violation on the comment, re-wrap the comment text across the four lines to stay ≤ ~100 col **without altering the wording** (the em-dash and the parenthetical must survive verbatim).

- [ ] **Step 3: Build sanity (comment-only, no test run needed).** A comment change cannot break compilation, but build the target once to confirm nothing else in the tail bundle left the file in a non-compiling state:
```bash
xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug -destination 'generic/platform=iOS Simulator' build | xcpretty
```
Expected: `BUILD SUCCEEDED`. (No `xcodebuild test` slice is prescribed — there is no new or changed behaviour to test; the pre-existing `LockCodeVerifyTests`/`LockCodeFailClosedTests` remain valid unchanged and will run in the bundle's full-suite gate.)

- [ ] **Step 4: Commit** (new commit only — never amend/force):
```bash
git add Foqos/Models/FamilyLockCode.swift
git commit -m "docs(#240): replace apologetic lock-code TODO with ruled threat model"
```

- [ ] **Step 5: Note for the PR.** #240 **closes on merge** — add `Closes #240` to the PR body. State plainly in the PR description that this is a comment-only change (no hashing/KDF/gating/schema change) enacting the 2026-07-10 maintainer ruling, and that the sync mirror in `Foqos/CloudKit/CloudKitNetworkService+LockCodes.swift` was intentionally left untouched.


---

