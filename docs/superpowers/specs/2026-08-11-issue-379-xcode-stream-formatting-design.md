# Issue #379: Wrapper-Owned Xcode Output Formatting

## Goal

Make the repository's supported formatted `xcodebuild` invocation preserve failures without
requiring callers to configure shell-specific `pipefail` behavior.

The current documented form leaves the pipeline in the caller:

```bash
scripts/xcode-stream.sh --agent build1 --session collab -- \
  xcodebuild test -project FamilyFoqos.xcodeproj -scheme FamilyFoqos \
  2>&1 | bundle exec xcpretty
```

In a fresh zsh process, a wrapper failure returns nonzero by itself but the formatted pipeline
returns `xcpretty`'s zero status. The wrapper's internal `set -o pipefail` cannot affect that outer
pipeline.

## Supported interface

Add one narrow public option to the existing entrypoint:

```bash
scripts/xcode-stream.sh --agent <agent> [--session <session>] --xcpretty -- \
  xcodebuild <arguments>
```

`--xcpretty` is valid only when the command immediately after `--` is `xcodebuild`. The wrapper
rejects the option for clean-build, screenshots, and arbitrary commands before asking the
simulator gate to allocate or mutate anything. Those paths retain their current unformatted
behavior.

`AGENTS.md` uses this form for every canonical formatted build example and removes the caller-side
`set -o pipefail` instruction and external `| bundle exec xcpretty` pipeline. Unformatted test,
clean-build, and screenshot commands remain unchanged.

## Execution boundary

The public wrapper keeps its current `exec` into `ios-sim-gate`. Preflight, registry, allocation,
and gate failures therefore remain visible and preserve their exact status without passing
through a formatter.

The public option is forwarded as a private marker to `__execute`. After the gate has established
the complete internal environment, the direct-`xcodebuild` branch appends the existing exact UUID,
DerivedData, and no-clone arguments, then owns this pipeline:

```text
xcodebuild <caller arguments> <injected arguments> 2>&1 | bundle exec xcpretty
```

The unformatted direct-`xcodebuild` branch continues to `exec` as it does today. The formatted
branch alone retains the internal Bash process to supervise the two pipeline children. The gate
still owns the outer process tree and cleanup boundary.

## Exit-status contract

The formatted branch captures both Bash `PIPESTATUS` entries immediately after the pipeline:

1. If `xcodebuild` returns nonzero, return that exact status.
2. If the child succeeds, return `xcpretty`'s status, including its exact nonzero status.
3. Return zero only when both processes succeed.

This preserves the existing wrapper promise instead of weakening it to an unspecified nonzero.
In particular, child/formatter pairs `23/0` and `0/17` must return `23` and `17`, respectively.

## Validation and failure behavior

- Existing agent, session, command-placement, and injected-argument validation stays unchanged.
- `--xcpretty` with a non-`xcodebuild` child is a usage failure before gate mutation.
- A missing formatter executable or formatter startup failure is reported as a formatter failure
  when the child succeeds.
- Output sent to both stdout and stderr by `xcodebuild` reaches `xcpretty`, matching the current
  documented `2>&1` behavior.
- No generic formatter protocol or second wrapper script is introduced.

## Test strategy

Extend `scripts/test-xcode-stream.sh` with fake `bundle`/`xcpretty` behavior and write the failing
regressions before implementation. Pin all of these cases:

- a fresh `zsh -f` caller with no `pipefail` receives the exact preflight/gate failure status from
  a supported `--xcpretty` invocation;
- child `23`, formatter `0` returns `23`;
- child `0`, formatter `17` returns `17`;
- merged stdout/stderr reaches the formatter;
- `--xcpretty` on a non-`xcodebuild` command fails before any gate mutation;
- the existing unformatted exact-status test remains green; and
- `AGENTS.md` requires the new supported form and no longer documents the unsafe external
  pipeline or caller-managed `pipefail` setup.

Run the complete shell-script regression suite, shell syntax checks, repository policy gates, a
real clean Debug build through `--xcpretty`, and the full gated test suite before review. The
release advances from 2.0.17 (36) to 2.0.18 (37).

## Rejected alternatives

A separate formatting helper would make the implementation small but create a second supported
entrypoint and leave the unsafe syntax easy to rediscover. A generic formatter command protocol
would add nested argument grammar and validation complexity without a second formatter use case.

## Post-merge sharing

The implementation PR closes #379 and merges before any upstream outreach. After the planner
confirms the merge, file one terse issue on `mnbf9rca/ios-sim-gate` describing the adopter-side
pipefail-masking hazard and the wrapper-owned fix, linking the Family Foqos PR as a reference
implementation. The upstream issue shares the settled design and does not demand adoption.
