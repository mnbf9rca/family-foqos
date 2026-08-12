# Issue #408: Locale-Independent Log Privacy UTF-8 Design

## Context

PR #407 made `/usr/bin/ruby` 2.6 the deterministic runtime for the Log Privacy Lint phase, but the
analyzer still inherits that process's external text encoding. Terminal sessions provide a UTF-8
locale, while GUI Xcode launches build phases without `LANG`, `LC_ALL`, or `LC_CTYPE`. In that GUI
environment, system Ruby selects US-ASCII as `Encoding.default_external`.

The analyzer currently reads Swift files with `Pathname#read`. Under the GUI environment, the first
non-ASCII file in sorted production order,
`Foqos/CloudKit/CloudKitNetworkService+Heartbeat.swift`, contains valid UTF-8 bytes but is tagged as
invalid US-ASCII. `SwiftLexer#code_mask` raises `invalid byte sequence in US-ASCII` when its regular
expression scans that string, blocking maintainer device builds.

The causal boundary is reproducible without Xcode:

```bash
env -u LANG -u LC_ALL -u LC_CTYPE /usr/bin/ruby \
  scripts/check-log-privacy.rb --root .
```

Changing only Ruby's external encoding with `-EUTF-8:UTF-8` makes the unchanged analyzer pass all
232 files and 500 sites. The existing `lexer skips comments and string contents` fixture also
contains Unicode and makes the complete fixture suite fail when run with the locale variables
removed. No new fixture is necessary to preserve a RED regression.

## Decision

Text encoding belongs to the analyzer's file-read boundary, not to its launcher or process-global
state.

- Every analyzer text input is read explicitly as `Encoding::UTF_8`. This includes production Swift
  sources and the two numeric baseline files. `Pathname#read(encoding: Encoding::UTF_8)` is supported
  by the shipped macOS Ruby 2.6 runtime and returns the production source as valid UTF-8 even when
  locale variables are absent.
- The fixture harness always removes `LANG`, `LC_ALL`, and `LC_CTYPE` from analyzer subprocesses by
  passing a frozen environment override to `Open3.capture3`. Every case then exercises the harshest
  deployed environment automatically, regardless of the terminal or harness interpreter.
- The Xcode phase remains unchanged. It already invokes `/usr/bin/ruby` absolutely and needs no
  locale setup once the analyzer owns its input encoding.
- Genuinely invalid UTF-8 produces a named, nonzero Xcode-formatted diagnostic for the offending
  file. The existing per-file rescue converts `ArgumentError` into a `Finding`; it does not normalize,
  replace, or silently skip invalid bytes.

This design preserves all privacy classifications, diagnostics, fixtures, and baselines. It changes
only how existing bytes are decoded and how the harness constructs the analyzer environment.

## Data Flow

The deployed path becomes:

```text
GUI Xcode (locale absent)
  -> /usr/bin/ruby scripts/check-log-privacy.rb
  -> Pathname#read(encoding: UTF-8)
  -> valid UTF-8 Swift string
  -> unchanged lexer and privacy analysis
```

The regression path becomes:

```text
system-Ruby or PATH-Ruby fixture harness
  -> Open3 environment removes LANG/LC_ALL/LC_CTYPE
  -> /usr/bin/ruby analyzer subprocess
  -> explicit UTF-8 reads
  -> unchanged expected result for each privacy fixture
```

The harness remains compatible with both system Ruby 2.6 and the developer's PATH Ruby. Analyzer
subprocesses remain pinned to `/usr/bin/ruby`, as established by #406.

## Alternatives Rejected

### Set `Encoding.default_external` globally

Assigning `Encoding.default_external = Encoding::UTF_8` would be a smaller edit, but it mutates
process-wide state and makes unrelated library or future file reads change behavior implicitly.
Explicit read-boundary encoding documents which inputs carry the UTF-8 contract and keeps the effect
local.

### Pass `-EUTF-8:UTF-8` from launchers

Adding `-E` to the Xcode phase and `Open3` command would fix those two launch paths, but direct
analyzer invocations would remain locale-dependent. It would also duplicate an input-format
requirement across callers. The analyzer must be deterministic on its own.

## Error Handling

Missing files and malformed numeric baselines retain their existing named, nonzero diagnostics.
Unreadable files retain the existing fail-closed handling. A genuinely invalid UTF-8 source is
converted at the per-file rescue boundary into `path:1: error: invalid byte sequence in UTF-8`, while
the analyzer remains nonzero and reports incomplete file coverage. It is never normalized, replaced,
or silently skipped; accepting damaged source would weaken a build guard.

The macOS Privacy & Security prompt that concurrently said `ruby` was prevented from modifying a
path is incidental to this encoding failure. The production analyzer has no write operations, the
captured build log has no permission or sandbox denial, and the identical failure reproduces in a
read-only shell run without the prompt. If that prompt recurs, its exact target path should be
captured and investigated separately.

## Test Strategy

The unmodified RED commands are:

```bash
env -u LANG -u LC_ALL -u LC_CTYPE /usr/bin/ruby \
  scripts/test-check-log-privacy.rb
env -u LANG -u LC_ALL -u LC_CTYPE /usr/bin/ruby \
  scripts/check-log-privacy.rb --root .
```

The suite fails the existing Unicode lexer fixture, and production analysis raises from
`SwiftLexer#code_mask`. A separate temporary invalid-byte case proves the pre-fix analyzer emits a
raw backtrace without naming the offending Swift file.

After implementation, run the complete suite through all required harness contexts:

```bash
/usr/bin/ruby scripts/test-check-log-privacy.rb
ruby scripts/test-check-log-privacy.rb
env -u LANG -u LC_ALL -u LC_CTYPE /usr/bin/ruby \
  scripts/test-check-log-privacy.rb
```

Because the harness strips locale from every analyzer subprocess, all three commands enforce the GUI
environment; the third additionally proves the harness itself works without a locale. Each reports
53 cases: the unchanged 52 privacy cases plus the invalid-UTF-8 named-failure case.

Then verify the production analyzer by effect in both process environments:

```bash
/usr/bin/ruby scripts/check-log-privacy.rb --root .
env -u LANG -u LC_ALL -u LC_CTYPE /usr/bin/ruby \
  scripts/check-log-privacy.rb --root .
```

Both must report 232/232 files, 500 sites, and 0 annotations. Ruby 2.6 syntax checks, project RuboCop,
`git diff --check`, and the version-increment gate complete verification. No Xcode or simulator run
is required for this Ruby-only behavior because the stripped environment reproduces the exact GUI
failure boundary.

## Scope

Implementation changes are limited to:

- `scripts/check-log-privacy.rb`
- `scripts/test-check-log-privacy.rb`
- `FamilyFoqos.xcodeproj/project.pbxproj` version settings, from 2.0.22/build 41 to
  2.0.23/build 42
- this design and its implementation plan

The build-phase command, Swift production sources, privacy rules, fixtures, baselines, and Fastlane
runtime do not change.
