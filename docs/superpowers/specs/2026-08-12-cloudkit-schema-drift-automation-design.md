# CloudKit Schema Drift Automation Design

## Goal

Replace the routine runbook's manual CloudKit discovery searches with one fail-closed drift report
that coding agents run inside schema-changing pull requests. Keep Production promotion visibly
maintainer-only, preserve the hand-reconciled manifest as an independent statement of intent, and
make operator usability a tested merge condition.

This reworks the process merged in PR #410. It does not change CloudKit Production, the checked-in
schema's current record or field inventory, or any Fastlane lane.

## Audience Split

The canonical `docs/cloudkit-production-schema.md` document has two explicit audiences:

1. **Routine Schema Change — Coding Agents** is normally executed by the coding agent that changes
   a CloudKit record type or field. A maintainer does not run discovery searches by hand.
2. **Release Promotion — Maintainer Only** is executed by the maintainer after the final
   schema-changing pull request merges and before a dependent TestFlight or App Store build.

The first workflow is reduced to five steps: change code, run the drift reporter, make the reported
hand-reconciled manifest and `.ckdb` edits until the report is clean, run the existing checked-in
schema checker, and include the changes plus successful outputs in the pull request. The document
contains no Swift source lists, discovery expressions, inventory counts, or `ripgrep` installation
instructions.

The second workflow adds the reporter to repository preflight but retains the existing CloudKit
Console deployment, authenticated Production postflight, issue closeout, and Fastlane stop/go
sequence. It states “Maintainer Only” before its first action.

## Architecture

Add two focused shell files:

- `scripts/report-cloudkit-schema-drift.sh` owns discovery, normalization, comparison, and stable
  operator output. It never edits an input.
- `scripts/test-report-cloudkit-schema-drift.sh` is a hermetic fixture suite for the reporter's
  dependency, parser, anti-vacuity, exception, output, exit-status, and no-write contracts.

Keep `scripts/check-cloudkit-schema-export.sh` separate and behaviorally unchanged. The reporter
answers “what disagrees across code, intent, and the checked-in export?” before reconciliation. The
checker answers “does the checked-in export cover every independently required manifest entry?”
after reconciliation. Combining those responsibilities would destabilize an existing release gate
and make its success output carry routine-development concerns.

The reporter is Bash, matching the repository's existing schema and release tools. It explicitly
preflights `rg` and every other external command it invokes. `ripgrep` remains documented in
`AGENTS.md`; converting the expressions to POSIX regular expressions is rejected because a subtle
translation error could silently discover nothing. Anti-vacuity controls make the retained
`rg`-based discovery trustworthy.

## Independent Manifest Oracle

`fastlane/required-prod-schema.txt` remains hand-reconciled. The reporter derives a candidate set
from code and reports differences; it never writes or regenerates the manifest.

Generating the manifest from code is rejected. It would compare a code-derived manifest with the
same code that generated it, making the field check tautological and incapable of detecting that an
agent forgot to declare a new requirement. The current independent-oracle guarantee is more
valuable than removing the reconciliation decision.

The three normalized sets use exact lines:

```text
RECORD TYPE RecordName
RECORD TYPE RecordName.fieldName
```

Each set is deduplicated and sorted under `LC_ALL=C` before comparison.

## Code Discovery

The reporter owns source roots, exact structured-file lists, and these five named discovery
families:

1. `static-record-types`: `static let recordType\s*=\s*"[^"]+"` declarations under the four
   app/extension source roots;
2. `literal-record-types`: literal `CKRecord\(recordType:\s*"[^"]+"` construction under those
   roots;
3. `field-key-cases`: `FieldKey: String` cases associated with their preceding record type in
   `SyncModels.swift` and `ProfileSessionRecord.swift`;
4. `record-key-constants`: string-valued `RecordKey` constants associated with the file's record
   type in the four standalone CloudKit model files; and
5. `family-root-subscript-keys`: literal `rootRecord\["[^"]+"\]` keys in the two FamilyRoot
   network service files, normalized under `FamilyRoot`.

Every configured directory and file must exist and be readable before discovery. Every named
family must produce at least one parseable requirement. A missing configured path or zero-result
family is an invalid report, not a clean result.

Duplicate discoveries are expected when multiple sites declare the same type or key and are
removed during normalization. Any nonempty discovery line that cannot be normalized is a parser
error rather than something the reporter skips.

## Manifest and Schema Normalization

The manifest normalizer reads every nonblank, noncomment `RECORD TYPE` requirement exactly. Empty,
unreadable, malformed, or duplicate requirement lines make the report invalid.

The `.ckdb` normalizer emits each record type and its application fields. CloudKit system fields
whose names start with `___`, `GRANT` clauses, blank lines, and ordinary comments are structural
schema syntax and are not candidate requirements. An unterminated or malformed record block makes
the report invalid.

Comparisons are symmetric after audited exception suppression:

- code versus manifest reports missing and extra manifest requirements;
- manifest versus checked-in schema reports missing and extra schema requirements.

The manifest remains the middle oracle deliberately. If code removes a deployed field, the
manifest can retain it as an annotated compatibility requirement and the additive-only `.ckdb`
stays aligned with intent.

## Audited Exceptions

Intentional extras are annotated beside the artifact entry they excuse, never hardcoded by name in
the reporter.

The manifest annotation grammar is:

```text
# DRIFT-EXCEPTION manifest-only: RECORD TYPE "cloudkit.share"
RECORD TYPE "cloudkit.share"
```

It suppresses exactly the following manifest requirement when comparing manifest to code. The
requirement still participates normally in the manifest-to-schema comparison.

The `.ckdb` annotation grammar is:

```text
// DRIFT-EXCEPTION schema-only: RECORD TYPE FamilyPolicy
RECORD TYPE FamilyPolicy (
```

It suppresses the named schema-only record block and all of that block's application fields when
comparing schema to manifest. It must immediately precede the matching record block.

The current clean baseline has two exception annotations: built-in `cloudkit.share` in the manifest
and deprecated `FamilyPolicy` in the checked-in schema. Legacy `SyncedSession` is not an exception
because it remains declared in code, manifest, and schema.

Malformed annotations, duplicate annotations, annotations without an exact target, and annotations
whose target is no longer extra are errors. One valid annotation increments the suppression count
once regardless of how many fields a schema-only record block contains. The clean summary exposes
annotation accretion on every run.

## Output and Exit Contracts

Successful output is exactly one line:

```text
OK: no CloudKit schema drift; 2 annotated exceptions suppressed.
```

The numeric value is derived from valid, exercised annotations rather than hardcoded.

Drift output uses stable, `LC_ALL=C`-sorted lines in this category order:

```text
MISSING from manifest: RECORD TYPE X.field
EXTRA in manifest: RECORD TYPE Y.field
MISSING from checked-in schema: RECORD TYPE X.field
EXTRA in checked-in schema: RECORD TYPE Y.field
CloudKit schema drift detected.
```

Only nonempty categories print. Drift exits `1`.

Invalid inputs or an invalid report exit `2` with a diagnostic that names the unreadable/empty
path, configured source path, discovery family, malformed requirement, annotation, or schema block.
A discovery command that returns “no matches” is converted to the named zero-result diagnostic;
other child failures preserve their exact nonzero status. A missing external command exits `127`
and names the command before any input processing or temporary-file creation.

The reporter creates only private temporary normalization files, removes them through an EXIT trap,
and performs no shared-state mutation. Its test suite proves all fixture inputs remain byte-identical
after both successful and failing reports.

## Test Strategy

The hermetic suite creates synthetic versions of every configured source directory/file, the
manifest, and the `.ckdb`. Its clean fixture contains a known positive for each of the five named
discovery families.

Anti-vacuity coverage is table-driven:

- remove each family's sole known-positive construct one at a time and require exit `2` with that
  exact family name;
- remove each configured source directory/file one at a time and require exit `2` naming that
  exact path;
- mutate each parser shape so a discovered but unparseable line fails instead of disappearing.

Behavior fixtures cover each drift direction independently and require exact sorted output plus
exit `1`. Additional fixtures cover both exception forms, the derived suppression count,
malformed/duplicate/stale annotations, missing `rg` with exit `127`, empty/unreadable artifacts with
exit `2`, duplicate requirements, malformed/unterminated `.ckdb` blocks, exact child-status
propagation, cleanup, and input byte identity.

The production verification gate runs:

```bash
bash scripts/test-report-cloudkit-schema-drift.sh
bash scripts/report-cloudkit-schema-drift.sh
bash scripts/test-check-cloudkit-schema-export.sh
bash scripts/check-cloudkit-schema-export.sh
bash scripts/test-check-prod-schema.sh
bash -n scripts/report-cloudkit-schema-drift.sh scripts/test-report-cloudkit-schema-drift.sh
shellcheck scripts/report-cloudkit-schema-drift.sh scripts/test-report-cloudkit-schema-drift.sh
```

It also validates the documentation structure, exact output contracts, `git diff --check`, the
version matrix, and signed history. The app advances from version `2.0.24` / build `43` to
`2.0.25` / build `44` in every Xcode build setting.

No Xcode or simulator run is required. The new reporter is standalone operator tooling, the existing
schema scripts are not Xcode build-phase dependencies, and the remaining changes are documentation,
schema comments/manifest comments, tests, and build-setting text.

## Verbatim Operator Walkthrough

After implementation reaches a review-ready commit, create a temporary scratch worktree and branch
from that exact head. Add one real scratch CloudKit field in code, then execute section 1 of
`docs/cloudkit-production-schema.md` word for word without improvising around gaps.

The transcript must explicitly label the first reporter exit `1` as the **deliberate-failure
demonstration**. The operator stops, makes only the reported hand-reconciliation edits, reruns the
reporter through its stop-and-fix loop until it prints the clean summary, then runs the existing
checker. Editing ahead of the initial report would invalidate the control.

If any necessary action is absent or ambiguous in the written checklist, that is a defect: update
the tooling or documentation in a new signed commit and restart the walkthrough from a fresh
scratch worktree. After a successful walkthrough, capture the complete command/output transcript in
the pull request body and discard the explicitly throwaway scratch worktree and branch.

Section 2 cannot be agent-walkthrough tested because its stop conditions include the maintainer's
real CloudKit Console deployment and authenticated Production postflight. The maintainer exercises
those conditions during the actual release; this boundary is explicit rather than an omitted test.

## Review and Merge Gates

The final implementation head requires independent reviewer approval. After approval, the reviewer
hands the pull request off, and a maintainer must read and accept the operator instructions before
merge. The maintainer is the usability acceptance test; reviewer approval alone is insufficient.
The planner holds the merge until that sign-off arrives.

The pull request stays non-draft only after the full verification gate and successful walkthrough
transcript are complete. No agent performs the maintainer-only Console deployment or merges around
either acceptance gate.

## Alternatives Rejected

### Generate the manifest from code

This removes hand editing but collapses the independent-oracle invariant. Code would generate the
manifest used to check that same code, so a missing field declaration could no longer produce a
meaningful disagreement.

### Extend the existing checked-in schema checker

One entrypoint would be superficially simpler, but it would mix routine code discovery with the
stable release gate and blur two different guarantees. A separate reporter composes with the
checker without changing it.

### Use a Ruby reporter

Ruby would make some structured parsing convenient, but it creates a second interpreter contract
for a shell-oriented release workflow and still requires every anti-vacuity fixture. Bash plus the
already documented and preflighted `rg` dependency is the smaller operational surface.

### Print intentional extras on every clean run

Always printing known extras trains operators to ignore output. Artifact-local annotations keep the
baseline quiet while the derived suppression count makes exception growth visible.

### Translate discovery to POSIX grep

Hand-translating the current `rg` expressions risks a silent zero-result pattern. Named dependency
preflight plus per-family known-positive controls prevents that failure without changing expression
semantics.

## Scope

Implementation is limited to:

- the new reporter and its hermetic test;
- the canonical CloudKit workflow document;
- artifact-local exception comments in the manifest and checked-in `.ckdb`;
- this design and its implementation plan; and
- Xcode version/build settings for `2.0.25` / `44`.

CloudKit record/field inventory, application code, Fastlane lanes, Production schema state, and the
existing checked-in schema checker's behavior remain unchanged. The temporary walkthrough field and
its reconciliation edits never enter the feature branch.
