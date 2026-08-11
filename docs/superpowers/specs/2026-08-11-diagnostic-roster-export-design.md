# Diagnostic Roster Export Design

## Goal

Add an explicitly opted-in `roster.txt` file to diagnostic exports so Family Foqos support can
map privacy-safe identity tokens in logs back to the family members they describe.

Ordinary exports remain unchanged: family member names and the roster file are absent unless the
user turns on the export-screen toggle for that export.

## Context

Diagnostic logs now identify family members with either:

- `FamilyMember.redactedLogLabel`, formatted as `role·first8StableUUID`; or
- an opaque CloudKit user record name when only a share participant is available.

Those values protect names in logs but make support investigations harder. The roster is a
deliberate decode table supplied only when the user is seeking support. Every identity token that
can appear in a family-member log line must be resolvable from it.

## User Experience and Consent

`LogExportView` gains a transient `@State` toggle labeled **Include family member names**. It starts
off every time the export screen is created and is not stored in `UserDefaults`. A previous opt-in
therefore cannot silently affect a later export.

Support-framed help text appears with the toggle:

> Turn this on only when Family Foqos support asks. Adds roster.txt so support can match diagnostic
> identifiers to family members.

The privacy disclosure changes immediately:

- Toggle off: explain that logs can contain profile names, timestamps, and technical device or
  account identifiers, while family member names are not included.
- Toggle on: state that `roster.txt` includes family member names, full identifiers, and CloudKit
  record names, and should be shared only with Family Foqos support.

The **What's Included** section conditionally adds **Family member roster for support**. The
existing generic **Personal identifiers** row in **Not Included** is replaced with the accurate,
specific **Family member names** row when the toggle is off; that row disappears when the toggle
is on. Passwords, lock codes, location coordinates, and blocked app names remain excluded.

Preview Logs continues to preview logs only. The roster is created only when the user taps Share
Logs, so names do not enter the log preview or the logging subsystem.

## Roster Format

A new pure `FamilyRosterExport` formatter accepts `[FamilyMember]` and returns UTF-8 text. It has no
singleton, UI, filesystem, or CloudKit dependencies.

The file is headerless and contains one line per member. Fields use an em dash surrounded by
spaces. The grammar is:

```text
<redactedLogLabel> — <displayName> — <full UUID> — <CK recordName> [— (departed)]
```

Rules:

- `redactedLogLabel` is copied verbatim so it joins directly to log lines.
- The UUID uses the complete uppercase `UUID.uuidString` representation.
- A non-empty `userRecordName` is included verbatim so opaque participant labels can be resolved.
  If a future or malformed model has an empty record name, that field is omitted rather than
  emitting a meaningless blank token.
- `— (departed)` is appended only when `isActive == false`.
- Members sort by `role.rawValue`, then `displayName`, then full UUID, using Swift's stable string
  comparison. The UUID tie-breaker makes output deterministic when role and name match.
- An opted-in export with no cached members contains an empty `roster.txt`. The file's presence
  still records that the option was honored without inventing data.
- A final newline is present when at least one member exists.

Example:

```text
child·3F2A9C1B — Emma — 3F2A9C1B-672E-4C4A-9039-FF6107FBCE91 — _abc123
parent·81D45AA0 — Dad — 81D45AA0-DB15-48E2-9E20-0BE031607A19 — _def456 — (departed)
```

## Architecture and Data Flow

1. When Share Logs is tapped, `LogExportView` snapshots
   `CloudKitManager.shared.familyMembers` on the main actor.
2. If the toggle is off, the view passes `nil` to the archive manager.
3. If the toggle is on, `FamilyRosterExport.content(for:)` formats the snapshot on the main actor,
   and the view passes the resulting `String` to the archive manager.
4. `LogExportManager.createLogArchive(familyRoster:)` retains a default value of `nil`, preserving
   the privacy-safe behavior of existing callers.
5. Inside the detached staging task, an internal static helper writes non-`nil` content to
   `roster.txt` before compression. A `nil` value creates no roster file.
6. The normal ZIP path contains `roster.txt`. If coordinated ZIP creation fails, the existing
   combined-text fallback includes it as a clearly named `=== roster.txt ===` section because it
   already combines every staging file.

The archive manager never reads `CloudKitManager` or `FamilyMember`. Passing a preformatted,
optional `String` avoids singleton coupling and avoids transferring non-Sendable app state into
the detached task.

The roster uses the current in-memory family-member cache. Export does not initiate a CloudKit
fetch: support exports must remain usable offline, and a network failure must not block access to
existing logs. Inactive cached entries remain useful and are marked `(departed)`.

## Error Handling

If roster formatting succeeds but writing `roster.txt` fails, archive creation fails and the UI
shows the existing localized export error. The app must not silently produce an archive that the
user explicitly requested to include the roster.

The existing no-logs check remains before the device-info and roster additions, so the presence of
an opted-in roster alone does not make an otherwise empty log export shareable.

No roster value is logged while formatting, staging, failing, or sharing.

## Testing

Focused unit tests cover:

- exact active-member line output, including the verbatim log label, display name, full UUID, and
  record name;
- `(departed)` only for inactive members;
- deterministic role/name/UUID ordering;
- omission of an empty record-name field;
- empty member input;
- `nil` roster content creating no file in a temporary staging directory;
- non-`nil` roster content creating an exact UTF-8 `roster.txt` file.

Implementation follows red-green TDD. After focused tests pass, run the full serialized test suite,
a serialized Debug build, swift-format lint, project-file validation, the privacy scan, and the
version-increment gate.

## Versioning and Scope

This PR bumps every target/configuration pair from marketing version `2.0.6` to `2.0.7` and build
number `25` to `26`. All 12 target/configuration pairs must agree.

This PR does not change log content, CloudKit fetching, family-member lifecycle, preview behavior,
or Child-mode diagnostics access. The subsequent and separate final batch PR addresses issue #360
by adding the build-phase lint.
