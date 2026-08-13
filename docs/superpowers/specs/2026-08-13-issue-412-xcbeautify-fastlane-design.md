# Issue #412: xcbeautify and Archive Export Verification

## Goal

Replace every active xcpretty integration with xcbeautify while preserving the wrapper's exact
process-status contract. Upgrade Fastlane to 2.238.0, verify the export-method spelling against
the shipped Gym implementation, provide a repeatable archive/export proof that cannot upload, and
stop making a second full copy of each Xcode archive.

This is one coherent tooling migration. The wrapper, Fastlane configuration, tests, current
documentation, release metadata, and archive-artifact behavior change together so no supported
caller temporarily points at the old formatter.

## Selected approach

Use a direct migration with no compatibility alias. `--xcbeautify` replaces `--xcpretty`, and a
stale `--xcpretty` call fails before execution with an error that names `--xcbeautify` as the
replacement. Carrying an alias would make an option named for xcpretty run another formatter and
would hide stale callers. A formatter-only patch is also rejected because it would omit the
required Fastlane proof lane and archive-copy removal.

Historical design and plan documents remain records of the implementation that existed when they
were written. Active code, tests, entrypoint documentation, and current workflow examples must not
invoke or recommend xcpretty. Fastlane 2.238.0 may continue to bring xcpretty into `Gemfile.lock`
as a transitive dependency; that lockfile entry is not an active formatter integration.

## Wrapper boundary

`scripts/xcode-stream.sh` remains the sole owner of formatted `xcodebuild` process semantics. Its
supported interface becomes:

```bash
scripts/xcode-stream.sh --agent <agent> [--session <session>] --xcbeautify -- \
  xcodebuild <arguments>
```

The wrapper accepts `--xcbeautify` only when the command immediately after `--` is `xcodebuild`.
It rejects `--xcpretty` with a named `use --xcbeautify` diagnostic. Option placement, immediate
child validation, `command -v xcbeautify`, and `xcbeautify --version` all complete before gate
status, registry initialization, simulator lookup, allocation, or other shared-state mutation.

The formatted branch owns this pipeline after the simulator gate establishes the child
environment and injects the exact UUID, DerivedData, and no-clone arguments:

```text
xcodebuild <caller arguments> <injected arguments> 2>&1 | xcbeautify
```

It captures both Bash `PIPESTATUS` entries immediately:

1. Return the exact `xcodebuild` status when it is nonzero.
2. Otherwise return the exact xcbeautify status when it is nonzero.
3. Return zero only when both processes succeed.

The unformatted path retains its existing direct execution. The formatter change does not broaden
the wrapper into a generic formatting protocol and does not alter clean-build, screenshots, or
arbitrary-command handling.

## Fastlane boundary

Pin Fastlane to 2.238.0 and explicitly select xcbeautify wherever this repository configures an
Xcode formatter, including Gym in `fastlane/Fastfile` and snapshots in `fastlane/Snapfile`.
xcbeautify is a Homebrew executable rather than a Bundler dependency, so active setup and
preflight documentation must name `brew install xcbeautify` and the executable probe directly.

Keep Gym's archive export method as `app-store`. The exact shipped `fastlane-2.238.0` gem still
validates against an allowlist containing `app-store` and rejects `app-store-connect`. The issue's
conditional migration requirement is therefore not met. No Gym patch or reconstructed validator
is allowed; the regression test must load the pinned gem and exercise the configuration layer Gym
actually executes. The PR body records this finding so the recheck is visibly completed rather
than skipped.

Add one public, zero-option `verify_export` lane and document it beside `beta` and `release`. The
lane obtains the App Store Connect credentials and derived build number required by the existing
shared Gym helper, invokes that helper, and returns. It has no call, branch, callback, or shared
post-build routine that can reach Pilot, Deliver, TestFlight, App Store submission, or GitHub
release publication. Maintainers run it through `scripts/fastlane.sh verify_export`, ensuring the
proof uses the same credential routing and Gym implementation as delivery lanes without adding an
upload path.

## Archive and dSYM flow

Beta and release continue to build through the shared Gym helper. After Gym succeeds, they read
`SharedValues::XCODEBUILD_ARCHIVE` from lane context and validate that the archive and its `dSYMs`
directory exist. A narrow `ArchiveStorage` operation creates the named dSYM zip directly from
`<archive>/dSYMs` and writes it beside the Xcode archive under `File.dirname(archive)`; it does
not copy, rename, retain, recover, or delete the `.xcarchive`.

Remove `ARCHIVE_DIR`, `preserve_archive_locally`, `ArchiveStorage.replace_directory`, and the
temporary/backup directory machinery used only by the duplicate archive copy. Existing archives
under `~/Archives/family-foqos` belong to the maintainer and are not modified by this work.

The resulting metadata contains the version, build, traceable stem, Xcode archive path, and dSYM
zip path. Beta and release prepare the zip before uploading to Apple. Missing archive context,
missing `dSYMs`, or zip failure aborts before Pilot or Deliver. After Apple accepts the upload,
the existing GitHub publication path attaches the prepared zip; GitHub publication remains
warn-only and never changes the Apple upload result. `verify_export` performs only the real Gym
archive/export proof and does not enter this publication flow.

## Documentation and dependencies

Update every current caller in the same PR:

- the root `AGENTS.md` canonical build command;
- `docs/development-workflow.md` setup, preflight, build, and lane examples;
- `scripts/xcode-stream.sh` help and diagnostics;
- `fastlane/Fastfile` and `fastlane/Snapfile`; and
- live test fixtures and policy checks.

No active example may retain an external xcpretty pipeline, caller-managed `pipefail`, or the old
wrapper flag. This addresses the original masking failure at the process owner instead of asking
each caller to configure its shell correctly.

Advance the release from 2.0.28 (47) to 2.0.29 (48), subject to rebasing and choosing the next
available version/build pair if `main` advances before the PR is ready.

## Failure behavior

- Unknown or stale formatter options fail before gate mutation and name the supported replacement.
- Missing xcbeautify returns 127; an installed executable whose version probe fails returns 1.
- A non-`xcodebuild` child with formatting enabled is rejected before allocation.
- Formatted child and formatter failures preserve their exact status with child-first precedence.
- Gym configuration validation, signing, archive, or export failure aborts `verify_export` and all
  delivery lanes before any upload.
- Missing archive context, missing dSYMs, or zip failure aborts beta/release before Apple upload.
- GitHub dSYM publication remains warn-only after an accepted Apple upload.

## Test strategy

Write each regression before its implementation change.

Port `scripts/test-xcode-stream.sh` from fake Bundler/xcpretty behavior to a fake xcbeautify
executable and pin:

- stale `--xcpretty` rejection that includes `use --xcbeautify`;
- child `23`, formatter `0` returning `23`;
- child `0`, formatter `17` returning `17`;
- merged stdout and stderr reaching the formatter;
- missing-command and failed-version preflights occurring before gate mutation;
- formatting scope remaining limited to an immediate `xcodebuild` child; and
- the existing unformatted exact-status contract remaining unchanged.

Strengthen `scripts/test-fastlane-export-method.rb` so it loads the pinned Fastlane 2.238.0 Gym
configuration, proves `app-store` is accepted, proves `app-store-connect` is rejected, and confirms
the shared archive lane passes the accepted spelling. Add a focused Fastlane lane test proving
`verify_export` has exactly one behavioral edge to the archive/export helper and cannot invoke
Pilot, Deliver, or dSYM publication.

Refocus `scripts/test-archive-storage.rb` on direct dSYM zipping and GitHub upload retry. It must
prove the zip source is the lane-context archive's `dSYMs`, missing input and zipper failure are
fatal, no whole archive is copied, and the existing release-create-to-upload-clobber fallback
preserves arguments. Remove replacement, backup, and interrupted-copy fixtures with the deleted
feature.

Run shell syntax checks, the complete relevant script regression suites, Bundler checks, active
code/documentation reference scans, and repository policy gates. Run the real proof as:

```bash
scripts/fastlane.sh verify_export
```

The maintainer supplies cloud-signing keystrokes. Capture successful real archive/export evidence
before review and confirm that no upload occurred. No beta or release upload is authorized by this
proof. Independent code review is required before merge.

## Success criteria

- Active code and documentation use xcbeautify exclusively.
- The wrapper preserves exact child-first pipeline statuses without caller `pipefail` setup.
- Fastlane 2.238.0 is pinned and tested at Gym's shipped configuration layer.
- `app-store` remains only because the pinned Gym validator rejects `app-store-connect`.
- `verify_export` proves real archive/export and has no upload path.
- Beta/release zip dSYMs directly from Xcode's archive and never duplicate the archive.
- Automated regressions, the maintainer-assisted real export, and independent review all pass
  before merge.
