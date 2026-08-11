# Issue #256 Dead App Selection Prompt Deletion Design

## Goal

Delete the unreachable `AppSelectionPrompt`, `AppSelectionPromptModifier`, and
`View.appSelectionPrompt(isPresented:profile:)` path while preserving the live
`AppSelectionRequiredBanner` production implementation byte-for-byte.

## Current behavior and root cause

`AppSelectionPrompt.swift` contains two unrelated paths:

- an unreachable dedicated sheet that edits and saves local app selection; and
- the live warning banner shown on a profile card when a synced profile still needs local app
  selection.

The sheet path forms a closed internal chain. `AppSelectionPromptModifier` constructs
`AppSelectionPrompt`, and the `View` extension constructs the modifier, but no production or test
code calls the extension. The prompt preview is the only other prompt construction. This leaves a
plausible-looking `saveSelection()` persistence path that cannot run.

The live flow does not use that sheet. `BlockedProfileCard` renders
`AppSelectionRequiredBanner`, invokes `onAppSelectionTapped`, and passes the selected profile
through `BlockedProfileCarousel` to `HomeView`. `HomeView` assigns `profileToEdit`, which presents
`BlockedProfileView`. Its normal save flow updates `needsAppSelection` according to whether a local
selection now exists.

## Deletion evidence

The evidence was re-derived from `main` at `9cd0715`, not accepted solely from the issue handover.

### Access level and required search radius

`AppSelectionPrompt`, `AppSelectionPromptModifier`, and `appSelectionPrompt` have no explicit
access modifier and are therefore internal to the Foqos module. Internal access requires searching
the entire Foqos module, not only the containing file. Searches were also extended across all
tracked production targets, packages, tests, resources, and the Xcode project to catch renamed,
stringly, or duplicated boundaries.

- Current exact-symbol searches find every dead API reference only in
  `Foqos/Components/Sync/AppSelectionPrompt.swift`.
- Searches excluding that file find no prompt, modifier, or extension call in the Foqos module.
- Git history searches find no addition of any of the three APIs outside the candidate file. The
  closed chain has been unreachable since introduction.
- Distinctive sheet strings have no matching localization or resource entry.
- The only `NSClassFromString` use checks for `XCTestCase`; there is no dynamic type construction or
  string-based navigation route for the prompt.

### Live banner boundary

`AppSelectionRequiredBanner` is also internal, so its full-module use chain was traced:

1. `BlockedProfileCard` renders the banner when `needsAppSelection` is true and the profile schema
   is supported.
2. Its button calls `onAppSelectionTapped`.
3. `BlockedProfileCarousel` forwards the selected `BlockedProfiles` instance.
4. `HomeView` assigns that profile to `profileToEdit`.
5. The `profileToEdit` sheet presents `BlockedProfileView`.
6. `BlockedProfileView.saveProfile()` uses
   `BlockedProfiles.needsAppSelectionAfterLocalSave` and persists the result through
   `BlockedProfiles.updateProfile`.

`ProfileAppSelectionStateTests` covers the live state rule. At baseline, both tests pass: an empty
selection retains the requirement, while an already satisfied local-selection state remains clear.

The production bytes from the banner declaration through its closing brace will not change. The
existing prompt preview will be repointed to the surviving banner and supplied with
`ThemeManager.shared`, retaining the project's preview convention without changing runtime code.

### Persistence, schema, and target boundaries

The deletion removes one unreachable caller of `BlockedProfiles.updateProfile`; it does not change
the model, the live update API, or any persisted field.

- No `@Model`, SwiftData schema, migration, Codable shape, CloudKit field, UserDefaults key, shared
  snapshot, or sync record changes.
- No changes to the live `needsAppSelection` model field or editor-save calculation.
- All deleted declarations are internal to the Foqos app module, so extensions and package clients
  cannot call them.
- `Foqos` is a file-system-synchronized Xcode root. This surgical edit keeps the same source file,
  so target membership and project structure remain unchanged.

### Imports and privacy floor

`FamilyControls` and `SwiftData` are used only by the dead prompt. The surviving banner and its
preview need only `SwiftUI`, so the unused imports will be removed.

The dead `saveSelection()` contains exactly two production `Log` calls. The current privacy floor
is 502 sites across 232 production files. Removing the dead calls must first make the privacy lint
fail at 500, after which `scripts/log-privacy-baseline.txt` will be deliberately lowered from 502 to
500 in the same implementation commit. The production file remains, so the discovered-file count
must stay 232; annotations must stay zero.

## Approved approach

Surgically edit `AppSelectionPrompt.swift`:

1. remove the `FamilyControls` and `SwiftData` imports;
2. delete `AppSelectionPrompt` and its helpers/save path;
3. preserve `AppSelectionRequiredBanner` production code byte-for-byte;
4. delete `AppSelectionPromptModifier` and the `View` extension; and
5. replace the dead prompt preview with a preview of `AppSelectionRequiredBanner`.

Then lower the privacy floor 502 to 500 and bump all configurations from 2.0.11/30 to
2.0.12/31.

## Rejected alternatives

- Removing the preview entirely was rejected because a surviving SwiftUI view should retain a
  `#Preview` under project conventions.
- Moving the banner into a newly named file was rejected because filename aesthetics do not
  justify source and project churn in a hygiene PR.
- A source-layout unit test was rejected because it would test repository text rather than a
  behavioral interface. Static deletion evidence, the existing live-path tests, compilation, and
  the full suite provide the appropriate regression proof.

## Verification contract

The change is acceptable only if:

- the three dead APIs and their distinctive sheet strings have zero live references;
- `AppSelectionRequiredBanner` still has its declaration, live card call site, and banner preview;
- the live callback/editor-save chain remains unchanged;
- privacy lint reports 232 files, 500 sites, and zero annotations;
- version gate reports 2.0.11/30 to 2.0.12/31;
- formatting, C2, sync, and diff checks pass;
- targeted `ProfileAppSelectionStateTests`, the full suite, and a serialized Debug build pass; and
- an independent deletion-focused review reports no unresolved Critical or Important findings.
