# Rename-Invariant Log Privacy Taint Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every log-privacy rule invariant to local and receiver identifier renames while preserving fail-closed behavior and the zero-annotation production baseline.

**Architecture:** Replace the spelling-gated local check with bounded per-function declaration and assignment analysis. Direct sensitive accessors become receiver-independent; declared sensitive types and assignment dependencies propagate taint recursively with cycle protection; message context only adds findings and never proves safety.

**Tech Stack:** Ruby 4, the existing custom Swift lexer/analyzer, fixture-driven subprocess tests, Swift/XCTest, Xcode build phases.

## Global Constraints

- Work only on `feat/log-privacy-lint`; never amend or force a commit.
- Run Xcode work only through `scripts/xcode-stream.sh --agent build2 --session collab --`.
- Keep `scripts/log-privacy-annotation-baseline.txt` exactly `0`.
- Preserve equal discovered/analyzed file counts, at least `503` production sites, and fail-closed exit `2` for ambiguity.
- Message-literal context may add suspicion but may never clear or downgrade suspicion.
- Do not change `redactedErrorForLog`, add a cache, or add general interprocedural Swift analysis.
- Request independent reviewer approval before merge; the planner owns merging.

---

### Task 1: Prove every identifier-bearing fail rule is rename-invariant

**Files:**

- Create: renamed twins under `scripts/fixtures/log-privacy/fail/renamed/`
- Modify: `scripts/test-check-log-privacy.rb`

**Interfaces:**

- Consumes: the existing `Case` fixture runner and analyzer exit/diagnostic contract.
- Produces: a failing adversarial suite in which each renamed twin expects the same exit status and diagnostic as its original fixture.

- [ ] **Step 1: Add renamed twin fixtures**

Create twins with identical behavior and only neutral identifier substitutions:

```text
multiline_display_name.swift: member -> m
laundered_display_info.swift: participant -> p, displayInfo -> label
bare_error.swift: error -> e
raw_url.swift: url -> u
coordinates.swift: coordinate -> c
nfc_identifier.swift: tagIdentifier -> value
qr_identifier.swift: qrCode -> value
participant_contact.swift: participant -> p
whole_member.swift: member -> m
string_describing_member.swift: member -> m
logger.swift: logger -> sink, directLogger -> sink2
message_variable.swift: message -> payload
unresolved_origin.swift: displayInfo -> info
valid_annotation.swift: displayInfo -> info
```

Add the decisive multi-hop #359 twin:

```swift
func report(participant: CKShare.Participant) {
  let a = participant.userIdentity.nameComponents?.formatted() ?? ""
  let b = participant.userIdentity.lookupInfo?.emailAddress ?? ""
  let c = !a.isEmpty ? a : b
  Log.debug("Participant \(c) status", category: .cloudKit)
}
```

Do not duplicate `NSLog`, `os_log`, or the unbalanced-call fixture because they contain no renameable identifier. Keep every renamed twin's `status`, `diagnostic`, `site_floor`, and `annotation_count` identical to its original `Case`.

- [ ] **Step 2: Run the adversarial suite and verify RED**

```bash
ruby scripts/test-check-log-privacy.rb
```

Expected: nonzero exit. The display, whole-object, bare-error, coordinate, NFC, QR, unresolved-origin, laundered-local, and multi-hop twins report analyzer status `0` where their `Case` requires `1` or `2`. Existing original cases remain passing.

- [ ] **Step 3: Commit the RED contract**

```bash
git add scripts/fixtures/log-privacy/fail/renamed scripts/test-check-log-privacy.rb
git commit -S -m "test: expose identifier-renaming privacy bypass"
```

---

### Task 2: Replace spelling gates with bounded semantic taint

**Files:**

- Modify: `scripts/check-log-privacy.rb`
- Modify only if the stricter analyzer exposes an ambiguous production log: the exact affected Swift file under one of the five production roots

**Interfaces:**

- Consumes: `SwiftLexer#source`, `Call#message_source`, `Call#message_offset`, the semantic `SAFE_PATTERNS`, and renamed fixture expectations.
- Produces: receiver-independent direct findings plus a private classification pipeline returning `:safe`, a finding message, or `:ambiguous` for every analyzed local origin.

- [ ] **Step 1: Introduce semantic declarations and remove the spelling trigger**

Add exact private analyzer constants for sensitive declared types and message contexts. Remove `SUSPICIOUS_LOCAL` and `suspicious_local?`.
Add `require 'set'` because recursive resolution uses a per-call `Set` for cycle protection.

```ruby
SENSITIVE_TYPE_RULES = {
  /(?:^|\W)(?:any\s+)?Error\b|NSError\b/ =>
    'whole Error interpolation is prohibited; use redactedErrorForLog(error)',
  /\b(?:FamilyMember|CKShare\.Participant|CKUserIdentity)\b/ =>
    'whole object interpolation may expose participant data',
  /\b(?:URL|NSURL)\b/ =>
    'raw URL interpolation is prohibited; use redactedURLString',
  /\b(?:CLLocationCoordinate2D|CLLocation)\b/ =>
    'raw coordinate interpolation is prohibited'
}.freeze

SENSITIVE_CONTEXT_RULES = {
  /\b(?:nfc|tag)\b/i => 'replayable NFC identifier interpolation is prohibited',
  /\bqr\b|\bscann(?:ed|ing)?\s+code\b/i =>
    'replayable QR identifier interpolation is prohibited'
}.freeze
```

Change `analyze_interpolations` so every non-allowlisted expression is checked directly, then any simple identifier or `String(describing: identifier)` is resolved semantically. An adjacent annotation remains the only escape for an ambiguous resolved origin.

- [ ] **Step 2: Make direct accessor rules receiver-independent**

Replace name-gated rules with accessor-chain rules:

```ruby
def sensitive_display_name?(expression)
  expression.match?(/\.displayName\b/) &&
    !expression.match?(/\.(?:role|mode|ruleType)\.displayName\b/)
end

def participant_contact?(expression)
  expression.match?(/\.(?:nameComponents|emailAddress|phoneNumber)\b/)
end
```

Keep URL, coordinate, NFC, and QR syntactic checks as add-only signals. They may produce findings early but must not mark any other expression safe.

- [ ] **Step 3: Extract bounded declarations and assignments**

Use source only before `call.message_offset`, starting at the closest preceding `func` or `init`. Parse parameter declarations from the signature and `let`/`var` declarations before the call into a private hash keyed by identifier:

```ruby
Declaration = Struct.new(:name, :type, :origin, keyword_init: true)
```

For local assignments, bound the right-hand side at a top-level semicolon or the first later line at the declaration's indentation after delimiter depth returns to zero. Preserve indented continuation lines so `??`, ternaries, and nested calls remain inside the origin. If the boundary cannot be established, classify the origin as ambiguous rather than scanning the remainder of the function.

- [ ] **Step 4: Resolve taint recursively with cycle protection**

Implement private methods with these contracts:

```ruby
def analyze_semantic_origin(expression, call, interpolation, lexer)
  # Finding, nil for proven safe, or raise AnalysisError for ambiguity
end

def classify_identifier(identifier, declarations, context, visiting = Set.new)
  # [:safe, nil], [:sensitive, diagnostic], or [:ambiguous, nil]
end
```

Classification order is fail-safe:

1. A sensitive declared type returns its rule's finding.
2. An explicit audited formatter or existing semantic safe pattern returns safe.
3. A direct sensitive accessor in the assignment returns its rule's finding.
4. Every referenced identifier that exists in the declaration map is resolved recursively; any sensitive dependency taints the assignee.
5. A context rule may turn an otherwise opaque value into a finding.
6. Literal-only and exact safe scalar origins return safe.
7. Missing declarations, cycles, and unresolved origins are ambiguous and raise exit `2` unless the call has the counted adjacent annotation.

The multi-hop `c -> a,b -> participant identity accessors` must return a participant-contact finding even though `a`, `b`, and `c` are neutral names.

- [ ] **Step 5: Run renamed fixtures and iterate only on semantic failures**

```bash
ruby scripts/test-check-log-privacy.rb
```

Expected: every original and renamed case passes. If a renamed twin has the wrong status, fix analyzer classification rather than weakening the fixture.

- [ ] **Step 6: Run production and preserve the zero-annotation baseline**

```bash
ruby scripts/check-log-privacy.rb --root "$PWD"
```

Expected: `files_discovered=232 files_analyzed=232 sites_analyzed=503 annotations=0` with no findings. If an existing site is now ambiguous, prefer removing the ambiguous interpolation or routing it through an already-audited semantic formatter. Do not add annotations or name-based allowlists.

- [ ] **Step 7: Verify Ruby quality and uncached performance**

```bash
ruby -c scripts/check-log-privacy.rb
ruby -c scripts/test-check-log-privacy.rb
bundle exec rubocop scripts/check-log-privacy.rb scripts/test-check-log-privacy.rb
/usr/bin/time -p ruby scripts/check-log-privacy.rb --root "$PWD"
/usr/bin/time -p ruby scripts/check-log-privacy.rb --root "$PWD"
/usr/bin/time -p ruby scripts/check-log-privacy.rb --root "$PWD"
/usr/bin/time -p ruby scripts/check-log-privacy.rb --root "$PWD"
/usr/bin/time -p ruby scripts/check-log-privacy.rb --root "$PWD"
```

Expected: syntax and RuboCop pass; every full uncached run is below `2.0s`. Record median and maximum.

- [ ] **Step 8: Commit the semantic fix**

```bash
git add scripts/check-log-privacy.rb Foqos FoqosWidget FoqosDeviceMonitor FoqosShieldConfig Packages/FoqosShared/Sources
git commit -S -m "fix: make log privacy analysis rename-invariant"
```

---

### Task 3: Re-verify the branch and obtain independent approval

**Files:**

- Modify only if verification exposes a scoped defect; each correction receives a new signed commit.

**Interfaces:**

- Consumes: the complete #360 branch and the reviewer focus list.
- Produces: fresh test/build evidence and an explicit independent approval or actionable findings.

- [ ] **Step 1: Run all static gates**

```bash
git diff --check 0314fee...HEAD
ruby scripts/test-check-log-privacy.rb
ruby scripts/check-log-privacy.rb --root "$PWD"
swift-format lint --recursive .
bash scripts/test-check-version-increment.sh
bash scripts/check-version-increment.sh 0314fee HEAD
```

- [ ] **Step 2: Run focused formatter tests serially**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/LogPrivacyTests 2>&1 | bundle exec xcpretty
```

Expected: 10 tests, zero failures.

- [ ] **Step 3: Run the full iOS suite serially**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  2>&1 | bundle exec xcpretty
```

Expected: all tests pass; record the executed count.

- [ ] **Step 4: Run the final Debug build serially**

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build2 --session collab -- \
  xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -configuration Debug build 2>&1 | bundle exec xcpretty
```

Expected: `Log Privacy Lint` executes before Sources and the build succeeds.

- [ ] **Step 5: Inspect scope, cleanliness, and signatures**

```bash
git status --short
git diff --stat 0314fee...HEAD
git log --show-signature --format='%h %G? %s' 0314fee..HEAD
```

Expected: a clean worktree and `G` for every commit.

- [ ] **Step 6: Request reviewer re-approval and notify the planner**

Send the reviewer the exact HEAD, renamed RED evidence, final original/renamed fixture count, production totals, five latency values, focused/full iOS counts, build result, and explicit requests to audit rename invariance, assignment bounds, dependency recursion/cycles, add-only context, receiver-independent accessor exceptions, and zero annotations. Do not merge.
