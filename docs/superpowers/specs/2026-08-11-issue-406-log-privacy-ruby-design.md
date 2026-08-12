# Issue #406: Deterministic Log Privacy Ruby Design

## Context

The Log Privacy Lint build phase currently checks `command -v ruby` and invokes the first Ruby on
`PATH`. Agent shells resolve Homebrew Ruby 4.0.6, while GUI Xcode resolves macOS system Ruby 2.6.10.
The same build guard therefore passes or crashes depending on how Xcode was launched, blocking
maintainer device testing.

The failure is reproducible and bounded:

- `/usr/bin/ruby scripts/test-check-log-privacy.rb` crashes because the harness uses `Pathname`
  without requiring `pathname`.
- `/usr/bin/ruby scripts/check-log-privacy.rb --root .` reaches the same missing dependency in the
  analyzer.
- Explicitly loading `pathname` and `set` reaches `Enumerable#filter_map`, which is unavailable in
  Ruby 2.6.
- A diagnostic shim for those three deltas makes all 52 fixtures and the production-tree analysis
  pass under system Ruby. A repository-wide Ruby API audit found no other post-2.6 method usage.

## Decision

System Ruby is the runtime contract for the build guard.

- The Xcode build phase first checks `[ -x /usr/bin/ruby ]` and emits the named dependency error
  `Log Privacy Lint requires macOS system Ruby at /usr/bin/ruby` if it is unavailable, then invokes
  `/usr/bin/ruby` directly. It performs no interpreter lookup and does not depend on GUI or shell
  `PATH` configuration.
- The fixture harness invokes every analyzer subprocess with `/usr/bin/ruby`, matching the runtime
  shipped by the build phase even when the harness itself runs under another Ruby.
- Both analyzer and fixture harness explicitly load `pathname`; the analyzer also explicitly loads
  `set` because it constructs `Set` instances.
- `filter_map` becomes a Ruby-2.6-compatible `each_with_object([])` implementation with identical
  behavior: safe or unclassified interpolations add nothing, and findings append to the result.

The build phase remains the effect-based enforcement point. Any future analyzer use of a runtime API
missing from system Ruby will fail every build rather than passing under one developer's PATH.

### Subsequent environment hardening

PR #411 exposed a third runtime variant: Fastlane launches `gym` under Bundler, and Xcode build
phases inherit `RUBYOPT`, `RUBYLIB`, and related Gem/Bundler variables. Those variables made the
pinned system Ruby load Homebrew Ruby 4 Bundler code and crash before the analyzer started.

The deterministic-runtime contract therefore owns the interpreter's entire environment, not only
its binary path. The Xcode phase now calls `scripts/run-log-privacy-lint.sh`, which launches
`/usr/bin/ruby` through `/usr/bin/env -i` with only explicit analyzer and repository arguments. A
regression runs that wrapper under `bundle exec` and proves the real production-tree analyzer passes
while the parent process carries Bundler's Ruby environment.

## Alternatives Rejected

### Pin Homebrew Ruby

An absolute `/opt/homebrew/bin/ruby` path is not guaranteed on Intel Macs or machines without that
Homebrew installation. Looking up `brew --prefix ruby` reintroduces an external build dependency and
GUI environment variance. This does not satisfy deterministic local builds.

### Vendor or manage a Ruby runtime

A bundled runtime, version manager, or Gem-based toolchain would make a standard-library-only build
guard depend on installation and maintenance machinery. The analyzer needs only Ruby 2.6-compatible
APIs, so that dependency has no compensating value.

## Test Strategy

The existing 52-case fixture suite is the behavioral oracle; privacy classifications and diagnostics
must not change.

The RED baseline is the unmodified system-Ruby suite crash. After the port, verification runs the
complete suite twice:

```bash
/usr/bin/ruby scripts/test-check-log-privacy.rb
ruby scripts/test-check-log-privacy.rb
```

In the first run, both harness and analyzer subprocesses use system Ruby. In the second, the harness
uses PATH Ruby while analyzer subprocesses remain pinned to the shipped system runtime. Thus every
fixture always exercises the deployed analyzer interpreter, while the harness remains compatible
with the developer runtime too.

Both scripts run under macOS system Ruby (`/usr/bin/ruby`, currently 2.6) and therefore must use only
Ruby 2.6-compatible APIs. The project's RuboCop configuration targets Ruby 4.0 and will not catch
compatibility violations; it is a style check, not the compatibility guard. The complete
dual-interpreter fixture suite is that guard and must be run under `/usr/bin/ruby`.

Additional verification runs Ruby 2.6 syntax checks for both scripts, RuboCop under the project
bundle, the analyzer against the production tree with `/usr/bin/ruby`, and a static inspection of the
Xcode phase confirming `/usr/bin/ruby` replaces `command -v ruby` and the bare `ruby` invocation.

## Scope

Files changed by implementation:

- `FamilyFoqos.xcodeproj/project.pbxproj`
- `scripts/check-log-privacy.rb`
- `scripts/test-check-log-privacy.rb`
- project version settings, from 2.0.21/build 40 to 2.0.22/build 41

No privacy policy, fixtures, baselines, Swift sources, Fastlane runtime, or other scripts change.
