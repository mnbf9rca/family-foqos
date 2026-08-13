# CloudKit Code-to-Schema Drift Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an XCTest gate that fails closed when CloudKit fields written by Swift drift from the checked-in `.ckdb` schema.

**Architecture:** A test-only validator recursively derives every Swift file below `Foqos`, discovers the three supported write-key shapes, and parses checked-in `RECORD TYPE` blocks. It compares code fields as a subset of schema fields, treats `SyncedSession` as the sole pinned read/delete-only exception, and exposes deterministic errors for unsupported declarations, missing fields, and missing record types.

**Tech Stack:** Swift, XCTest, Foundation file enumeration and regular expressions, Xcode simulator tests.

## Global Constraints

- Keep the implementation in one new `FoqosTests/CloudKitCodeSchemaDriftTests.swift` file; do not add production API.
- Derive source files recursively from `Foqos`; do not maintain a hand-written source-file list.
- Fail closed on every non-enumerable active record declaration; only `SyncedSession` may be fieldless.
- Treat code fields as a subset of schema fields; additive schema-only fields remain valid.
- Pin 13 active record types and 101 fields with the exact per-type counts from issue #383.
- Use the repository Xcode stream wrapper and simulator UUID injection; never pass a simulator name or caller destination.
- Bump all build settings from marketing version `2.0.26` / build `45` to `2.0.27` / `46`.

---

### Task 1: Prove the test contract RED

**Files:**
- Create: `FoqosTests/CloudKitCodeSchemaDriftTests.swift`

**Interfaces:**
- Consumes: temporary fixture roots containing `Foqos/**/*.swift` and `Foqos/CloudKit/cloudkit-schema.ckdb`.
- Produces: tests for `CloudKitSchemaDriftValidator.validate(repoRoot:) -> [String: Set<String>]` and deterministic `CloudKitSchemaDriftError` cases.

- [ ] **Step 1: Add focused tests before the validator exists**

Add XCTest cases that:

```swift
func testGivenEverySupportedPattern_WhenValidating_ThenDiscoversLiteralWireKeys()
func testGivenUnsupportedDeclarationInNestedPlantedFile_WhenValidating_ThenFailsClosed()
func testGivenCodeFieldMissingFromSchema_WhenValidating_ThenReportsField()
func testGivenWrittenRecordTypeMissingFromSchema_WhenValidating_ThenReportsType()
func testGivenRepositorySources_WhenValidating_ThenMatchesPinnedBaseline()
```

The positive fixture must contain a `FieldKey: String` enum with implicit and explicit raw values, a `RecordKey` constants enum, and a literal `CKRecord(recordType:)` variable with a string-subscript write. The planted-file fixture must place an unsupported `FieldKey` declaration below a nested `Foqos` directory so the failure proves recursive discovery is live.

- [ ] **Step 2: Run the focused class and verify RED**

Run:

```bash
./scripts/xcode-stream.sh --agent build2 --session collab --xcpretty -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/CloudKitCodeSchemaDriftTests
```

Expected: compile failure because `CloudKitSchemaDriftValidator` and `CloudKitSchemaDriftError` do not exist.

### Task 2: Implement the minimal fail-closed validator GREEN

**Files:**
- Modify: `FoqosTests/CloudKitCodeSchemaDriftTests.swift`

**Interfaces:**
- Consumes: repository root URL, recursively derived Swift source URLs, and `.ckdb` text.
- Produces: `[recordType: Set<fieldName>]` or a typed error identifying the unsupported declaration or missing schema entry.

- [ ] **Step 1: Add deterministic error and validator types below the test class**

Use private test-only types with these responsibilities:

```swift
private enum CloudKitSchemaDriftError: Error, Equatable {
  case unreadableInput(String)
  case unsupportedDeclaration(file: String, line: String)
  case unableToEnumerate(recordType: String)
  case ambiguousLiteralVariable(file: String, variable: String)
  case missingRecordType(String)
  case missingField(recordType: String, field: String)
}

private struct CloudKitSchemaDriftValidator {
  static func validate(repoRoot: URL) throws -> [String: Set<String>]
}
```

- [ ] **Step 2: Derive source files and parse keyed declarations**

Enumerate readable `.swift` files recursively below `repoRoot/Foqos`, sorted by path. Associate each `static let recordType = "…"` with the following `FieldKey` or `RecordKey` block before the next record type. Accept only these current declaration forms:

```swift
case implicitName
case swiftName = "wireName"
static let swiftName = "wireName"
```

Reject every other non-comment line in a key block. Require at least one key for every static record type except the exact `SyncedSession` pin.

- [ ] **Step 3: Parse literal record writes and checked-in schema blocks**

Discover literal assignments shaped like:

```swift
let rootRecord = CKRecord(recordType: "FamilyRoot", recordID: rootRecordID)
rootRecord["createdAt"] = Date()
```

Map a literal variable to exactly one record type per source file and fail if it is ambiguous. Parse all `.ckdb` `RECORD TYPE` blocks into type/field sets, retaining record types even when their field set is empty and ignoring CloudKit system fields prefixed with `___`.

- [ ] **Step 4: Compare code to schema fail-closed**

For every code record type in sorted order, first require a matching schema block and then require every code field in sorted order. Throw `missingRecordType` or `missingField` at the first drift. Never reject schema-only record types or fields.

- [ ] **Step 5: Run the focused class and verify GREEN**

Run the Task 1 command. Expected: all five tests pass, including the live planted-file discovery failure.

- [ ] **Step 6: Mutation-check every discovery control**

Temporarily disable each of the three parser paths one at a time—`FieldKey`, `RecordKey`, and literal writes—and rerun the positive fixture. Each mutation must fail. Restore the implementation and rerun the focused class green.

### Task 3: Pin release version and verify the branch

**Files:**
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`
- Test: `FoqosTests/CloudKitCodeSchemaDriftTests.swift`

**Interfaces:**
- Consumes: version-gate policy and the complete XCTest target.
- Produces: release versions `2.0.27` / `46` and a review-ready branch.

- [ ] **Step 1: Bump every target/configuration version setting**

Change all 12 occurrences each:

```text
MARKETING_VERSION = 2.0.27;
CURRENT_PROJECT_VERSION = 46;
```

- [ ] **Step 2: Run formatting and project/version checks**

Run:

```bash
swift-format --in-place FoqosTests/CloudKitCodeSchemaDriftTests.swift
swift-format lint FoqosTests/CloudKitCodeSchemaDriftTests.swift
plutil -lint FamilyFoqos.xcodeproj/project.pbxproj
./scripts/test-check-version-increment.sh
rg -c 'MARKETING_VERSION = 2\.0\.27;' FamilyFoqos.xcodeproj/project.pbxproj
rg -c 'CURRENT_PROJECT_VERSION = 46;' FamilyFoqos.xcodeproj/project.pbxproj
git diff --check
```

Expected: every command exits 0.

- [ ] **Step 3: Run focused and full XCTest verification**

Run the focused command from Task 1, then:

```bash
./scripts/xcode-stream.sh --agent build2 --session collab --xcpretty -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos
```

Expected: the focused class and full suite pass with zero failures.

- [ ] **Step 4: Commit without amending**

```bash
git add FoqosTests/CloudKitCodeSchemaDriftTests.swift \
  FamilyFoqos.xcodeproj/project.pbxproj \
  docs/superpowers/plans/2026-08-13-cloudkit-code-schema-drift-test.md
git commit -S -m "Test CloudKit code schema drift"
./scripts/check-version-increment.sh 8780bfb HEAD
git verify-commit HEAD
```

- [ ] **Step 5: Request code review before merge**

Push the branch, open a draft PR that closes #383 and records RED/GREEN plus mutation evidence, then request reviewer inspection through AMQ. Undraft only after a `READY` verdict; the maintainer owns merge.
