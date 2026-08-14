# Issue #412 xcbeautify and Fastlane Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace active xcpretty integrations with xcbeautify, add a repeatable no-upload
Fastlane export proof, and stop duplicating Xcode archives while preserving exact failure status.

**Architecture:** `scripts/xcode-stream.sh` owns the formatted `xcodebuild` pipeline and returns
the child status before the formatter status. Fastlane 2.238.0 explicitly invokes xcbeautify,
keeps Gym's validated `app-store` spelling, exposes one upload-free `verify_export` lane, and
prepares dSYMs beside the lane-context archive without copying the archive.

**Tech Stack:** Bash 4+, xcbeautify, Ruby 4/Bundler, Fastlane 2.238.0, Gym, Xcode project metadata,
shell and Ruby regression harnesses.

## Global Constraints

- Work only in `/Users/rob/git/family-foqos/.worktrees/build1-412` on
  `chore/412-xcbeautify-migration`.
- Run `scripts/warm-git-credentials.sh` in the clean worktree before the first implementation edit.
- Do not amend or force any commit; create a new signed commit for each task and each review fix.
- Do not start another Xcode or simulator implementation stream on this machine.
- `--xcpretty` is removed with no alias and must fail with a diagnostic containing
  `use --xcbeautify`.
- The formatted wrapper contract is exact: nonzero `xcodebuild` status wins; otherwise return the
  xcbeautify status.
- Pin Fastlane exactly to 2.238.0 and test the shipped Gym validator rather than reconstructing its
  allowlist.
- Keep `export_method: 'app-store'`; Fastlane 2.238.0 rejects `app-store-connect`.
- `verify_export` accepts zero options and has no Pilot, Deliver, App Store, TestFlight, or GitHub
  publication path.
- Write the dSYM zip beside the Xcode archive; do not add output-path configurability.
- Do not copy, move, delete, or clean existing archives under `~/Archives/family-foqos`.
- Advance 2.0.28 (47) to 2.0.29 (48), or rebase and select the next unused pair if `main` advances.
- Obtain successful maintainer-assisted `verify_export` proof and independent review before merge.

---

### Task 1: Replace the wrapper-owned formatter without weakening status propagation

**Files:**
- Modify: `scripts/test-xcode-stream.sh:279-420,530-590,680-790`
- Modify: `scripts/xcode-stream.sh:193-246,267-345,510-512`

**Interfaces:**
- Consumes: the existing `scripts/xcode-stream.sh --agent NAME [--session NAME] -- COMMAND`
  interface and simulator-gate environment contract.
- Produces: `--xcbeautify`, direct `xcbeautify --version` preflight, and the internal
  `__execute --xcbeautify` marker with unchanged child-first `PIPESTATUS` semantics.

- [ ] **Step 1: Warm signing and SSH credentials from the clean feature worktree**

Run:

```bash
scripts/warm-git-credentials.sh
```

Expected: the script reports a clean named feature branch, a successful signed scratch commit and
SSH push dry-run, restores `chore/412-xcbeautify-migration`, and leaves `git status --short` empty.

- [ ] **Step 2: Port the wrapper harness to a direct fake xcbeautify executable**

Replace `write_fake_xcpretty` and its Bundler shim with this direct executable shape, then rename
the fixture log and exit variables consistently:

```bash
write_fake_xcbeautify() {
  cat >"$TEST_ROOT/bin/xcbeautify" <<'EOF'
#!/opt/homebrew/bin/bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  exit "${XCBEAUTIFY_PREFLIGHT_EXIT:-0}"
fi
cat >"$XCBEAUTIFY_INPUT_LOG"
exit "${XCBEAUTIFY_EXIT:-0}"
EOF
  chmod +x "$TEST_ROOT/bin/xcbeautify"
}
```

Use `xcbeautify-input.log`, `XCBEAUTIFY_INPUT_LOG`, `XCBEAUTIFY_EXIT`, and
`XCBEAUTIFY_PREFLIGHT_EXIT`. Change all supported formatted invocations to `--xcbeautify`. Change
the rejected shell-mediated example to end in `| xcbeautify`.

- [ ] **Step 3: Add failing stale-option and direct-preflight regressions**

Add these cases before the supported formatting cases:

```bash
reset_case rejected-missing-xcbeautify
mkdir -p "$CASE_ROOT/no-xcbeautify-bin"
cat >"$CASE_ROOT/no-xcbeautify-bin/dirname" <<'EOF'
#!/opt/homebrew/bin/bash
exec /usr/bin/dirname "$@"
EOF
chmod +x "$CASE_ROOT/no-xcbeautify-bin/dirname"
set +e
output=$(PATH="$CASE_ROOT/no-xcbeautify-bin" "$WRAPPER" \
  --agent build2 --session collab --xcbeautify -- xcodebuild test 2>&1)
status=$?
set -e
if [[ "$status" -ne 127 || "$output" != *"xcbeautify"* ]]; then
  fail "missing xcbeautify must exit 127 and name xcbeautify: exit=$status output=$output"
fi
[[ ! -s "$GATE_LOG" ]] || fail "missing xcbeautify reached the gate"

reset_case rejected-xcpretty-option
set +e
output=$(run_wrapper --agent build2 --session collab --xcpretty -- xcodebuild test 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 || "$output" != *"use --xcbeautify"* ]]; then
  fail "stale --xcpretty usage must name --xcbeautify: exit=$status output=$output"
fi
[[ ! -s "$GATE_LOG" ]] || fail "stale --xcpretty usage reached the gate"

reset_case rejected-xcbeautify-unavailable
set +e
output=$(XCBEAUTIFY_PREFLIGHT_EXIT=19 run_wrapper \
  --agent build2 --session collab --xcbeautify -- xcodebuild test 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 || "$output" != *"xcbeautify"* ]]; then
  fail "unavailable xcbeautify must be named and rejected: $output"
fi
[[ ! -s "$GATE_LOG" ]] || fail "unavailable xcbeautify reached the gate"
```

Retain the existing assertions for gate status 29, child status 23, formatter status 17, merged
stdout/stderr, immediate-child scope, and the unformatted path. Do not add source-text assertions
for human documentation; Task 5 updates and directly reviews current docs, and Task 6 scans active
surfaces for missed callers.

- [ ] **Step 4: Run the focused harness and confirm the production wrapper is still red**

Run:

```bash
bash scripts/test-xcode-stream.sh
```

Expected: FAIL because `scripts/xcode-stream.sh` does not yet accept `--xcbeautify`, and the stale
option does not yet name its replacement. Do not accept a failure caused by a malformed fixture.

- [ ] **Step 5: Implement the direct xcbeautify pipeline and fail-closed option handling**

Rename `use_xcpretty` to `use_xcbeautify` throughout. In both public and internal parsers, accept
only `--xcbeautify`. Add a public parser branch before generic usage handling:

```bash
--xcpretty)
  die "--xcpretty was removed; use --xcbeautify"
  ;;
```

Preflight before `gate status`:

```bash
[[ "$use_xcbeautify" != true || "${command[0]##*/}" == "xcodebuild" ]] ||
  die "--xcbeautify requires xcodebuild immediately after --"
if [[ "$use_xcbeautify" == true ]]; then
  command -v xcbeautify >/dev/null || {
    echo "xcode-stream: xcbeautify not found; install it with: brew install xcbeautify" >&2
    exit 127
  }
  xcbeautify --version >/dev/null 2>&1 ||
    die "xcbeautify unavailable; reinstall it with: brew install xcbeautify"
fi
```

Replace the formatted child pipeline with:

```bash
"$@" \
  -destination "$IOS_SIM_GATE_DESTINATION" \
  -derivedDataPath "$IOS_SIM_GATE_DERIVED_DATA_PATH" \
  -parallel-testing-enabled NO \
  -disable-concurrent-destination-testing \
  2>&1 | xcbeautify
pipeline_statuses=("${PIPESTATUS[@]}")
```

Keep the existing decision: exit with `pipeline_statuses[0]` when nonzero, otherwise exit with
`pipeline_statuses[1]`.

- [ ] **Step 6: Run focused verification**

Run:

```bash
bash -n scripts/xcode-stream.sh
bash -n scripts/test-xcode-stream.sh
bash scripts/test-xcode-stream.sh
```

Expected: shell syntax and every wrapper execution and exact-status assertion pass.

- [ ] **Step 7: Commit the wrapper migration**

```bash
git add scripts/xcode-stream.sh scripts/test-xcode-stream.sh
git commit -S -m "build: migrate xcode stream to xcbeautify"
```

---

### Task 2: Pin Fastlane 2.238.0 and test Gym's shipped export validator

**Files:**
- Modify: `Gemfile:1-7`
- Modify: `Gemfile.lock`
- Modify: `fastlane/Fastfile:42-57`
- Modify: `fastlane/Snapfile:1-26`
- Modify: `scripts/test-fastlane-export-method.rb:1-34`
- Modify: `scripts/test-fastlane-sim-gate.sh:70-95`

**Interfaces:**
- Consumes: `Gym::Options.available_options` from the Bundler-pinned Fastlane gem and
  `build_app_store_archive(api_key:, build:)`.
- Produces: Fastlane 2.238.0, explicit `xcodebuild_formatter: 'xcbeautify'`, Snapfile
  `xcodebuild_formatter('xcbeautify')`, and a regression at Gym's executable configuration layer.

- [ ] **Step 1: Strengthen the export-method test before changing the pin**

Create real Gym configurations with the shipped option definitions:

```ruby
def gym_configuration(export_method)
  FastlaneCore::Configuration.create(
    Gym::Options.available_options,
    { export_method: export_method }
  )
end

gym_configuration('app-store')
begin
  gym_configuration('app-store-connect')
  warn 'FAIL: shipped Gym unexpectedly accepted app-store-connect'
  exit 1
rescue FastlaneCore::Interface::FastlaneError
  # Expected for Fastlane 2.238.0.
end
```

Keep the existing capture of the real private archive lane and additionally require:

```ruby
unless captured_options&.fetch(:export_method) == 'app-store'
  warn 'FAIL: archive lane did not configure Gym for an App Store export'
  exit 1
end
unless captured_options.fetch(:xcodebuild_formatter) == 'xcbeautify'
  warn 'FAIL: archive lane did not configure Gym for xcbeautify'
  exit 1
end
```

In `scripts/test-fastlane-sim-gate.sh`, assert
`captured.fetch(:xcodebuild_formatter) == 'xcbeautify'` after evaluating the Snapfile.

- [ ] **Step 2: Run the Fastlane formatter tests and confirm they fail for the expected reasons**

Run:

```bash
bundle exec ruby scripts/test-fastlane-export-method.rb
bash scripts/test-fastlane-sim-gate.sh
```

Expected: the archive test fails because Gym options do not contain the explicit formatter, and
the simulator-gate test fails because Snapfile still resolves xcpretty.

- [ ] **Step 3: Update the pin and lockfile**

Change `Gemfile` to:

```ruby
gem "fastlane", "2.238.0"
```

Then run:

```bash
bundle update fastlane --conservative
bundle check
bundle exec fastlane --version
```

Expected: `Gemfile.lock` pins `fastlane (2.238.0)`, `bundle check` passes, and Fastlane reports
2.238.0. Retain xcpretty lock entries when Fastlane still declares them transitively.

- [ ] **Step 4: Configure both Fastlane Xcode entrypoints for xcbeautify**

In the Gym call, update the version comment and add:

```ruby
# Gym 2.238.0 still rejects Xcode's app-store-connect spelling before archiving.
export_method: 'app-store',
xcodebuild_formatter: 'xcbeautify',
```

Replace the Snapfile formatter with:

```ruby
xcodebuild_formatter("xcbeautify")
```

- [ ] **Step 5: Run the pinned-gem and Snapfile regressions**

Run:

```bash
bundle exec ruby scripts/test-fastlane-export-method.rb
bash scripts/test-fastlane-sim-gate.sh
bundle exec rubocop fastlane/Fastfile scripts/test-fastlane-export-method.rb
```

Expected: `app-store` is accepted, `app-store-connect` is rejected by Fastlane 2.238.0, both
entrypoints select xcbeautify, and RuboCop passes.

- [ ] **Step 6: Commit the Fastlane pin and formatter configuration**

```bash
git add Gemfile Gemfile.lock fastlane/Fastfile fastlane/Snapfile \
  scripts/test-fastlane-export-method.rb scripts/test-fastlane-sim-gate.sh
git commit -S -m "build: pin fastlane 2.238 with xcbeautify"
```

---

### Task 3: Add a credentialed export proof with no upload edge

**Files:**
- Create: `scripts/test-fastlane-verify-export.rb`
- Modify: `scripts/test-fastlane-credential-routing.sh:100-145`
- Modify: `scripts/fastlane.sh:14-28`
- Modify: `fastlane/Fastfile:160-180`

**Interfaces:**
- Consumes: `asc_api_key`, `derived_build_number`, and
  `build_app_store_archive(api_key:, build:)`.
- Produces: public zero-option lane `verify_export` and credential routing through
  `scripts/fastlane.sh verify_export`; there is no artifact publication or upload callback.

- [ ] **Step 1: Add the credential-routing regression**

Add `verify_export` to the credential-lane list:

```bash
for lane in check_asc_key pull_metadata beta release verify_export; do
```

Extend the fake tool setup with an executable `xcbeautify` that returns zero for `--version`. Add
separate missing and failed-version cases for the formatter-using lane set
`screenshots beta release verify_export`, asserting exit 127 for a missing command, nonzero for a
failed version probe, and no `op` or `bundle` invocation.

- [ ] **Step 2: Add a behavioral Fastlane lane regression**

Create `scripts/test-fastlane-verify-export.rb`. Load Fastlane actions and the real Fastfile. Stub
the credential, shell, and build actions, while making every upload action and dSYM publication
raise immediately:

```ruby
require 'base64'
require 'fastlane'
require 'openssl'

Fastlane.load_actions
raw_pem = OpenSSL::PKey::EC.generate('prime256v1').to_pem
ENV['ASC_KEY_ID'] = 'TESTKEY123'
ENV['ASC_ISSUER_ID'] = '11111111-2222-3333-4444-555555555555'
ENV['ASC_KEY_CONTENT_BASE64'] = Base64.strict_encode64(raw_pem)

captured_builds = []
Fastlane::Actions::AppStoreConnectApiKeyAction.singleton_class.define_method(:run) do |_options|
  {
    key: raw_pem,
    key_id: 'TESTKEY123',
    issuer_id: '11111111-2222-3333-4444-555555555555'
  }
end
Fastlane::Actions::ShAction.singleton_class.define_method(:run) { |_options| "123\n" }
Fastlane::Actions::BuildAppAction.singleton_class.define_method(:run) do |options|
  captured_builds << options
  nil
end
[Fastlane::Actions::PilotAction, Fastlane::Actions::DeliverAction].each do |action|
  action.singleton_class.define_method(:run) { |_options| raise 'upload path reached' }
end
ArchiveStorage.singleton_class.define_method(:upload_dsyms) do |**_options|
  raise 'dSYM publication path reached'
end
```

Call `fastfile.runner.lanes.fetch(:ios).fetch(:verify_export).call({})`. Assert one build, build
number `123`, `export_method == 'app-store'`, and `xcodebuild_formatter == 'xcbeautify'`. A reached
Pilot, Deliver, or publication edge fails by construction.

- [ ] **Step 3: Run both tests and verify they fail before implementation**

Run:

```bash
bash scripts/test-fastlane-credential-routing.sh
bundle exec ruby scripts/test-fastlane-verify-export.rb
```

Expected: credential routing fails because `verify_export` bypasses `op`; the Ruby test fails
because the lane does not exist.

- [ ] **Step 4: Add xcbeautify preflight and credential routing to the wrapper**

After Homebrew Ruby is added to `PATH`, preflight xcbeautify only for Xcode-using lanes:

```bash
case "${1:-}" in
  screenshots|beta|release|verify_export)
    command -v xcbeautify >/dev/null || {
      echo "xcbeautify is required. Install it with: brew install xcbeautify" >&2
      exit 127
    }
    xcbeautify --version >/dev/null 2>&1 || {
      echo "xcbeautify is unavailable. Reinstall it with: brew install xcbeautify" >&2
      exit 1
    }
    ;;
esac
```

Add `verify_export` to the existing credential case with `beta`, `release`, `pull_metadata`, and
`check_asc_key`.

- [ ] **Step 5: Add the structurally upload-free public lane**

Add immediately before `release`:

```ruby
desc 'Verify App Store archive and export without uploading'
lane :verify_export do
  api_key = asc_api_key
  build = derived_build_number
  build_app_store_archive(api_key: api_key, build: build)
end
```

Do not call `preflight`, `assert_no_release_blockers`, archive artifact preparation, Pilot,
Deliver, or dSYM publication from this lane.

- [ ] **Step 6: Run proof-lane regression and script checks**

Run:

```bash
bash -n scripts/fastlane.sh
bash -n scripts/test-fastlane-credential-routing.sh
bash scripts/test-fastlane-credential-routing.sh
bundle exec ruby scripts/test-fastlane-verify-export.rb
bundle exec rubocop fastlane/Fastfile scripts/test-fastlane-verify-export.rb
```

Expected: routing, dependency failures, single-build behavior, and the unreachable upload traps all
pass.

- [ ] **Step 7: Commit the no-upload verification lane**

```bash
git add fastlane/Fastfile scripts/fastlane.sh \
  scripts/test-fastlane-credential-routing.sh scripts/test-fastlane-verify-export.rb
git commit -S -m "build: add upload-free export verification lane"
```

---

### Task 4: Zip dSYMs from the lane-context archive and delete archive duplication

**Files:**
- Modify: `fastlane/archive_storage.rb:1-51`
- Modify: `scripts/test-archive-storage.rb:1-260`
- Modify: `fastlane/Fastfile:1-18,80-112,185-208`

**Interfaces:**
- Consumes: `SharedValues::XCODEBUILD_ARCHIVE` and a zipper block receiving
  `(source_dsyms_directory, destination_zip)`.
- Produces: `ArchiveStorage.create_dsym_zip(archive:, destination:) -> String` and
  `prepare_archive_dsyms -> { version:, build:, stem:, archive:, dsym_zip: }`.

- [ ] **Step 1: Replace archive-copy fixtures with direct dSYM-zip regressions**

Delete every `replace_directory` recovery, backup, interrupt, and copy fixture. Add:

```ruby
Dir.mktmpdir do |root|
  archive = File.join(root, 'FamilyFoqos.xcarchive')
  source = File.join(archive, 'dSYMs')
  destination = File.join(root, 'FamilyFoqos-dSYMs.zip')
  FileUtils.mkdir_p(source)
  File.write(File.join(source, 'FamilyFoqos.app.dSYM'), 'symbols')

  observed = nil
  result = ArchiveStorage.create_dsym_zip(archive: archive, destination: destination) do |from, to|
    observed = [from, to]
    File.write(to, 'zip-bytes')
  end

  raise 'wrong dSYM source' unless observed == [source, destination]
  raise 'wrong zip result' unless result == destination && File.file?(destination)
end
```

Add cases proving a missing `<archive>/dSYMs` raises `ArgumentError`, a zipper exception propagates,
and a zipper block that produces no destination raises `RuntimeError`. Keep the existing
`upload_dsyms` create/retry argument assertions. End with:

```ruby
puts 'PASS: direct dSYM preparation and GitHub retry are recoverable'
```

- [ ] **Step 2: Run the archive harness and confirm the new interface is missing**

Run:

```bash
bundle exec ruby scripts/test-archive-storage.rb
```

Expected: FAIL because `ArchiveStorage.create_dsym_zip` is undefined.

- [ ] **Step 3: Replace whole-directory storage with the narrow zip contract**

Remove `require 'securerandom'` and all of `replace_directory`. Add:

```ruby
def self.create_dsym_zip(archive:, destination:)
  source = File.join(archive, 'dSYMs')
  raise ArgumentError, "Archive dSYMs not found: #{source}" unless File.directory?(source)

  FileUtils.rm_f(destination)
  yield(source, destination)
  raise "dSYM zip was not created: #{destination}" unless File.file?(destination)

  destination
end
```

Keep `upload_dsyms` unchanged.

- [ ] **Step 4: Replace `preserve_archive_locally` with direct preparation**

Remove `ARCHIVE_DIR` and rename the private lane to `prepare_archive_dsyms`. Validate the
lane-context archive, derive the existing version/build/SHA stem, and use:

```ruby
dsym_zip = File.join(File.dirname(archive), "#{stem}-dSYMs.zip")
ArchiveStorage.create_dsym_zip(archive: archive, destination: dsym_zip) do |source, destination|
  Dir.chdir(source) { sh('zip', '-qr', destination, '.') }
end
UI.success("dSYMs prepared: #{dsym_zip}")
```

Return:

```ruby
{
  version: version,
  build: build,
  stem: stem,
  archive: archive,
  dsym_zip: dsym_zip
}
```

Change beta/release to call `prepare_archive_dsyms` before their existing Apple upload. Update the
publication warning from `local archive is safe` to `dSYM zip remains at #{artifacts[:dsym_zip]}`.

- [ ] **Step 5: Verify direct artifacts and complete deletion of copy machinery**

Run:

```bash
bundle exec ruby scripts/test-archive-storage.rb
bundle exec ruby scripts/test-fastlane-verify-export.rb
bundle exec rubocop fastlane/archive_storage.rb fastlane/Fastfile scripts/test-archive-storage.rb
rg -n 'ARCHIVE_DIR|preserve_archive_locally|replace_directory|\.tmp-|\.backup-' \
  fastlane scripts/test-archive-storage.rb
```

Expected: all tests and RuboCop pass; `rg` returns exit 1 with no matches. Confirm no command touched
`~/Archives/family-foqos`.

- [ ] **Step 6: Commit the direct dSYM artifact flow**

```bash
git add fastlane/archive_storage.rb fastlane/Fastfile scripts/test-archive-storage.rb
git commit -S -m "build: stop duplicating Xcode archives"
```

---

### Task 5: Synchronize current documentation and release metadata

**Files:**
- Modify: `AGENTS.md:35-45`
- Modify: `docs/development-workflow.md:55-105`
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj:707-1216`

**Interfaces:**
- Consumes: the supported `--xcbeautify` wrapper and `scripts/fastlane.sh verify_export` lane.
- Produces: current setup/build/lane documentation and uniform version 2.0.29 (48).

- [ ] **Step 1: Update the root command sheet and workflow runbook**

Change the canonical build command in `AGENTS.md` to `--xcbeautify`. Add xcbeautify to the install
line without removing swift-format or ripgrep:

```text
brew install swift-format ripgrep xcbeautify
```

In `docs/development-workflow.md`:

- change the formatted build example to `--xcbeautify`;
- explain that wrapper preflight and the internal pipeline use the standalone xcbeautify binary;
- document `brew install xcbeautify` in setup;
- list `scripts/fastlane.sh verify_export` as archive/export-only with no upload; and
- keep beta/release documented as upload lanes outside the simulator gate.

- [ ] **Step 2: Review current documentation for complete caller migration**

Read the edited `AGENTS.md` and `docs/development-workflow.md` end to end. Confirm they consistently
name the standalone xcbeautify install, wrapper-owned formatted command, upload-free
`verify_export`, and separate beta/release upload lanes. This is human-instruction review, not an
automated source-text test.

- [ ] **Step 3: Advance every project configuration to 2.0.29 (48)**

Replace every project setting value:

```text
MARKETING_VERSION = 2.0.29;
CURRENT_PROJECT_VERSION = 48;
```

Verify uniqueness:

```bash
rg -n 'MARKETING_VERSION = ' FamilyFoqos.xcodeproj/project.pbxproj
rg -n 'CURRENT_PROJECT_VERSION = ' FamilyFoqos.xcodeproj/project.pbxproj
```

Expected: all marketing-version entries are 2.0.29 and all build-version entries are 48.

- [ ] **Step 4: Run documentation, version, and active-reference checks**

Run:

```bash
bash scripts/test-xcode-stream.sh
git add AGENTS.md docs/development-workflow.md FamilyFoqos.xcodeproj/project.pbxproj
candidate_tree=$(git write-tree)
bash scripts/test-check-version-increment.sh origin/main "$candidate_tree"
rg -n 'bundle exec xcpretty' AGENTS.md docs/development-workflow.md \
  scripts/xcode-stream.sh fastlane/Fastfile fastlane/Snapfile
rg -n -- '--xcpretty' AGENTS.md docs/development-workflow.md \
  fastlane/Fastfile fastlane/Snapfile
rg -n -- '--xcpretty' scripts/xcode-stream.sh
rg -n 'xcpretty' Gemfile Gemfile.lock
```

Expected: wrapper and staged-tree version gates pass; both active integration scans return exit 1
with no matches; the wrapper scan shows only its fail-closed removal diagnostic; the dependency
scan may show only Fastlane's transitive xcpretty entries in `Gemfile.lock` and no direct Gemfile
dependency.

- [ ] **Step 5: Commit synchronized docs and version metadata**

```bash
git add AGENTS.md docs/development-workflow.md FamilyFoqos.xcodeproj/project.pbxproj
git commit -S -m "docs: document xcbeautify export workflow"
```

---

### Task 6: Prove the complete process and request independent review

**Files:**
- Verify: all files changed by Tasks 1-5
- Record in PR body: shipped Fastlane 2.238.0 rejects `app-store-connect`; `app-store` retained by
  the issue's conditional rule; real `verify_export` proof result; no upload occurred.

**Interfaces:**
- Consumes: the complete feature branch and maintainer cloud-signing keystrokes.
- Produces: automated evidence, a real formatted build, a real no-upload archive/export, and a
  review-ready non-draft PR.

- [ ] **Step 1: Run all focused tests and static checks**

Run:

```bash
bundle check
bash -n scripts/xcode-stream.sh
bash -n scripts/fastlane.sh
bash -n scripts/test-xcode-stream.sh
bash -n scripts/test-fastlane-credential-routing.sh
bash scripts/test-xcode-stream.sh
bash scripts/test-fastlane-credential-routing.sh
bash scripts/test-fastlane-sim-gate.sh
bash scripts/test-fastlane-gates.sh
bundle exec ruby scripts/test-fastlane-export-method.rb
bundle exec ruby scripts/test-fastlane-verify-export.rb
bundle exec ruby scripts/test-archive-storage.rb
bundle exec rubocop fastlane/Fastfile fastlane/archive_storage.rb \
  scripts/test-fastlane-export-method.rb scripts/test-fastlane-verify-export.rb \
  scripts/test-archive-storage.rb
bash scripts/test-check-version-increment.sh origin/main HEAD
git diff --check origin/main...HEAD
```

Expected: every command passes.

- [ ] **Step 2: Run a real formatted Debug build through the wrapper**

Run only when no other Xcode/simulator stream is active:

```bash
scripts/xcode-stream.sh --agent build1 --session collab --xcbeautify -- \
  xcodebuild -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  -configuration Debug build
```

Expected: xcbeautify renders the build, the wrapper returns zero, and the gate reuses build1's
UUID/DerivedData ownership without creating XCTestDevices clones.

- [ ] **Step 3: Ask planner to stage the maintainer for the real export proof**

Send on `issue/412`: automated checks and the formatted Debug build pass; request maintainer
availability for cloud-signing keystrokes. Do not run beta, release, Pilot, or Deliver.

- [ ] **Step 4: Run the real archive/export-only lane with the maintainer present**

Run:

```bash
scripts/fastlane.sh verify_export
```

Expected: Fastlane 2.238.0 archives and exports successfully using `app-store` and xcbeautify,
returns zero, and performs no TestFlight, App Store, or GitHub upload. Record the resulting archive
and exported IPA paths from Fastlane output without copying either artifact.

- [ ] **Step 5: Confirm the branch is clean and every commit is signed**

Run:

```bash
git status --short --branch
git log --show-signature --format='%h %G? %s' origin/main..HEAD
```

Expected: the worktree is clean and every branch commit reports a good signature.

- [ ] **Step 6: Push and open a ready-for-review PR**

Push `chore/412-xcbeautify-migration` and open a non-draft PR closing #412. The body must include:

- wrapper status/preflight evidence;
- Fastlane 2.238.0 shipped-validator result and why `app-store` remains;
- direct dSYM/no-archive-copy behavior;
- real `verify_export` result and explicit no-upload confirmation;
- formatted Debug build and focused test results; and
- version 2.0.29 (48).

- [ ] **Step 7: Request independent review before merge**

Send planner the PR URL, exact head SHA, test evidence, and real proof evidence. Address every
actionable finding in new signed commits, rerun the affected focused test plus the full Task 6
suite, and request rereview. The planner performs the merge only after the reviewer returns READY.
