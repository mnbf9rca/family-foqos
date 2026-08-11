# Deterministic Log Privacy Ruby Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Log Privacy Lint behave identically in GUI Xcode, CLI builds, and agent runs by shipping and testing against macOS system Ruby 2.6.

**Architecture:** The Xcode phase and fixture analyzer subprocesses use absolute `/usr/bin/ruby`, guarded by a named executable preflight. Both Ruby scripts load their own standard-library dependencies, and the analyzer replaces its sole Ruby-2.7 API with a Ruby-2.6 equivalent while preserving all 52 privacy outcomes.

**Tech Stack:** Ruby 2.6 and Ruby 4, Xcode PBX shell phase, Open3 fixture harness, RuboCop.

## Global Constraints

- The shipped analyzer runtime is `/usr/bin/ruby`; no PATH lookup may select the build-phase interpreter.
- The phase must fail with status 2 and name `/usr/bin/ruby` if the executable is unavailable.
- The complete 52-case suite must pass under both `/usr/bin/ruby` and PATH `ruby`.
- Every fixture analyzer subprocess must use `/usr/bin/ruby`, including when the harness runs under PATH Ruby.
- Privacy findings, diagnostics, baselines, Swift fixtures, and Fastlane runtime behavior must not change.
- MARKETING_VERSION increases from 2.0.21 to 2.0.22 and CURRENT_PROJECT_VERSION from 40 to 41.
- Commits remain signed; never amend or force-push; request independent review before merge.

---

### Task 1: Port analyzer and harness to the shipped Ruby runtime

**Files:**
- Modify: `scripts/check-log-privacy.rb:1-8,597-615`
- Modify: `scripts/test-check-log-privacy.rb:1-12,430-433`

**Interfaces:**
- Consumes: `/usr/bin/ruby`, Ruby standard libraries `pathname`, `set`, and `optparse`.
- Produces: `SYSTEM_RUBY = '/usr/bin/ruby'` in the fixture harness and Ruby-2.6-compatible analyzer execution.

- [ ] **Step 1: Preserve the RED evidence**

Run on the unmodified implementation commit:

```bash
/usr/bin/ruby scripts/test-check-log-privacy.rb
```

Expected: exit 1 with `undefined method 'Pathname'` at harness line 7. Also run the analyzer directly and with explicit standard libraries to record its two-stage failure:

```bash
/usr/bin/ruby scripts/check-log-privacy.rb --root .
/usr/bin/ruby -rpathname -rset scripts/check-log-privacy.rb --root .
```

Expected: missing `Pathname`, followed by missing `filter_map` at analyzer line 599.

- [ ] **Step 2: Load standard-library dependencies explicitly**

At the analyzer top, use:

```ruby
require 'optparse'
require 'pathname'
require 'set'
```

At the fixture harness top, use:

```ruby
require 'fileutils'
require 'open3'
require 'pathname'
require 'tmpdir'
```

- [ ] **Step 3: Pin fixture subprocesses to system Ruby**

Define beside the existing path constants:

```ruby
SYSTEM_RUBY = '/usr/bin/ruby'
```

and change the subprocess boundary to:

```ruby
Open3.capture3(SYSTEM_RUBY, ANALYZER.to_s, '--root', root.to_s)
```

- [ ] **Step 4: Replace `filter_map` without changing results**

Change `analyze_interpolations` to collect with:

```ruby
call.interpolations.each_with_object([]) do |interpolation, findings|
  expression = interpolation.expression.strip
  next if safe_expression?(expression)

  if sensitive_display_name?(expression)
    declarations ||= declarations_before(call, lexer)
    next if safe_presentation_display_name?(expression, declarations)
  end

  message = violation_message(expression)
  finding =
    if message
      Finding.new(path: call.path, line: interpolation.line, message: message)
    elsif (identifier = semantic_identifier(expression))
      analyze_semantic_origin(identifier, call, interpolation, lexer)
    end
  findings << finding if finding
end
```

- [ ] **Step 5: Run GREEN under system Ruby**

Run:

```bash
/usr/bin/ruby scripts/test-check-log-privacy.rb
```

Expected: `PASS: 52 log privacy lint cases`.

### Task 2: Pin the Xcode build phase and verify interpreter parity

**Files:**
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj:565`
- Test: `scripts/test-check-log-privacy.rb`

**Interfaces:**
- Consumes: system-Ruby-compatible analyzer from Task 1.
- Produces: a deterministic Log Privacy Lint phase with a named dependency error.

- [ ] **Step 1: Replace the PATH-dependent phase command**

Set the phase script to the PBX-escaped equivalent of:

```sh
[ -x /usr/bin/ruby ] || {
  echo "error: Log Privacy Lint requires macOS system Ruby at /usr/bin/ruby" >&2
  exit 2
}
/usr/bin/ruby "${SRCROOT}/scripts/check-log-privacy.rb" --root "${SRCROOT}"
```

- [ ] **Step 2: Run the full fixture suite under both harness interpreters**

Run:

```bash
/usr/bin/ruby scripts/test-check-log-privacy.rb
ruby scripts/test-check-log-privacy.rb
```

Expected from each: `PASS: 52 log privacy lint cases`. The analyzer subprocess is `/usr/bin/ruby` in both runs.

- [ ] **Step 3: Run system-Ruby production analysis and syntax checks**

Run:

```bash
/usr/bin/ruby scripts/check-log-privacy.rb --root .
/usr/bin/ruby -c scripts/check-log-privacy.rb
/usr/bin/ruby -c scripts/test-check-log-privacy.rb
```

Expected: production lint passes with discovered/analyzed totals equal; both syntax checks say `Syntax OK`.

- [ ] **Step 4: Run project Ruby lint and inspect the phase**

Run:

```bash
bundle exec rubocop scripts/check-log-privacy.rb scripts/test-check-log-privacy.rb
rg -n "Log Privacy Lint requires|command -v ruby|/usr/bin/ruby" FamilyFoqos.xcodeproj/project.pbxproj
```

Expected: RuboCop reports no offenses; the phase contains the named `/usr/bin/ruby` preflight and invocation, with no `command -v ruby`.

### Task 3: Version, review, and publish

**Files:**
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj` version settings
- Include: `docs/superpowers/specs/2026-08-11-issue-406-log-privacy-ruby-design.md`
- Include: `docs/superpowers/plans/2026-08-11-issue-406-log-privacy-ruby.md`

**Interfaces:**
- Consumes: the dual-interpreter GREEN implementation.
- Produces: a signed, reviewed, merge-ready PR closing issue #406.

- [ ] **Step 1: Apply the required version increment**

Replace every consistent project setting:

```text
MARKETING_VERSION = 2.0.21 -> 2.0.22
CURRENT_PROJECT_VERSION = 40 -> 41
```

- [ ] **Step 2: Commit implementation and plan**

Stage only the project file, analyzer, harness, and plan; create a new signed commit. Do not amend the two design commits.

- [ ] **Step 3: Run fresh post-commit verification**

Repeat both full fixture-suite commands, production analysis, both Ruby 2.6 syntax checks, RuboCop, `git diff --check`, and:

```bash
scripts/check-version-increment.sh origin/main HEAD
```

Expected version-gate output: 2.0.21 -> 2.0.22 and 40 -> 41.

- [ ] **Step 4: Request independent read-only review**

Provide the reviewer base `cd6d1f4`, the final head, this plan, exact RED/GREEN evidence, and attention points: build-phase preflight, analyzer subprocess pin, Ruby-2.6 API parity, unchanged privacy outcomes, and dual-interpreter semantics. The reviewer must not run Xcode builds or simulator tests.

- [ ] **Step 5: Publish merge-ready**

After review readiness and fresh verification, push `fix/406-pin-log-privacy-ruby` and open an un-drafted PR with `Closes #406`. Wait for all required checks, then hand the clean PR to the planner for merge.
