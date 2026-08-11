# Log Privacy Lint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This repository forbids
> parallel implementation/build streams, so do not use subagent-driven development.

**Goal:** Add a fail-closed, multiline-aware production-log privacy analyzer, migrate unsafe log
sites to audited helpers, and enforce the analyzer in every app build.

**Architecture:** A standard-library Ruby scanner discovers every production Swift source, extracts
balanced log calls, classifies interpolations with bounded local-origin analysis, and enforces hard
file coverage plus maintained site/annotation baselines. A shared Swift formatter converts errors
to bounded single-line diagnostics through an exhaustive CloudKit metadata allowlist. The app target
runs the scanner in an always-out-of-date pre-Sources phase.

**Tech Stack:** Ruby standard library, Swift 5.9, Foundation, CloudKit, XCTest, Xcode project build
phases, swift-format.

## Global Constraints

- Work only on `feat/log-privacy-lint` in the existing `build2-log-privacy-lint` worktree.
- Use signed commits; never amend, force-push, or force-commit.
- Run all Xcode builds/tests serially through
  `scripts/xcode-stream.sh --agent build2 --session collab -- xcodebuild ...`; callers must not pass
  a destination or DerivedData path.
- Analyze exactly `Foqos`, `FoqosWidget`, `FoqosDeviceMonitor`, `FoqosShieldConfig`, and
  `Packages/FoqosShared/Sources`; fixtures and tests are outside production roots.
- Add no SwiftSyntax or other dependency, no pre-commit rule, and no Child-mode diagnostics gate.
- Require `files_analyzed == files_discovered`, production facade sites `>= 503`, and an exact
  `LOG-PRIVACY-SAFE` annotation count of `0` initially.
- Exit `1` only for confirmed privacy violations; exit `2` for configuration, parsing, unresolved
  suspicious origins, and coverage-integrity failures.
- Keep the single facade-owned `os_log` call; ban production `Logger`, other `os_log`, and `NSLog`.
- Advance every project configuration from `2.0.7`/`26` to `2.0.8`/`27`.
- Obtain independent code review before the planner merges.

---

### Task 1: Add RED analyzer fixtures and the real-process test harness

**Files:**

- Create: `scripts/test-check-log-privacy.rb`
- Create: `scripts/fixtures/log-privacy/fail/*.swift`
- Create: `scripts/fixtures/log-privacy/pass/*.swift`
- Create: `scripts/fixtures/log-privacy/baselines/site-0.txt`
- Create: `scripts/fixtures/log-privacy/baselines/site-1.txt`
- Create: `scripts/fixtures/log-privacy/baselines/annotation-0.txt`
- Create: `scripts/fixtures/log-privacy/baselines/malformed.txt`

**Interfaces:**

- Consumes: the future production CLI
  `ruby scripts/check-log-privacy.rb --root <repository-or-fixture-root>`.
- Produces: a process-level regression suite that copies exact fixture files into temporary copies
  of all five production roots, writes both baseline files, and asserts exit class plus diagnostic
  fragments without mocking scanner behavior.

- [ ] **Step 1: Create the fixture harness around the final CLI contract**

Use `Open3.capture3`, `Dir.mktmpdir`, and `FileUtils`. Define a case record and helpers with these
interfaces:

```ruby
Case = Struct.new(
  :name, :fixture, :status, :diagnostic, :site_floor, :annotation_count,
  keyword_init: true
)

def with_fixture_root(fixture:, site_floor:, annotation_count:)
  # Create all five exact production roots plus scripts/, copy the exact fixture to
  # Foqos/Fixture.swift (or the exact facade path for the facade_os_log case), and write
  # scripts/log-privacy-baseline.txt and scripts/log-privacy-annotation-baseline.txt.
end

def run_analyzer(root)
  Open3.capture3(RbConfig.ruby, ANALYZER, "--root", root)
end

def assert_case(test_case)
  # Assert Process::Status#exitstatus and that stdout+stderr includes test_case.diagnostic.
end
```

The harness must delete temporary roots in `ensure`, must not add a wildcard fixture exclusion to
the analyzer, and must invoke the checked-in analyzer path rather than loading Ruby classes in
process.

- [ ] **Step 2: Add exact historical and structural failure fixtures**

Create these concrete fixture cases with expected exit `1`:

```swift
// fail/multiline_display_name.swift
func report(member: FamilyMember) {
  Log.info(
    "Member: \(member.displayName)",
    category: .cloudKit
  )
}

// fail/laundered_display_info.swift
func report(participant: CKShare.Participant) {
  let displayInfo = participant.userIdentity.nameComponents?.givenName
    ?? participant.userIdentity.lookupInfo?.emailAddress
    ?? "unknown"
  Log.debug("Participant: \(displayInfo)", category: .cloudKit)
}

// fail/associated_error_payload.swift
func report(error: Error) {
  Log.error("Failure: \(error)", category: .sync)
}
```

Add separate one-site fixtures for raw URL/query, coordinate/latitude/longitude, NFC identifier,
QR identifier, person/member/participant name/email/phone, `\(member)`,
`String(describing: member)`, `Logger(`, non-facade `os_log(`, and `NSLog(`. Each fixture contains
one minimal function and one matching sink so the diagnostic line and site floor are deterministic.

- [ ] **Step 3: Add analysis-integrity failure fixtures**

Add cases expecting exit `2` for:

```swift
// fail/message_variable.swift
func report(message: String) {
  Log.debug(message, category: .app)
}

// fail/unresolved_origin.swift
func report(displayInfo: String) {
  Log.debug("Participant: \(displayInfo)", category: .cloudKit)
}

// fail/unbalanced_call.swift
func report() {
  Log.info("unterminated", category: .app
}
```

Also make the harness exercise a missing production root, malformed site baseline, malformed
annotation baseline, site-floor drop (`2` sites required with `1` present), annotation exact-count
mismatch (`0` required with one valid annotation), and an unreadable Swift file created with mode
`000`. The unreadable-file case must remain in `files_discovered`, remain absent from
`files_analyzed`, and produce the hard mismatch diagnostic before its permissions are restored in
`ensure`. Assert the
coverage-drop message includes both the baseline and observed count and explains deliberate floor
lowering; assert a file-analysis mismatch says numeric baselines cannot repair it.

- [ ] **Step 4: Add safe contrast fixtures**

Add expected-exit-`0` fixtures covering this literal matrix:

```swift
func report(member: FamilyMember, error: Error, records: [CKRecord]) {
  Log.info(
    "member=\(member.redactedLogLabel) role=\(member.role.displayName) count=\(records.count)",
    category: .cloudKit
  )
  Log.error(
    "failure=\(redactedErrorForLog(error)) localized=\(error.localizedDescription)",
    category: .cloudKit
  )
}

func roster(member: FamilyMember) -> String {
  member.displayName
}
```

Add pass cases for `ShareParticipantLog.label`, `ShareParticipantLog.statusMessage`,
`DebugRedaction.*ForLog`, `redactedURLString`, opaque UUID/record/zone names, timestamps, and the
single facade-owned `Packages/FoqosShared/Sources/FoqosShared/Log.swift` `os_log` call. The pass
fixture with four static preview calls must report four analyzed sites, proving previews remain in
coverage.

- [ ] **Step 5: Run the harness to establish RED**

Run:

```bash
ruby scripts/test-check-log-privacy.rb
```

Expected: nonzero with a clear failure that `scripts/check-log-privacy.rb` does not exist. The test
harness itself must parse successfully:

```bash
ruby -c scripts/test-check-log-privacy.rb
```

Expected: `Syntax OK`.

- [ ] **Step 6: Commit the RED fixtures**

```bash
git add scripts/test-check-log-privacy.rb scripts/fixtures/log-privacy
git commit -S -m "test: define log privacy lint contract"
```

---

### Task 2: Implement the fail-closed Ruby analyzer

**Files:**

- Create: `scripts/check-log-privacy.rb`
- Create: `scripts/log-privacy-baseline.txt`
- Create: `scripts/log-privacy-annotation-baseline.txt`
- Modify: `scripts/test-check-log-privacy.rb`

**Interfaces:**

- Consumes: `--root PATH`, the five exact production roots, a deliberately temporary site baseline
  integer `494` while the nine direct sinks still exist, annotation baseline integer `0`, and exact facade sink path
  `Packages/FoqosShared/Sources/FoqosShared/Log.swift`.
- Produces: Xcode diagnostics `path:line: error: message`, exit codes `0/1/2`, and the success line
  `Log privacy lint passed: files_discovered=N files_analyzed=N sites_analyzed=N annotations=N`.

- [ ] **Step 1: Implement strict CLI, discovery, and baseline parsing**

Use only Ruby standard-library files `optparse`, `pathname`, and `set`. Define these exact public
boundaries inside `module LogPrivacy`:

```ruby
PRODUCTION_ROOTS = %w[
  Foqos
  FoqosWidget
  FoqosDeviceMonitor
  FoqosShieldConfig
  Packages/FoqosShared/Sources
].freeze

FACADE_PATH = "Packages/FoqosShared/Sources/FoqosShared/Log.swift"

Finding = Struct.new(:path, :line, :message, keyword_init: true)
Analysis = Struct.new(
  :files_discovered, :files_analyzed, :sites_analyzed, :annotations, :findings,
  keyword_init: true
)

def self.run(argv) -> Integer
def self.production_files(root) -> Array[Pathname]
def self.read_nonnegative_integer(path, label:) -> Integer
```

Require exactly one readable directory from `--root`, require every production root, sort all
readable `.swift` paths, reject malformed/negative/multi-line baselines, and distinguish a confirmed
finding from an analyzer exception. Do not recover from any read or parse exception by returning an
empty file/site list.

- [ ] **Step 2: Implement balanced facade-call extraction**

Add a byte-oriented `SwiftLexer` with these interfaces:

```ruby
Call = Struct.new(
  :path, :line, :level, :source, :message_source, :interpolations,
  keyword_init: true
)

class SwiftLexer
  def initialize(path, source); end
  def log_calls -> Array[Call]; end
  def direct_sink_findings -> Array[Finding]; end
  def annotation_count -> Integer; end
end
```

Track ordinary strings, multiline strings, raw-string hash counts, escaped characters, line and
nested block comments, balanced parentheses, and nested interpolation parentheses. Recognize only
standalone `Log.debug/info/warning/error` tokens; reject `lockLog.warning` and longer identifier/member
chains. For every recognized token, return one complete balanced call or raise an analysis error at
its starting line. Parse the first argument as a string literal and extract every interpolation
expression with its source line. Reject a whole-message variable/property with exit `2` while
allowing only the literal formatters named in the design.

- [ ] **Step 3: Implement direct-sink and privacy classification**

Define semantic predicates rather than a blanket property-name ban:

```ruby
def sensitive_expression?(expression) -> Boolean
def safe_expression?(expression) -> Boolean
def whole_object_expression?(expression) -> Boolean
def bare_error_expression?(expression) -> Boolean
```

Fail direct person/member/participant display names, `nameComponents`, email, phone, raw URL/query,
coordinate/latitude/longitude, replayable NFC/QR identifiers, known PII-bearing whole objects, and
`String(describing:)` around them. Require receiver context so `member.displayName` fails while
`member.role.displayName` passes. Allow exactly the semantic instruments in the final design,
including `error.localizedDescription` and `redactedErrorForLog(error)` only as interpolation
expressions. Ban `Logger(`, `NSLog(`, and all `os_log(` except the exact facade path.

- [ ] **Step 4: Implement bounded local-origin analysis and annotations**

For suspicious bare local identifiers, scan backward only within the enclosing function/closure,
find the nearest `let`/`var` assignment, and recursively classify its right-hand side. Stop at the
function/closure boundary and reject parameters, `self` properties, nested-closure assignments,
missing assignments, and ambiguous multiple origins with exit `2`. Preserve the historical
`nameComponents/emailAddress -> displayInfo -> Log.debug` failure.

Accept only an immediately adjacent annotation matching:

```text
// LOG-PRIVACY-SAFE: at least one non-whitespace reason character
```

Count all valid annotations across production files and require exact equality with
`scripts/log-privacy-annotation-baseline.txt`. Empty, detached, or malformed annotations do not
suppress analysis.

- [ ] **Step 5: Enforce coverage and stable exits**

Increment `files_analyzed` only after complete lexing and classification. Require discovered and
analyzed file counts to match exactly. Require `sites_analyzed >= site_floor`; on a drop print:

```text
coverage shrank from BASELINE to N — if you deliberately removed log calls, lower the baseline; if you
did not, the analyzer is missing sites
```

Print all confirmed privacy findings and return `1`; return `2` for configuration, lexing, origin,
or coverage failures. Never let a lower baseline suppress a file mismatch or parse error.

- [ ] **Step 6: Run fixture suite to GREEN and production scan to intentional RED**

```bash
ruby -c scripts/check-log-privacy.rb
ruby scripts/test-check-log-privacy.rb
ruby scripts/check-log-privacy.rb --root "$PWD"
```

Expected: syntax is valid; all isolated fixtures pass; the temporary production floor is `494`, and
production exits `1` and reports the known
direct sinks, bare-error interpolations, dynamic preview interpolations, and any genuine historical
sensitive sites. It must report all production files as analyzed before source migrations begin.

- [ ] **Step 7: Commit the analyzer**

```bash
git add scripts/check-log-privacy.rb scripts/log-privacy-baseline.txt \
  scripts/log-privacy-annotation-baseline.txt scripts/test-check-log-privacy.rb
git commit -S -m "feat: add fail-closed log privacy analyzer"
```

---

### Task 3: Add the bounded shared error formatter using Swift TDD

**Files:**

- Create: `Packages/FoqosShared/Sources/FoqosShared/LogPrivacy.swift`
- Create: `FoqosTests/LogPrivacyTests.swift`

**Interfaces:**

- Produces: `public func redactedErrorForLog(_ error: any Error) -> String`.
- Contract: one line, at most `2_048` Swift `Character` values, recursive depth at most `3`, cycle
  detection, drop-by-default `userInfo`, enum type/case preservation, and audited nested-error
  recursion.

- [ ] **Step 1: Write formatter RED tests**

Define private test probes without custom descriptions:

```swift
private enum PayloadFreeProbe: Error { case offline }
private enum AssociatedProbe: Error {
  case rejected(secret: String)
  case wrapped(secret: String, error: Error)
}

private final class CyclicProbe: Error, CustomNSError {
  static var errorDomain: String { "LogPrivacyTests.CyclicProbe" }
  var errorUserInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
}
```

Add tests named for these outcomes:

- domain, numeric code, and localized description are present;
- embedded CR/LF become spaces and output has no newline;
- a 3,000-character description yields exactly 2,048 characters;
- an underlying chain deeper than three stops at the depth marker;
- `CyclicProbe` terminates and includes the cycle marker;
- payload-free `PayloadFreeProbe.offline` includes `PayloadFreeProbe.offline`;
- `AssociatedProbe.rejected(secret: "DO-NOT-LOG")` includes `rejected` but omits the secret;
- `AssociatedProbe.wrapped(secret:error:)` omits the secret and includes the nested audited error;
- a non-allowlisted `userInfo["authToken"] = "DO-NOT-LOG"` value is absent;
- `CKPartialErrorsByItemIDKey` retains only `recordName` and `zoneName` plus the nested formatted
  error, and never renders arbitrary record fields or non-allowlisted metadata.

- [ ] **Step 2: Run the focused test to verify RED**

```bash
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/LogPrivacyTests | xcpretty
```

Expected: compile failure because `redactedErrorForLog` is undefined.

- [ ] **Step 3: Implement the minimal audited formatter**

Import `CloudKit` and `Foundation`. Keep implementation details internal/private and expose only:

```swift
public func redactedErrorForLog(_ error: any Error) -> String {
  ErrorLogRedactor().format(error)
}
```

`ErrorLogRedactor` must use constants `maxDepth = 3` and `maxCharacters = 2_048`, normalize all
newline forms before truncating, and carry a `Set<ObjectIdentifier>` for bridged `NSError`
identities. For native non-`LocalizedError` enum values, inspect `Mirror.displayStyle == .enum`, use
`String(describing:)` only when the enum has no children, otherwise emit only the first child's case
label. Walk associated payload mirrors solely to locate values conforming to `Error`; never call
`String(describing:)` on non-error payloads. Route found errors back through the same formatter with
incremented depth.

For `NSError`, emit domain/code/localizedDescription. Read only `NSUnderlyingErrorKey` and
`CKPartialErrorsByItemIDKey`; drop every other `userInfo` key. For partial-error dictionary keys,
emit only `CKRecord.ID.recordName` and `.zoneID.zoneName` (or the equivalent opaque string key),
then format each error value recursively. Sort partial entries by their emitted opaque identifier so
tests and logs are deterministic.

- [ ] **Step 4: Run focused formatter tests to GREEN**

Run the same serialized focused test command. Expected: all `LogPrivacyTests` pass with no secret
payload, arbitrary `userInfo`, newline, over-depth chain, or cycle leakage.

- [ ] **Step 5: Commit the formatter and tests**

```bash
git add Packages/FoqosShared/Sources/FoqosShared/LogPrivacy.swift FoqosTests/LogPrivacyTests.swift
git commit -S -m "feat: add bounded error log redaction"
```

---

### Task 4: Migrate production sinks and preview messages until the analyzer is GREEN

**Files:**

- Modify: `FoqosDeviceMonitor/DeviceActivityMonitorExtension.swift`
- Modify: `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift`
- Modify: `scripts/log-privacy-baseline.txt`
- Modify: the 19 current bare-error files under `Foqos/` listed below
- Modify: `Foqos/Views/ModeSelectionView.swift`
- Modify: `Foqos/Components/Strategy/QRCodeScanner.swift`
- Modify: `Foqos/Components/Settings/MapLocationPicker.swift`

**Interfaces:**

- Consumes: `Log.info/warning`, `redactedErrorForLog(_:)`, and analyzer diagnostics.
- Produces: at least `503` production facade sites, no banned direct sinks, no bare whole-error
  interpolation, and four static preview messages that still count as sites.

- [ ] **Step 1: Migrate the nine direct `Logger` calls**

Remove the private `Logger` instances and now-unused `OSLog` imports. Change the two monitor interval
messages to `Log.info(..., category: .timer)` and the seven SharedData lock messages to
`Log.warning(..., category: .app)`. Preserve the original static text and safe `errno` integers.
After those nine calls exist, change `scripts/log-privacy-baseline.txt` from the explicitly temporary
`494` to the final maintained floor `503`; do not raise it before the sinks are migrated.

- [ ] **Step 2: Mechanically migrate all analyzer-reported bare errors**

Replace only whole error expressions inside literal `Log.*` messages:

```swift
Log.error("Failed: \(error)", category: .cloudKit)
// becomes
Log.error("Failed: \(redactedErrorForLog(error))", category: .cloudKit)
```

Apply the analyzer-reported 70-site migration across these exact current files, preserving message
copy, level, category, and surrounding control flow:

```text
Foqos/FoqosApp.swift
Foqos/Views/BlockedProfileListView.swift
Foqos/Views/Parent/ParentDashboardView.swift
Foqos/Utils/AuthorizationVerifier.swift
Foqos/Utils/RequestAuthorizer.swift
Foqos/Utils/LockCodeManager.swift
Foqos/Utils/StrategyManager.swift
Foqos/Utils/TimersUtil.swift
Foqos/Utils/HeartbeatManager.swift
Foqos/Components/Sync/AppSelectionPrompt.swift
Foqos/CloudKit/ShareCoordinator.swift
Foqos/CloudKit/CloudKitNetworkService.swift
Foqos/CloudKit/CloudKitNetworkService+AccountAndZones.swift
Foqos/CloudKit/CloudKitNetworkService+Commands.swift
Foqos/CloudKit/CloudKitNetworkService+FamilyMembers.swift
Foqos/CloudKit/CloudKitNetworkService+Heartbeat.swift
Foqos/CloudKit/CloudKitNetworkService+LockCodes.swift
Foqos/CloudKit/CloudKitNetworkService+Sharing.swift
Foqos/CloudKit/CloudKitNetworkService+Verification.swift
```

Use the analyzer—not raw grep—as the authoritative 70-site count because balanced multiline calls
are the contract. Do not change existing
`error.localizedDescription` interpolations.

- [ ] **Step 3: Make the four preview messages static**

Use these exact replacements while retaining all four calls:

```swift
Log.debug("Selected preview mode", category: .ui)
Log.debug("Preview scanning failed", category: .ui)
Log.debug("Selected preview location", category: .ui)
Log.debug("Selected alternate preview location", category: .ui)
```

- [ ] **Step 4: Run formatter tests and production analyzer**

```bash
ruby scripts/test-check-log-privacy.rb
ruby scripts/check-log-privacy.rb --root "$PWD"
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/LogPrivacyTests | xcpretty
```

Expected: Ruby fixtures pass; production reports equal discovered/analyzed counts, at least 503
sites, zero annotations, and no findings; focused Swift tests pass.

- [ ] **Step 5: Commit production migrations**

```bash
git add Foqos FoqosDeviceMonitor Packages/FoqosShared/Sources/FoqosShared/SharedData.swift \
  scripts/log-privacy-baseline.txt
git commit -S -m "fix: migrate production logs to privacy-safe sinks"
```

---

### Task 5: Enforce the lint in Xcode and advance the release version

**Files:**

- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: `ruby scripts/check-log-privacy.rb --root "${SRCROOT}"`.
- Produces: an always-out-of-date `Log Privacy Lint` phase before Sources and uniform project
  settings `MARKETING_VERSION = 2.0.8`, `CURRENT_PROJECT_VERSION = 27`.

- [ ] **Step 1: Add the pre-Sources shell phase**

Add a new `PBXShellScriptBuildPhase` identifier and insert it in the `FamilyFoqos` target after the
existing concurrency lint and before `801B20912DE6C78C00B77FE1 /* Sources */`. Set
`alwaysOutOfDate = 1`, list the analyzer, both baselines, and all five production roots in
`inputPaths`, and use exactly:

```sh
command -v ruby >/dev/null 2>&1 || {
  echo "error: Log Privacy Lint requires ruby on PATH" >&2
  exit 2
}
ruby "${SRCROOT}/scripts/check-log-privacy.rb" --root "${SRCROOT}"
```

- [ ] **Step 2: Bump all project configurations uniformly**

Replace every `CURRENT_PROJECT_VERSION = 26;` with `27` and every
`MARKETING_VERSION = 2.0.7;` with `2.0.8`. Verify unique values:

```bash
rg -n 'CURRENT_PROJECT_VERSION|MARKETING_VERSION' FamilyFoqos.xcodeproj/project.pbxproj
```

- [ ] **Step 3: Verify gates and measure warm analyzer latency**

```bash
bash scripts/test-check-version-increment.sh
bash scripts/check-version-increment.sh 0314fee HEAD
ruby scripts/test-check-log-privacy.rb
/usr/bin/time -p ruby scripts/check-log-privacy.rb --root "$PWD"
/usr/bin/time -p ruby scripts/check-log-privacy.rb --root "$PWD"
/usr/bin/time -p ruby scripts/check-log-privacy.rb --root "$PWD"
/usr/bin/time -p ruby scripts/check-log-privacy.rb --root "$PWD"
/usr/bin/time -p ruby scripts/check-log-privacy.rb --root "$PWD"
```

Record all five `real` values, their median, and maximum for the PR body. Each warm run must be below
2.0 seconds. If any warm run exceeds 2.0 seconds, stop and request review of a full-scan cache keyed
by every file path/mtime/size plus analyzer and baseline digests; do not scope to changed files or
disable the phase.

- [ ] **Step 4: Build once to prove the phase executes**

```bash
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build \
  2>&1 | xcpretty
```

Expected: `Log Privacy Lint` runs and the Debug build succeeds.

- [ ] **Step 5: Commit build integration and version**

```bash
git add FamilyFoqos.xcodeproj/project.pbxproj
git commit -S -m "build: enforce log privacy lint"
```

---

### Task 6: Run final serialized verification and request review

**Files:**

- Modify only if verification exposes a scoped defect; every fix receives a new signed commit.

**Interfaces:**

- Produces: complete verification evidence and an independent review request; no merge is performed
  by the implementer.

- [ ] **Step 1: Run static and script verification**

```bash
git diff --check 0314fee...HEAD
ruby -c scripts/check-log-privacy.rb
ruby -c scripts/test-check-log-privacy.rb
ruby scripts/test-check-log-privacy.rb
ruby scripts/check-log-privacy.rb --root "$PWD"
swift-format lint --recursive .
bash scripts/test-check-version-increment.sh
bash scripts/check-version-increment.sh 0314fee HEAD
```

Expected: all commands exit `0`; analyzer totals show equal file counts, at least 503 sites, and zero
annotations.

- [ ] **Step 2: Run the full iOS suite serially**

```bash
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos 2>&1 | xcpretty
```

Expected: all tests pass. Capture the executed test count and zero-failure summary.

- [ ] **Step 3: Run the final Debug build serially**

```bash
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos -configuration Debug build \
  2>&1 | xcpretty
```

Expected: `BUILD SUCCEEDED` after the log privacy phase passes.

- [ ] **Step 4: Inspect scope and signatures**

```bash
git status --short
git diff --stat 0314fee...HEAD
git log --show-signature --oneline 0314fee..HEAD
```

Expected: clean worktree, only #360/spec/plan files changed, and every commit has a good signature.

- [ ] **Step 5: Send independent review requests**

Use AMQ to send the reviewer the branch, exact HEAD, design, plan, analyzer totals, latency median/max,
test count, build result, and focused requests to audit fail-closed parsing, annotation/site coverage,
the exhaustive formatter allowlist, enum associated-value omission, and Xcode phase ordering. Send
the planner a status message with the same evidence. Do not merge; the planner owns merge after
approval.
