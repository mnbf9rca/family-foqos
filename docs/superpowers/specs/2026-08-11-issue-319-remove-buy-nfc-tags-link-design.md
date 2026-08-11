# Issue #319: Remove the Buy NFC Tags Link

## Goal

Remove the affiliate purchase link from Settings without replacing it or changing the app's NFC functionality and explanatory copy elsewhere.

## Audit

- `Foqos/Views/SettingsView.swift` contains the only `Buy NFC Tags` section.
- The section contains the only use of the file-level `amznStoreLink` constant.
- The Amazon affiliate label occurs only inside that section.
- No production code, tests, scripts, or project settings reference the constant or section text elsewhere.
- Generic NFC feature descriptions and NFC scanning/writing behavior are unrelated to the purchase link and remain unchanged.

## Design

Delete the complete `Section("Buy NFC Tags")` block and delete the now-unused `amznStoreLink` constant. Add no replacement content.

This is preferable to hiding the section behind a condition because the maintainer requested removal, and retaining dead affiliate-link code would leave the unwanted destination in the binary. It is also preferable to replacing the destination or label because the issue explicitly requests no replacement content.

## Verification strategy

There is no durable behavior seam for this static SwiftUI layout, and adding a source-text test would couple tests to formatting rather than user behavior. Verification therefore consists of:

- an exact repository sweep proving the section, label, URL, and constant are absent;
- a focused diff proving the surrounding About and Help sections are unchanged;
- formatting and repository policy gates;
- the existing test suite and a serialized Debug build;
- independent review of the exact head.

The release advances from 2.0.14 (33) to 2.0.15 (34). Privacy baselines remain unchanged.
