# Multiline Log Privacy Lint Design

## Context

Issue #360 is the structural follow-up to the write-time privacy fixes in #386. At merged main
`0314fee`, the repository has 502 `Log.debug`/`info`/`warning`/`error` call sites, of which 494 are
outside `FoqosTests`. CI now has a strict required Version gate, and CodeQL covers Actions and Ruby,
but no automated check analyzes Swift log privacy.

The known #359 leak proves that a same-line regular expression is insufficient. Swift formatting
split the `Log.info(` call from `member.displayName`, and another leak first assigned participant
name/email values to a local `displayInfo` before interpolating that local. Enforcement therefore
has to understand complete calls and a bounded amount of local data flow.

## Goals

- Add a multiline-aware, fail-closed privacy analyzer to the Xcode build.
- Analyze all production Swift sources that can reach the shared logging system: `Foqos`,
  `FoqosWidget`, `FoqosDeviceMonitor`, `FoqosShieldConfig`, and `Packages/FoqosShared/Sources`.
- Catch direct sensitive interpolation, sensitive values laundered through locals, nonliteral
  messages, unresolved suspicious origins, and whole-object interpolation.
- Require the shared `Log` facade for all production log sinks.
- Preserve the established safe instruments from #386.
- Make analyzer coverage degradation visible and actionable rather than allowing a vacuous pass.
- Remove dynamic interpolation from every `#Preview` log call so previews need no remembered
  exception.

## Non-goals

- Do not gate Debug Mode or log export in Child mode. The maintainer explicitly rejected that
  design because broken lock-code sync is a reason support needs diagnostics from a child device.
- Do not add a pre-commit privacy rule. API-created commits bypass hooks.
- Do not redesign the logging facade, add runtime message scrubbing, change production log levels,
  add a logging toggle, alter file rotation, or change backup/file-protection behavior.
- Do not ban sensitive accessors throughout the application. Family-management UI legitimately
  displays participant names, email addresses, and phone numbers; enforcement is scoped to log
  sinks.
- Do not add SwiftSyntax or another package dependency solely for this lint.

## Considered approaches

### 1. Standard-library Ruby lexical analyzer — selected

A standalone Ruby script discovers production Swift files, lexes balanced calls across lines,
examines interpolations, and performs a bounded backward scan for local assignments. Ruby is
already present in the repository toolchain, is covered by CodeQL, needs no dependency resolution,
and is fast enough to run on every Xcode build. A state machine can fail explicitly when it cannot
balance or understand a call instead of silently returning no findings.

### 2. Shell and multiline regular expressions

This is smaller but cannot reliably balance nested calls, strings, comments, or interpolation. It
also cannot follow the `displayInfo` laundering shape that caused #359 or distinguish parse failure
from zero matches. It does not meet the acceptance criteria.

### 3. SwiftSyntax command-line tool

SwiftSyntax would provide the strongest syntax tree but adds a package, compile step, toolchain
compatibility surface, and substantial build latency for a bounded repository-specific rule. It is
disproportionate while the lexical analyzer can fail closed on unsupported syntax.

## Components and file responsibilities

- `scripts/check-log-privacy.rb` owns file discovery, Swift lexical scanning, sink enforcement,
  bounded local-origin analysis, diagnostics, and coverage assertions.
- `scripts/log-privacy-baseline.txt` contains the deliberately maintained production facade-site
  floor. Its initial value is `503` after the nine direct-sink migrations.
- `scripts/log-privacy-annotation-baseline.txt` contains the deliberately maintained count of
  `LOG-PRIVACY-SAFE` annotations. Its initial value is `0`; changing that exact count requires a
  visible, reviewed baseline edit.
- `scripts/test-check-log-privacy.rb` executes the real analyzer against isolated fixtures and the
  production tree. It does not mock analyzer behavior.
- `scripts/fixtures/log-privacy/` contains only explicit analyzer inputs. It is outside every
  production scan root and is passed to the analyzer by exact path in tests; there is no wildcard
  “fixture” exclusion that production code could exploit.
- `FamilyFoqos.xcodeproj/project.pbxproj` adds a `Log Privacy Lint` build phase that invokes the
  analyzer before Sources compilation.
- `FoqosDeviceMonitor/DeviceActivityMonitorExtension.swift` and
  `Packages/FoqosShared/Sources/FoqosShared/SharedData.swift` migrate nine direct `Logger` calls to
  the shared facade.
- `Packages/FoqosShared/Sources/FoqosShared/LogPrivacy.swift` owns the single audited
  `redactedErrorForLog(_:)` formatter. The 70 production facade sites that currently interpolate a
  bare error object migrate mechanically to this helper.
- `FoqosTests/LogPrivacyTests.swift` constructs bounded-chain, cyclic-chain, long-line, CloudKit
  partial-error, and rejected-`userInfo` fixtures against the real shared formatter.
- `Foqos/Views/ModeSelectionView.swift`, `Foqos/Components/Strategy/QRCodeScanner.swift`, and
  `Foqos/Components/Settings/MapLocationPicker.swift` remove the four remaining dynamic preview-log
  interpolations.
- The project version advances uniformly from `2.0.7`/`26` to `2.0.8`/`27`.

## Discovery and coverage contract

The production command receives the repository root and discovers every readable `.swift` file
under these exact roots:

1. `Foqos`
2. `FoqosWidget`
3. `FoqosDeviceMonitor`
4. `FoqosShieldConfig`
5. `Packages/FoqosShared/Sources`

`FoqosTests`, UI tests, documentation, and `scripts/fixtures` are intentionally outside that set.
The analyzer records a file as analyzed only after it has read and lexed the entire file without an
unsupported or unbalanced construct.

Two different coverage checks have deliberately different semantics:

- `files_analyzed == files_discovered` is a hard invariant. A mismatch exits as an analysis error
  and says it is not fixable by editing a number; the analyzer must successfully analyze every
  discovered file.
- `sites_analyzed >= 503` is a maintained floor. Falling below it reports both values and the
  direction: “coverage shrank from 503 to N — if you deliberately removed log calls, lower the
  baseline; if you did not, the analyzer is missing sites.” Legitimate additions do not require a
  ritual baseline edit. Legitimate removals lower the one-line baseline in the same reviewed diff.

The analyzer prints discovered-file, analyzed-file, and analyzed-site totals on success. Missing or
malformed roots, unreadable files, malformed baseline content, and unparseable calls are errors,
never zero findings.

## Swift call parsing

The scanner recognizes facade tokens only when `Log` is not part of a longer identifier or member
chain, preventing `lockLog.warning` from inflating coverage. It extracts each complete
`Log.debug`/`info`/`warning`/`error` call by balancing parentheses while tracking ordinary strings,
multiline strings, raw-string delimiters, line comments, block comments, escapes, and nested Swift
interpolations.

The parser must either return a complete call with its file and starting line or emit an analysis
error. It must never recover from an unsupported or unbalanced construct by skipping forward and
continuing with a smaller site count.

Production message arguments must be string literals or an explicitly allowlisted formatter such
as `ShareParticipantLog.statusMessage`. Passing a variable or property as the whole message, for
example `let msg = "..."; Log.debug(msg)`, is an analysis error because the sink no longer exposes
content to the checker.

## Privacy rules

The analyzer applies rules only inside log calls. The consented roster may continue to use
`member.displayName` because it is not a log sink.

### Direct sensitive expressions

Sensitive receiver-and-property combinations fail, including person/member/participant display
names, CloudKit participant `nameComponents`, `emailAddress`, `phoneNumber`, raw URL/query values,
coordinates/latitude/longitude, and replayable NFC/QR identifiers. Receiver context is required:
`member.displayName` fails while `member.role.displayName` passes.

### Established safe instruments

The following forms are accepted:

- `FamilyMember.redactedLogLabel`
- `ShareParticipantLog.label` and `ShareParticipantLog.statusMessage`
- `DebugRedaction` methods ending in `ForLog`
- `redactedURLString`
- role labels (`role.*`)
- collection counts (`*.count`)
- already permitted opaque UUID/CloudKit record-name forms and timestamps

The allowlist is intentionally semantic rather than a blanket property-name exemption.

### Bounded local-origin analysis

For an interpolated local, the analyzer scans backward within the enclosing function or closure for
its assignment. If the assignment uses a sensitive accessor, the sink fails even when the final
interpolation contains only the local identifier. This pins the historical
`name`/`email` → `displayInfo` → `Log.debug` shape.

A suspicious origin that cannot be resolved does not pass. Parameters, `self.cachedName`, locals
assigned in a nested closure, and other origins outside the bounded analysis produce an analysis
error or require a narrow adjacent `// LOG-PRIVACY-SAFE: <reason>` annotation. Empty annotations,
non-adjacent annotations, and annotations without a reason do not suppress a finding.

The analyzer counts every valid `LOG-PRIVACY-SAFE` annotation and requires the count to equal the
maintained annotation baseline, initially `0`. Additions and removals both require an explicit
baseline change in the same reviewed diff, so an escape hatch cannot appear or disappear silently.
An unresolved suspicious origin without a valid adjacent annotation is exit `2` because analysis
could not prove the interpolation safe; a resolved sensitive origin is exit `1` because it is a
confirmed privacy violation.

### Whole-object interpolation

Interpolating an object known to carry PII, such as `\(member)`, fails. Wrappers such as
`String(describing: member)` also fail. This prevents synthesized descriptions or reflection from
dumping stored properties while evading property-token checks.

Bare error interpolation, `\(error)`, is also prohibited whole-object interpolation because an
`NSError` description can include unaudited `userInfo`. `error.localizedDescription` remains
legal. Callers that need structured diagnostics use `redactedErrorForLog(error)` as an allowlisted
interpolation expression inside a literal message; it is not an allowlisted whole-message
formatter and therefore does not weaken the message-as-variable rule.

`redactedErrorForLog(_:)` emits a bounded, single-line representation containing the error domain,
numeric code, localized description, and only explicitly permitted CloudKit metadata. The
`userInfo` allowlist is exhaustive: opaque CloudKit record and zone names may be retained, while
every unlisted key and value is dropped. `NSUnderlyingError` and `CKPartialErrorsByItemID` are
expanded only to a depth of `3`, cycle detection stops repeated error identities, partial errors
are rendered per record identifier, embedded line breaks are normalized to spaces, and the final
line is truncated to `2,048` Swift `Character` values. A
malformed or cyclic chain therefore cannot hang or produce unbounded output. If the
CloudKit-specific implementation becomes disproportionate, the formatter ships with only
domain/code/localized-description and the enrichment is recorded as a follow-up in #383; the
bare-error ban and all 70 migrations still ship in this change.

Before bridging an error to `NSError`, the formatter preserves diagnostics for native Swift error
enums that do not conform to `LocalizedError`. When `Mirror.displayStyle == .enum`, it emits the
dynamic type name and case label. A payload-free case may obtain its case label from
`String(describing:)`; a case with associated values obtains only
`Mirror.children.first?.label`. Non-error associated values are never described or emitted. Any
associated value that itself conforms to `Error`, including an error nested inside a tuple payload,
is routed recursively through the same audited formatter under the existing depth, cycle, and line
caps. This retains nested failure structure without allowing arbitrary payloads back into the log.

### Direct sinks

`Logger(`, `os_log(`, and `NSLog(` are prohibited throughout production roots except for the single
`os_log` integration inside `Packages/FoqosShared/Sources/FoqosShared/Log.swift`. `print` is outside
scope because it is not persisted by the shared log facade.

`DeviceActivityMonitorExtension` moves its two interval messages to `Log.info`, and `SharedData`
moves seven lock warnings to `Log.warning`. This increases production facade coverage from 494 to
503 and leaves one audited sink implementation.

## Preview cleanup

There are four dynamic log interpolations inside `#Preview` blocks at the baseline:

- selected mode in `ModeSelectionView`
- scanner error text in `QRCodeScanner`
- two selected coordinates in `MapLocationPicker`

They become static preview event messages. Preview behavior remains useful without exporting sample
coordinates, mode values, or error descriptions, and the analyzer carries no preview exception.
The calls remain facade sites and still count toward the `503` production-site floor.

## Build integration and failure behavior

The `Log Privacy Lint` shell phase invokes only:

```sh
command -v ruby >/dev/null 2>&1 || {
  echo "error: Log Privacy Lint requires ruby on PATH" >&2
  exit 2
}
ruby "${SRCROOT}/scripts/check-log-privacy.rb" --root "${SRCROOT}"
```

It runs before Sources, is always out of date, and lists the analyzer, both baselines, and
production roots as inputs. The pre-commit hook remains unchanged. The warm production scan must complete in
under `2.0` seconds on the implementation machine, measured over five consecutive direct runs;
the PR body records the median and maximum. If it exceeds that budget, implementation stops for a
reviewed caching design keyed by every discovered file's path, modification time, and size plus the
analyzer and baseline digests. A cache miss still performs a full production-root scan; changed-file
scoping and disabling the build phase are not acceptable fallbacks.

Exit behavior is stable:

- `0`: every file analyzed, site floor satisfied, no privacy violations
- `1`: source was analyzed and one or more privacy violations were found
- `2`: configuration, discovery, reading, parsing, origin-resolution, or coverage integrity error

Diagnostics use Xcode-compatible `path:line: error:` output for source findings and give a concrete
safe-helper or baseline-maintenance action where applicable.

## Adversarial test matrix

Tests run the real script and pin these outcomes:

### Must fail as privacy violations

- exact multiline #359 `Log.info` shape with `member.displayName`
- exact #359 laundering chain from `nameComponents`/`emailAddress` through `displayInfo`
- raw tag identifier, URL, coordinate, latitude, longitude, name, email, and phone interpolation
- whole-object `\(member)` and `String(describing: member)`
- bare `\(error)` whole-object interpolation
- direct `Logger(`, `os_log(` outside the facade, and `NSLog(`

### Must fail as analysis errors

- message passed as a variable rather than an analyzable literal/formatter
- unresolved suspicious parameter, `self` property, nested-closure local, or missing assignment
- unbalanced/malformed multiline log call
- unreadable or unsupported Swift input
- malformed baseline
- discovered/analyzed file mismatch
- site count below the maintained floor, with the deliberate-removal workflow in the message
- annotation count different from its maintained exact baseline

### Must pass

- same-call contrast containing `member.redactedLogLabel` and `member.role.displayName`
- `member.displayName` outside a log call in the consented roster
- `ShareParticipantLog.*`, `DebugRedaction.*ForLog`, `redactedURLString`, `role.*`, collection
  `.count`, permitted UUID/record-name values, and timestamps
- facade-owned `os_log`
- `error.localizedDescription` and `redactedErrorForLog(error)` inside literal messages
- bounded error formatting that stops at depth `3`, detects a cyclic underlying-error chain, and
  truncates the result to `2,048` characters
- native payload-free Swift error enum formatting that retains the type and case name
- associated-value Swift error enum formatting that retains the case label, omits an obviously
  sensitive non-error payload, and safely includes a nested `Error` through the audited recursion
- CloudKit partial-error formatting that preserves permitted record/zone identifiers while an
  obviously sensitive value stored under a non-allowlisted `userInfo` key is absent from output
- every production root, with discovered and analyzed file counts equal
- current production tree at 503 or more facade sites after migration

Each fixture lives at an exact path outside production roots and declares the expected exit class
and diagnostic fragment. Tests first run red against the absent/incomplete analyzer, then green only
after the minimal corresponding rule is implemented.

## Verification and review

Implementation verification includes the fixture suite, direct production analyzer invocation,
recursive `swift-format` lint, project/version guards, the serialized full iOS suite, and a
serialized Debug build. All commits are signed, fixes use new commits rather than amend/force, and
the PR receives independent review before the implementer marks it ready and the planner merges it.
