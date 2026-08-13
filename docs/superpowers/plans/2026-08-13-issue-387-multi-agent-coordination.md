# Multi-Agent Coordination Rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the six field-tested coordination rules from issue #387 to the operator-facing developer guidelines.

**Architecture:** Treat issue #387 as the authoritative specification. Keep its six common-case actions as self-sufficient one-line rules in `AGENTS.md`, then link once to `docs/multi-agent-coordination.md` for rationale, examples, the full heartbeat, and executable CPU recipes. Verify the rules by exact text audit, independent review, and a planner-led live walkthrough that includes both the safe path and a deliberately induced parked-gate failure.

**Tech Stack:** Markdown, AMQ CLI, GitHub pull-request metadata, repository version gate.

## Global Constraints

- Work only on `docs/387-multi-agent-coordination`, forked from `main@4a4f512e198de0b50b5da695c11f9f25a7569a5e`.
- Issue #387 is the authoritative spec; create no redundant design document.
- Preserve all six issue rules and their operational details without weakening them.
- Apply progressive disclosure: exactly six one-line rules and one detail reference in `AGENTS.md`;
  durable procedure belongs in `docs/multi-agent-coordination.md`, not this historical plan.
- Do not post real human approval requests to the AMQ `user` mailbox; the only exception is the explicitly authorized harmless walkthrough-test message, which the planner must detect and drain immediately.
- Obtain independent reviewer approval before the operator walkthrough.
- Mark the PR ready for review before reporting it merge-ready.
- Obtain explicit maintainer sign-off after they read the final diff and after the walkthrough passes.
- Do not merge; the planner owns merge.
- Advance all 12 configurations from 2.0.25 (44) to 2.0.26 (45), refreshing from live `main` and re-bumping if another PR lands first.
- Do not run Xcode or simulator work; this is an operator-documentation and release-metadata change.

---

### Task 1: Add the six coordination rules and release bump

**Files:**
- Modify: `AGENTS.md`
- Create: `docs/multi-agent-coordination.md`
- Modify: `FamilyFoqos.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: the six numbered requirements in GitHub issue #387.
- Produces: one concise `## Multi-Agent Coordination` index, one durable detail runbook, and
  release 2.0.26 (45) in all configurations.

- [ ] **Step 1: Add the focused guideline section**

Place the section beside the repository's other always-on operational policies. Cover exactly:

1. Human interaction routes through the planner; agents never park real `gate/*` approvals in the `user` mailbox and instead send `blocked on human gate: <what>` on their normal planner thread.
2. At 30 minutes of silence from an agent with in-flight work, the planner drains its own inbox, checks the agent's `inbox/new`, sweeps the `user` mailbox for parked gates, inspects work evidence, and pings the agent directly.
3. `notifier_live` proves only the wake process is alive and is never evidence of progress.
4. An agent announces every waiting state when it begins, including gates, reviews, and dependencies.
5. A merge-ready PR is already ready for review, never draft.
6. A turn never ends with only promised future work; if work remains, the final message names the exact remainder. Planner heartbeat uses commit age, dirty files, and CPU delta rather than message recency as work evidence.

- [ ] **Step 2: Bump every configuration**

Change every `CURRENT_PROJECT_VERSION = 44;` to `45` and every
`MARKETING_VERSION = 2.0.25;` to `2.0.26`. Do not change other project settings.

- [ ] **Step 3: Run static verification**

Run:

```bash
rg -n '^## Multi-Agent Coordination|blocked on human gate|30 minutes|inbox/new|notifier_live|waiting state|draft|future work|commit age|dirty files|CPU delta' AGENTS.md
test "$(rg -c 'CURRENT_PROJECT_VERSION = 45;' FamilyFoqos.xcodeproj/project.pbxproj)" -eq 12
test "$(rg -c 'MARKETING_VERSION = 2.0.26;' FamilyFoqos.xcodeproj/project.pbxproj)" -eq 12
scripts/test-check-version-increment.sh
git diff --check
```

Expected: the text audit finds one section and every required operational phrase; both counts are
12; the version gate and diff check pass.

- [ ] **Step 4: Commit the implementation**

```bash
git add AGENTS.md FamilyFoqos.xcodeproj/project.pbxproj
git commit -S -m "docs: add multi-agent coordination rules"
```

### Task 2: Verify and obtain independent review

**Files:**
- Verify only: `AGENTS.md`, `FamilyFoqos.xcodeproj/project.pbxproj`.

**Interfaces:**
- Consumes: the exact committed Task 1 head.
- Produces: a clean evidence packet and reviewer READY decision before operator testing.

- [ ] **Step 1: Verify the exact committed head**

Run the Task 1 static checks again, plus:

```bash
scripts/check-c2-guards.sh
scripts/check-sync-guards.sh
/usr/bin/ruby scripts/check-log-privacy.rb --root .
git merge-base --is-ancestor origin/main HEAD
test -z "$(git status --porcelain)"
```

Expected: every command returns zero; no Xcode or simulator command runs.

- [ ] **Step 2: Request independent read-only review**

Send the reviewer issue URL, exact base/head SHAs, final diff, six-rule mapping, version evidence,
and planned operator walkthrough. Ask for Critical/Important/Minor findings and READY yes/no. The
reviewer must not mutate files or run Xcode.

- [ ] **Step 3: Address findings with new commits**

Fix all Critical and Important findings without amend or force-push, rerun proportionate checks,
and obtain READY on the new exact head.

### Task 3: Publish an undrafted PR and run the operator walkthrough

**Files:**
- No source changes unless the walkthrough exposes a documentation defect.

**Interfaces:**
- Consumes: independently approved exact head.
- Produces: a ready-for-review PR, live evidence for all testable coordination rules, and maintainer sign-off.

- [ ] **Step 1: Refresh, push, and open the PR ready for review**

Refresh `origin/main`, preserve ancestry, resolve any version collision in a new signed commit,
push the branch, and open a non-draft PR titled `Document multi-agent coordination rules (#387)`
with `Closes #387`. Require green GitHub checks and verify `isDraft=false`, `mergeable=MERGEABLE`,
the reviewed head SHA, and base `main` before calling it merge-ready.

- [ ] **Step 2: Run the safe human-gate and blocker-announcement demonstration**

On the #387 planner thread, send this harmless status at the moment the simulated wait begins:

```text
blocked on human gate: walkthrough-only confirmation; no real work is blocked
```

The planner confirms it was drained on the normal thread and that the `user` mailbox has no new
message from this safe-path demonstration.

- [ ] **Step 3: Induce and detect the documented parked-gate failure**

Send one clearly labeled harmless walkthrough-test message to the `user` mailbox on a stable
`gate/387-walkthrough-test` thread. The planner then performs the documented sweep, finds and
drains it, and confirms no test gate remains parked. This is the only authorized exception to the
new no-`user`-mailbox rule.

- [ ] **Step 4: Demonstrate the full quiet-agent heartbeat**

Without waiting 30 minutes, the planner runs the sequence on a live agent:

1. drain the planner inbox;
2. inspect the target agent's `inbox/new` to see whether instructions were consumed;
3. inspect the `user` mailbox for parked gates;
4. inspect commit age, dirty files, and CPU delta as work evidence; and
5. ping the agent directly.

Record that `notifier_live` was treated only as wake-process evidence, not progress evidence.
The walkthrough transcript must state that this accelerated demonstration validates the five-step
response sequence but does not validate detection of the 30-minute trigger itself.

- [ ] **Step 5: Audit PR readiness and turn-ending text**

Show `isDraft=false` in PR metadata. Inspect the implementer's current handoff: if work remains,
it names the exact remainder; once nothing remains, it says the work is complete rather than
announcing a future action.

- [ ] **Step 6: Obtain maintainer sign-off**

After the reviewer is READY and every walkthrough step passes, ask the planner to have the
maintainer read the final PR diff and explicitly sign off. Do not ask the maintainer to join a
read-along session. Do not hand off for merge until the planner reports the sign-off.

- [ ] **Step 7: Hand off to the planner for merge**

Send the PR URL, exact head/base SHAs, independent review decision, green checks, walkthrough
evidence, and maintainer sign-off. The planner merges; build1 does not.

### Task 4: Apply maintainer-requested progressive disclosure

**Files:**
- Modify: `AGENTS.md`
- Create: `docs/multi-agent-coordination.md`
- Modify: `docs/superpowers/plans/2026-08-13-issue-387-multi-agent-coordination.md`

**Interfaces:**
- Consumes: the six walkthrough-tested rules and both verified CPU-delta recipes at `2d22c5c`.
- Produces: six common-case one-liners plus one resolvable detail link in `AGENTS.md`; a durable
  runbook containing all relocated detail with no behavioral change.

- [ ] **Step 1: Write and run a failing structure audit**

The audit must require exactly six bullets between `## Multi-Agent Coordination` and the next
level-two heading, exactly one reference to `docs/multi-agent-coordination.md`, no fenced code in
that root section, all six common-case actions, and a present link target. It must fail against
`2d22c5c` because the section contains multi-line procedures and no durable detail link.

- [ ] **Step 2: Relocate detail without weakening the one-liners**

Make each root bullet one physical Markdown line and independently actionable. Move the safe gate
example, five-step heartbeat, progress-evidence rationale, fleet CPU recipe, standalone CPU recipe,
foreign-fleet warning, wait announcement, non-draft check, and exact-remainder examples into
`docs/multi-agent-coordination.md`. Add one reference line after the six bullets.

- [ ] **Step 3: Verify the moved operator text**

Run the structure/link audit. Extract and execute both Bash blocks from their new file: verify the
managed-fleet block still fails closed for an unknown role, and verify the standalone block resolves
this project's build1 process twice with a nondecreasing CPU time and exits 1 for a missing role.
Run the repository version, C2, sync, privacy, and whitespace guards.

- [ ] **Step 4: Commit and publish the relocation**

Create one new signed commit; never amend. Push PR #415, update its walkthrough transcript to say
the walkthrough-tested content moved without behavior change, and confirm the exact final head is
OPEN, `isDraft=false`, MERGEABLE/CLEAN with green checks.

- [ ] **Step 5: Repeat the operator-document gates**

Obtain reviewer delta approval and a cheap re-read confirming the six one-liners and reference are
followable. Then ask the maintainer to read the final diff and explicitly sign off. Only after that
sign-off send the merge-ready packet to the planner; build1 does not merge.

### Task 5: Rewrite the full developer guide as an invariant index

**Files:**
- Modify: `AGENTS.md`
- Create: `docs/development-workflow.md`
- Create: `docs/swift-style-guide.md`
- Create: `docs/app-modes-and-locking.md`
- Modify: `docs/multi-agent-coordination.md`
- Create: `scripts/warm-git-credentials.sh`
- Create: `scripts/test-warm-git-credentials.sh`

**Interfaces:**
- Consumes: every normative statement, table, example, and command in `AGENTS.md@669f202`.
- Produces: a root invariant/index file of at most 100 physical lines, four focused durable docs,
  and a tested `scripts/warm-git-credentials.sh` entrypoint.

**Losslessness ledger:**

| Current content | Root keeps | Detail destination |
|---|---|---|
| never amend/force; review before merge | both prohibitions | `docs/development-workflow.md` rationale |
| biometric warm-up transaction/fallback | required script invocation | script + `docs/development-workflow.md` |
| simulator ownership and concurrency | wrapper/UUID/direct-child prohibitions | `docs/development-workflow.md` |
| five script-safety rules | all five terse rules | `docs/development-workflow.md` examples |
| six coordination rules | all six one-liners | `docs/multi-agent-coordination.md` |
| build/test/clean/screenshots/archive/format commands | one-line commands | `docs/development-workflow.md` explanations |
| formatting/imports/naming/SwiftUI/SwiftData/SafeQuery/protocol/error/logging/control-flow/computed/closures/comments/previews/architecture/files | high-risk `@SafeQuery`, save, and Log/privacy invariants | `docs/swift-style-guide.md`, including every example |
| testing best practices | one-Date-per-test invariant | `docs/swift-style-guide.md` |
| app-mode matrix/promotion/lock checks/UI predicates | mode summary and exact predicates/guard | `docs/app-modes-and-locking.md` |
| duplicated Build Output example | canonical wrapper command | `docs/development-workflow.md` |

- [ ] **Step 1: Write the failing root inventory audit**

Create an ad hoc Ruby audit that requires `AGENTS.md` to be at most 100 lines; contain the critical
Git, credential, simulator, script-safety, coordination, SwiftData/logging/testing, and lock-mode
invariants plus canonical one-line commands; link exactly once to each of the four durable docs;
and contain none of the moved example headings, tables, or fenced code blocks. Run it against
`669f202`; expect failure on line budget and missing three detail links.

- [ ] **Step 2: Write the failing warm-up regression harness**

Create `scripts/test-warm-git-credentials.sh` with isolated fake-Git cases for success, dirty tree,
detached/unnamed branch, default branch, non-SSH push URL, signed-commit failure, dry-run failure,
branch restoration, scratch deletion, final clean state, and exact child exit propagation. Run it;
expect failure because `scripts/warm-git-credentials.sh` does not exist.

- [ ] **Step 3: Implement the warm-up script minimally**

Create a Bash entrypoint with `set -euo pipefail`, dependency/precondition diagnostics, unique
scratch branch, cleanup trap, signed empty commit, SSH dry-run, and postcondition checks. Run the
harness; expect every case to pass. Run `shellcheck` on both scripts.

- [ ] **Step 4: Relocate all guide detail using the ledger**

Rewrite root `AGENTS.md` as a self-sufficient invariant/index file of at most 100 lines. Create the
three new focused docs, preserve the existing coordination runbook, and copy every ledger item to
its root/detail destination without semantic deletion. Add the calibrated sign-off contract:
`tiny` means prose-only with no new/changed flow step and no new command; planner classifies and
reviewer may escalate; reviewer approval, green checks, and planner merge remain blocking; name the
delta in the next maintainer report for retroactive veto/revert by new commit; all other operator
changes keep full reviewer/walkthrough/maintainer gates.

- [ ] **Step 5: Run relocation and executable verification**

Run the root inventory/link audit, warm-up harness, shellcheck, `scripts/test-xcode-stream.sh`, both
CPU recipes extracted from `docs/multi-agent-coordination.md`, version/C2/sync/privacy/whitespace
guards, and verify all 12 version settings remain 2.0.26 (45). Compare the ledger with the final
diff and record a destination for every row.

- [ ] **Step 6: Commit, push, and run operator gates**

Create new signed commits without amend, update PR #415 title/body for the full rewrite, and verify
OPEN/non-draft/MERGEABLE-CLEAN exact-head checks. Obtain a full independent reviewer pass using the
losslessness ledger. Ask the planner to stage the real warm-up walkthrough while the maintainer is
physically present; verify the assigned branch/tree are restored. Exercise wrapper entrypoints via
existing tests without launching unnecessary Xcode. Then obtain maintainer final read of the new
root `AGENTS.md` and hand off to the planner for merge.
