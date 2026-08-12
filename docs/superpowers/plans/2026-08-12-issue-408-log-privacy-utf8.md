# Locale-Independent Log Privacy UTF-8 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Log Privacy Lint decode all text inputs as UTF-8 and keep its complete fixture suite green when macOS system Ruby has no locale variables.

**Architecture:** The analyzer owns encoding at each `Pathname#read` boundary instead of mutating Ruby's process default or relying on launcher flags. The fixture harness removes `LANG`, `LC_ALL`, and `LC_CTYPE` from every pinned `/usr/bin/ruby` analyzer subprocess, permanently exercising the GUI Xcode environment.

**Tech Stack:** Ruby 2.6 and Ruby 4, `Pathname`, `Open3`, Xcode project version settings, RuboCop.

## Global Constraints

- The shipped analyzer runtime remains `/usr/bin/ruby`; do not change the Xcode Log Privacy Lint phase command.
- Use only APIs supported by macOS system Ruby 2.6; RuboCop targets Ruby 4.0 and is not the compatibility guard.
- Decode every analyzer text input explicitly as `Encoding::UTF_8`; do not assign `Encoding.default_external` or add `-E` launcher flags.
- Every fixture analyzer subprocess must remove `LANG`, `LC_ALL`, and `LC_CTYPE`.
- Preserve all 52 existing privacy-case classifications, diagnostics, Swift fixtures, and baseline values.
- Genuinely invalid UTF-8 must produce a named nonzero file diagnostic; do not normalize or replace invalid bytes.
- Increment `MARKETING_VERSION` from 2.0.22 to 2.0.23 and `CURRENT_PROJECT_VERSION` from 41 to 42.
- Do not run Xcode or simulator tests; locale-stripped Ruby commands reproduce the exact GUI failure boundary.
- Never amend or force-push. All commits must be signed, and independent review is required before merge.

---

### Task 1: Make the locale-stripped fixture condition permanent

**Files:**
- Modify: `scripts/test-check-log-privacy.rb:14-18,439-441`
- Test: `scripts/fixtures/log-privacy/pass/lexer_boundaries.swift` through the existing harness case `lexer skips comments and string contents`

**Interfaces:**
- Consumes: `SYSTEM_RUBY = '/usr/bin/ruby'`, `Open3.capture3`, and the existing 52-case privacy suite.
- Produces: `ANALYZER_ENVIRONMENT`, a frozen hash passed as the first argument to `Open3.capture3` so analyzer subprocesses run without locale variables.

- [ ] **Step 1: Record the existing locale-stripped RED**

Run:

```bash
env -u LANG -u LC_ALL -u LC_CTYPE /usr/bin/ruby scripts/test-check-log-privacy.rb
```

Expected: exit 1; `lexer skips comments and string contents` reports `invalid byte sequence in US-ASCII` from `SwiftLexer#code_mask`.

- [ ] **Step 2: Add the GUI environment to the harness**

Beside `SYSTEM_RUBY`, add:

```ruby
ANALYZER_ENVIRONMENT = {
  'LANG' => nil,
  'LC_ALL' => nil,
  'LC_CTYPE' => nil
}.freeze
```

Change `run_analyzer` to:

```ruby
def run_analyzer(root)
  Open3.capture3(
    ANALYZER_ENVIRONMENT,
    SYSTEM_RUBY,
    ANALYZER.to_s,
    '--root',
    root.to_s
  )
end
```

- [ ] **Step 3: Run the ordinary system-Ruby suite to verify the harness itself exposes the bug**

Run:

```bash
/usr/bin/ruby scripts/test-check-log-privacy.rb
```

Expected: exit 1 with the same Unicode lexer fixture and US-ASCII error, proving ordinary harness runs now exercise the deployed GUI environment.

### Task 2: Decode analyzer inputs explicitly as UTF-8

**Files:**
- Modify: `scripts/check-log-privacy.rb:431-436,507-510`
- Test: `scripts/test-check-log-privacy.rb`

**Interfaces:**
- Consumes: production Swift paths and numeric baseline paths as `Pathname` values.
- Produces: valid UTF-8 strings from `Pathname#read(encoding: Encoding::UTF_8)` under both terminal and GUI-like environments.

- [ ] **Step 1: Pin production Swift source reads**

In `Analyzer#analyze`, replace the implicit read with:

```ruby
source = file.read(encoding: Encoding::UTF_8)
```

- [ ] **Step 2: Pin baseline text reads**

In `read_nonnegative_integer`, replace the implicit read with:

```ruby
value = path.read(encoding: Encoding::UTF_8)
```

- [ ] **Step 3: Add a named invalid-UTF-8 regression case**

Use `with_fixture_root` to overwrite its temporary `Foqos/Fixture.swift` with
`File.binwrite(destination, [0xFF].pack('C'))`. Run the real analyzer and require status 2 plus the
literal diagnostic `Foqos/Fixture.swift:1: error: invalid byte sequence in UTF-8`. Add
`ArgumentError` to the existing per-file rescue list so the analyzer converts the exception into a
path-bearing `Finding` without accepting the damaged file.

- [ ] **Step 4: Run the complete suite under every required harness context**

Run:

```bash
/usr/bin/ruby scripts/test-check-log-privacy.rb
ruby scripts/test-check-log-privacy.rb
env -u LANG -u LC_ALL -u LC_CTYPE /usr/bin/ruby scripts/test-check-log-privacy.rb
```

Expected from each: `PASS: 53 log privacy lint cases`. Every analyzer subprocess is system Ruby with locale variables removed; the third command also proves the harness itself works without a locale.

- [ ] **Step 5: Verify production behavior is locale-independent by effect**

Run:

```bash
/usr/bin/ruby scripts/check-log-privacy.rb --root .
env -u LANG -u LC_ALL -u LC_CTYPE /usr/bin/ruby scripts/check-log-privacy.rb --root .
```

Expected from each: `files_discovered=232 files_analyzed=232 sites_analyzed=500 annotations=0`.

### Task 3: Increment the application version and commit implementation

**Files:**
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`
- Include: `scripts/check-log-privacy.rb`
- Include: `scripts/test-check-log-privacy.rb`

**Interfaces:**
- Consumes: the green locale-independent analyzer and harness from Tasks 1-2.
- Produces: version 2.0.23/build 42 and one signed implementation commit without changes to the Log Privacy Lint phase command.

- [ ] **Step 1: Update all consistent project version settings**

Replace every project build-setting occurrence:

```text
MARKETING_VERSION = 2.0.22; -> MARKETING_VERSION = 2.0.23;
CURRENT_PROJECT_VERSION = 41; -> CURRENT_PROJECT_VERSION = 42;
```

Do not modify the `shellScript` field for Log Privacy Lint.

- [ ] **Step 2: Verify the version delta and Xcode phase stability before committing**

Run:

```bash
git diff -- FamilyFoqos.xcodeproj/project.pbxproj
rg -n 'Log Privacy Lint requires|/usr/bin/ruby' FamilyFoqos.xcodeproj/project.pbxproj
```

The raw diff must show only 2.0.22/41 to 2.0.23/42 changes in the project file. The phase inspection
must show the existing named `/usr/bin/ruby` preflight and absolute invocation unchanged. The
commit-range version gate runs after the implementation commit in Task 4.

- [ ] **Step 3: Run syntax, style, and diff hygiene checks**

Run:

```bash
/usr/bin/ruby -c scripts/check-log-privacy.rb
/usr/bin/ruby -c scripts/test-check-log-privacy.rb
bundle exec rubocop scripts/check-log-privacy.rb scripts/test-check-log-privacy.rb
git diff --check
```

Expected: both syntax checks report `Syntax OK`, RuboCop reports no offenses, and diff check is silent.

- [ ] **Step 4: Create a new signed implementation commit**

Run:

```bash
git add FamilyFoqos.xcodeproj/project.pbxproj \
  scripts/check-log-privacy.rb scripts/test-check-log-privacy.rb
git commit -S -m "Pin log privacy text inputs to UTF-8"
```

Never amend the design or plan commit.

### Task 4: Fresh verification, independent review, and publication

**Files:**
- Verify: all files changed from `origin/main` through final `HEAD`
- Publish: branch `fix/408-pin-log-privacy-utf8`

**Interfaces:**
- Consumes: signed design, plan, and implementation commits plus issue #408.
- Produces: an independently reviewed, undrafted, green PR closing #408 for planner merge.

- [ ] **Step 1: Run all post-commit gates from the clean worktree**

Run the three complete fixture-suite commands and both production-analysis commands from Task 2, then:

```bash
/usr/bin/ruby -c scripts/check-log-privacy.rb
/usr/bin/ruby -c scripts/test-check-log-privacy.rb
bundle exec rubocop scripts/check-log-privacy.rb scripts/test-check-log-privacy.rb
scripts/check-version-increment.sh origin/main HEAD
git diff --check origin/main...HEAD
git status --porcelain=v1
git log --show-signature --format='%h %G? %s' origin/main..HEAD
```

Expected: all suites pass 53 cases; both production runs report identical 232/232 and 500-site totals; syntax, style, version, and diff gates pass; status is empty; every commit has a good signature.

- [ ] **Step 2: Request independent AMQ review**

Send the reviewer the base `814c961`, final head, issue #408, design and plan paths, exact RED/GREEN evidence, and these attention points:

```text
- UTF-8 is explicit at every analyzer text read boundary.
- Harness analyzer subprocesses always remove LANG/LC_ALL/LC_CTYPE.
- No process-global encoding mutation or -E launcher flag exists.
- Xcode build-phase command is unchanged.
- All privacy outcomes and counts are unchanged.
- Version is exactly 2.0.23/build 42.
```

The reviewer must not run Xcode or simulator work. Resolve every actionable finding with a new signed commit, never an amend, and request a delta review.

- [ ] **Step 3: Push and open an undrafted PR after reviewer readiness**

Push `fix/408-pin-log-privacy-utf8`, then create an undrafted PR against `main` with `Closes #408`. Include the root cause, the incidental privacy-prompt ruling, and all verification commands/results.

- [ ] **Step 4: Hand merge ownership to the planner**

Confirm the PR is not a draft and required GitHub checks have started. Send the planner the PR URL, reviewed head, verification evidence, and current check state. The planner merges after required checks; do not merge locally or through GitHub yourself.
