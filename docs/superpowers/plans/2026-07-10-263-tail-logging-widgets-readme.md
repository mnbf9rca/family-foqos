# Epic #263 tail (G, H, J1, #240) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This plan is **self-contained** — it assumes no prior Claude session/project memory (the implementer may be Codex). Read `AGENTS.md` at the repo root first; it overrides everything here.

**Goal:** Ship the final four epic-#263 clean-up bundles as ONE branch / ONE PR (the "F+I bundle" pattern — four self-contained mini-plans, executed and reviewed in sequence, merged together):
- **Mini-plan H — logging & privacy** (`#252`, `#247`, `#250`): stop writing family-share participants' real names/emails to exportable logs (`#252`); stop leaking the physical-unblock NFC UID through Debug Mode in Child mode (`#247`); route all processes' logs to the shared app-group container so Export Logs actually includes extension logs (`#250`).
- **Mini-plan G — widget / Live Activity freshness** (`#238`, `#249`): reload the home-screen widget's timelines when the monitor extension starts/stops a scheduled session (`#238`); end-and-recreate the Live Activity on a profile switch so it stops showing the previous profile's name (`#249`).
- **Mini-plan J1 — README corrections** (`#253`, `#254`): correct the minimum OS/toolchain and dead TODO links (`#253`); rewrite the removed-V1 "Blocking Strategies" section against the V2 trigger model (`#254`).
- **Mini-plan #240 — threat-model comment swap**: replace the apologetic PBKDF2/Argon2 TODO in `FamilyLockCode.swift` with the maintainer's ruled threat model (comment-only).

**Architecture:** Each mini-plan is a focused, TDD-first change on `main` at base commit `e7ac000`. The four are code-independent (different subsystems: logging/privacy, DeviceActivity/widgets/ActivityKit, docs, a single code comment). **This bundle implements LAST in the epic-#263 queue** — after `#302`/`#301`/`#298`, B2, and D3+E2 — so many citations in this document will have drifted by implementation time. **Every mini-plan opens with a mandatory Task 0 citation-refresh** that re-derives its citations by symbol against the then-current `main` and records the SHA it verified against. **Implementation order within the bundle: H → G → J1 + #240** (H and G carry runtime surface and device-acceptance rows; the docs and the comment ride last). Commit each mini-plan's tasks under its own `(#N)` scope.

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
- **PR wording:** the plan-only PR that INTRODUCES this document must be titled **"plans the fix for #238, #249, #252, #247, #250, #253, #254, #240"**, never "fixes". When each mini-plan is later IMPLEMENTED, its commits use conventional-commit types scoped to the issue (`fix(#N)`/`feat(#N)`/`test(#N)`/`refactor(#N)`/`docs(#N)`).

---
## Mini-plan H — logging & privacy (#252, #247, #250)

> **Tail-bundle position.** This mini-plan implements **last** in the tail bundle (order H → G → J1+#240), on `main` at base commit `e7ac000`, **after** #302/#301/#298, B2, and D3+E2 have merged. None of those bundles is known to touch the four files H edits (`CloudKitNetworkService+FamilyMembers.swift`, `ProfileDebugCard.swift`, `DebugView.swift`, `Packages/FoqosShared/Sources/FoqosShared/Log.swift`), but citations **may still drift** — each sub-part opens with a mandatory Task 0 that re-derives every citation **by symbol** (fixed-string grep) and records the SHA it verified against. All line numbers below were verified against `e7ac000`; where a Task-0 grep reports a shifted line, use the fresh number.

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
- **Cross-process locking.** Giving each process a **distinct basename** structurally eliminates the shared-file append/rotation race (no two processes ever touch the same file), so **no `flock`/`NSFileCoordinator` is added for writes** — that is the whole point of the per-process naming, and adding locks would be over-engineering. The only cross-process operations are read-only enumeration and `clearLogs` (which deletes siblings' files); both are safe because `writeToFile` opens a **fresh** handle per call (`:239`), so a file deleted between writes is simply recreated on the next write — no stale-handle corruption.
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
- [ ] **Step 5: `copyLogFilesToStagingDirectory`** (`:313-322`) — use collision-free basenames:
```swift
  public func copyLogFilesToStagingDirectory(_ stagingDir: URL) throws {
    try queue.sync {
      let urls = _getLogFileURLsUnsafe()
      for url in urls {
        let destURL = stagingDir.appendingPathComponent(Self.stagingDestinationName(for: url))
        try fileManager.copyItem(at: url, to: destURL)
      }
    }
  }
```
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

## Mini-plan G — widget / Live Activity freshness (#238, #249)

> **Tail-bundle ordering.** This mini-plan implements **LAST** (order H → G → J1+#240),
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

- [ ] **Step 1: Write the failing spy test** (append to `ScheduleTimerActivityTests.swift`; it uses
  plain `import FoqosShared`, and the seam is `public`). Add a tiny `@unchecked Sendable` counter
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

## Mini-plan J1 — README corrections (#253, #254) — DOCS ONLY

This mini-plan makes **two documentation-only fixes to `README.md`** — no runtime source, no schema, no tests-under-test. It has two independent sub-parts, each self-contained:

- **J1a · #253** — the README advertises the wrong minimum OS / toolchain (iOS 17.6, Xcode 15, Swift 5.9) and carries three placeholder `TODO` hyperlinks.
- **J1b · #254** — the "Blocking Strategies" section documents the **removed V1 strategy-picker system** (7 strategy classes + `physicalUnblock*`) as if it were the current configuration model, instead of the V2 **start-triggers / stop-conditions** model.

**Bundle position & drift warning.** In the tail bundle this mini-plan implements **LAST** (order: H → G → J1+#240), *after* #302/#301/#298, B2, and D3+E2. Those bundles touch **Swift** sources, not `README.md` or `FamilyFoqos.xcodeproj/project.pbxproj`, so drift on *these* two files is unlikely — but line numbers are still **provisional**. Each sub-part opens with a mandatory Task 0 that re-derives every citation by **fixed-string grep** and records the SHA it verified against. Do not trust the line numbers printed below.

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

> **Comment-only change.** This mini-plan touches **exactly three comment lines** in one file. It does **not** change the hashing implementation, does **not** add a KDF (PBKDF2/Argon2), does **not** add attempt-gating or a schema change, and does **not** touch the sync mirror. It IMPLEMENTS LAST in the tail bundle (order: H → G → J1 → **#240**), so its one citation may have drifted — Task 0 re-locates the anchor by fixed-string grep. **Close #240 on merge.**

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

Because this mini-plan implements **last** in the tail bundle, the line numbers above may have drifted from earlier bundles (H/G/J1) even though none of them touch `FamilyLockCode.swift`. Re-locate the anchor by fixed string before editing.

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

