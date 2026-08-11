# Issue #256 Dead App Selection Prompt Deletion Implementation Plan

> Execute proof-first in the isolated `fix/256-delete-app-selection-prompt` worktree. Never amend or
> force-push. Run every Xcode command through the serialized wrapper with `set -o pipefail` and
> `bundle exec xcpretty`; do not provide a simulator destination.

**Goal:** Remove the unreachable dedicated app-selection sheet path while keeping the live warning
banner and editor-save behavior intact.

**Architecture:** The dead internal prompt/modifier/extension form a closed chain inside one Swift
file. The live internal banner remains in that file and routes through the card/carousel callbacks
to `HomeView` and `BlockedProfileView`. Treat static reachability as the deletion proof and existing
state tests as the live behavioral proof.

**Baseline:** `main` `9cd0715`, version 2.0.11/30, privacy floor 502.

---

## Task 1: Freeze baseline evidence

1. Confirm a clean branch/worktree based on `9cd0715`.
2. Search the entire Foqos module and all tracked targets for:
   - `AppSelectionPrompt`
   - `AppSelectionPromptModifier`
   - `appSelectionPrompt(`
3. Repeat searches excluding the candidate file; expect no code hits.
4. Search distinctive sheet strings, resources, the Xcode project, runtime type lookup, and
   navigation routes; expect no prompt route.
5. Search Git history outside the candidate file; expect no past use.
6. Trace and record the live banner callback chain through `BlockedProfileCard`,
   `BlockedProfileCarousel`, `HomeView`, and `BlockedProfileView`.
7. Run privacy lint; expect 232 files, 502 sites, zero annotations.
8. Run targeted baseline tests:

```bash
set -o pipefail
scripts/xcode-stream.sh --agent build1 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -only-testing:FoqosTests/ProfileAppSelectionStateTests 2>&1 | bundle exec xcpretty
```

Expected: 2 tests, zero failures.

## Task 2: Commit the approved design and plan

Add and commit:

- `docs/superpowers/specs/2026-08-11-issue-256-dead-app-selection-prompt-deletion-design.md`
- `docs/superpowers/plans/2026-08-11-issue-256-dead-app-selection-prompt-deletion.md`

These artifacts must state each deleted declaration's internal access level and the whole-module
search radius it requires.

## Task 3: Make the surgical deletion

Edit `Foqos/Components/Sync/AppSelectionPrompt.swift` with `apply_patch`:

1. keep only `import SwiftUI`;
2. delete the entire `AppSelectionPrompt` declaration;
3. leave the production `AppSelectionRequiredBanner` declaration byte-identical;
4. delete `AppSelectionPromptModifier` and `View.appSelectionPrompt`;
5. replace the dead prompt preview with:

```swift
#Preview {
  AppSelectionRequiredBanner()
    .environmentObject(ThemeManager.shared)
}
```

Do not rename/move the file or clean up the surviving banner's unused environment property.

## Task 4: Prove the privacy-floor change

Before changing the baseline, run:

```bash
ruby scripts/check-log-privacy.rb --root .
```

Expected RED: the analyzer reports the site count shrank from 502 to 500 while the file count stays
232 and annotations stay zero.

Change `scripts/log-privacy-baseline.txt` from 502 to 500, then rerun the analyzer.

Expected GREEN: 232 files, 500 sites, zero annotations.

Commit the surgical source edit and deliberate floor reduction together. The commit body must state
that the two removed sites were the dead prompt's success/error logs.

## Task 5: Bump the version

Update all 12 Xcode configurations in `FamilyFoqos.xcodeproj/project.pbxproj`:

- `MARKETING_VERSION`: 2.0.11 to 2.0.12
- `CURRENT_PROJECT_VERSION`: 30 to 31

Run:

```bash
scripts/check-version-increment.sh origin/main HEAD
```

Commit the version bump in a new commit.

## Task 6: Static and behavioral verification

1. Confirm dead APIs and distinctive sheet strings have zero live code/resource hits.
2. Confirm `AppSelectionRequiredBanner` still has exactly its production declaration, card use, and
   preview.
3. Confirm the live callback/editor-save chain remains present.
4. Run:
   - `swift-format lint --recursive .`
   - `git diff --check origin/main...HEAD`
   - C2 guards
   - sync guards
   - version gate
   - privacy lint
5. Rerun targeted `ProfileAppSelectionStateTests` through the serialized wrapper.
6. Run the full test suite through the serialized wrapper.
7. Run a serialized Debug build.

Expected: all commands exit zero; full-suite count matches the current baseline with zero failures.

## Task 7: Independent review and publication

Request a read-only, deletion-focused AMQ review. Give the reviewer:

- base and exact head SHAs;
- the approved design and plan;
- internal access levels and whole-module search evidence;
- historical no-use evidence;
- live banner callback/editor-save trace;
- privacy RED/GREEN arithmetic;
- exact targeted/full/build results; and
- version 2.0.12/31.

The reviewer must not mutate files or run Xcode. Resolve every Critical or Important finding in a
new commit and rerun affected verification. Address evidence-related Minor findings when practical.

Refresh `origin/main`. If it moved, rebase without force/amend, update the version in a new commit,
and rerun verification/review as required.

Push the branch and open a non-draft PR that closes only #256. Monitor all GitHub checks to green,
verify the PR is OPEN, non-draft, CLEAN, and at the reviewed exact head, then send the green PR to
the planner for the planner-owned merge. Do not begin #257 until merge confirmation arrives.
