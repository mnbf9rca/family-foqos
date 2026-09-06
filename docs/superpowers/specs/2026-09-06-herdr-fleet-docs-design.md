# Herdr Fleet Documentation Design

**Date:** September 6, 2026. **Base:** `main` at `60babac`. **Branch:** `docs/herdr-fleet`. **Revision:** 3, after the reviewer's second adversarial round.

This document is the spec and the plan in one. No separate plan round follows. A builder implements it as one PR in its own worktree.

## Problem

`AGENTS.md`, `docs/multi-agent-coordination.md`, and one paragraph of `docs/development-workflow.md` describe an AMQ mailbox fleet (AMQ, `AM_ME`, `AM_ROOT`, `agentctl`, tmux, the `user` mailbox) that no longer exists. The fleet now runs in Herdr with agents addressed by name, and the documents must say so.

## Decided facts (not open for redesign)

- The fleet is one Herdr workspace with one agent per tab. Roles and names: `orchestrator` (Claude), `planner` (Claude, fable), `build1` (Codex), `build2` (Codex), `reviewer` (Codex).
- Messaging is `herdr agent prompt <name> "<text>" [--wait --timeout <ms>]`. Replies are read with `herdr agent read <name> --source recent-unwrapped --lines N`. Agent state (`idle`, `working`, `blocked`, `done`, `unknown`) comes from Herdr screen detection.
- Startup sequence: every agent auto-loads `AGENTS.md` when it starts; the orchestrator's first prompt names the agent's role; the agent then reads `docs/multi-agent-coordination.md` for that role's rules before taking work.
- The orchestrator is the human's eyes, ears, and proxy. It dispatches work, relays human decisions, owns the quiet-agent heartbeat, and arbitrates planner-versus-reviewer disagreements. It decides when one side rests on something checkable (code, an existing invariant, a reproduced result) and the other does not, applying KISS, YAGNI, and right-sizing with first-hand knowledge of the human's intent. It escalates to the human when the disagreement is about preference, product behaviour, scope, or blast radius (release, user data, security, user-facing text), and always after two unresolved rounds. It produces no repository artifacts. It verifies agent claims through its own subagents or workflows, not in its own context. It merges only after asking the human for that specific PR.
- Review rounds run directly between planner and reviewer. The planner prompts the reviewer by name, sends the orchestrator a one-line notice when it requests a review and when the verdict arrives, and escalates to the orchestrator only if a disagreement survives two rounds. Dispatch, human gates, heartbeat, and merge asks stay with the orchestrator.
- The planner writes specs and plans and does not implement. Builders implement in their own worktree and branch with disjoint files, and all simulator work goes through `scripts/xcode-stream.sh` (unchanged). The reviewer does adversarial design review (correctness, over-engineering, missing cases that matter in practice) and independent code review before every merge.
- A brief from the orchestrator to any agent contains only a one-sentence problem statement, the human's rulings that are not open for redesign, real details the agent cannot discover itself, and how to report back. It never contains method, model, effort, or workflow guidance. Project conventions and operational facts live in project docs, never in any agent's private memory.
- Operational recipes are replaced, not deleted. Human gates route through the orchestrator. The quiet-agent heartbeat and CPU-delta recipe use Herdr. Warm-git-credentials dispatch comes from the orchestrator. `AGENTS.md` stays an index-sized invariant sheet; detail lives in `docs/multi-agent-coordination.md`.
- Rulings on the first revision's open questions: hub-and-spoke messaging except for the direct planner-reviewer review loop; the orchestrator owns the heartbeat; the `--agent <Herdr name> --session collab` convention is documented in this change; the tiny-delta retroactive veto collapses into the per-PR merge ask; the two Codex startup gotchas go in the runbook; the dated 2026-08-13 plan stays untouched.

## Inventory

Active guidance with stale fleet content:

| File | Stale content | Action |
|---|---|---|
| `AGENTS.md` | Lines 9, 10, 26, 27, 28 name the planner as merger and dispatcher, the AMQ `user` mailbox, `inbox/new`, and `notifier_live`. | Edit the listed lines. Replacement text below. |
| `docs/multi-agent-coordination.md` | Whole file is written around AMQ threads, mailboxes, `agentctl`, tmux, `AM_ME`, and `AM_ROOT`. | Replace the file body. Full replacement text below. |
| `docs/development-workflow.md` | Line 20: "the planner dispatches this warm-up". No explanation of what `--agent` and `--session` mean now. | One-word edit plus one added sentence. |
| `.gitignore` | Local `.agent-mail/` and `.amqrc` leftovers still exist. | No change; retain their ignore entries per the human ruling. |

Historical records that mention the old fleet and stay untouched: every file under `docs/superpowers/plans/` and `docs/superpowers/specs/`, including this document. They record what was done at the time and are not live instructions. `FoqosTests/MutationFunnelTests.swift` and the 2026-07-03 sync-engine plan use the word "user" for a SwiftData context, which is a false positive.

`scripts/xcode-stream.sh`, `scripts/warm-git-credentials.sh`, and their tests contain no fleet references and do not change.

## Change 1: `AGENTS.md`

Keep every section, heading, and bullet not listed here exactly as it is. Formatting note for the builder: the human's global instruction forbids hard-wrapped Markdown, so write new lines unwrapped.

### Engineering Invariants

Replace line 9 with:

> - Obtain independent adversarial design review (correctness, over-engineering, missing cases that matter in practice) before implementation and independent code review before every merge. The orchestrator merges, and only after asking the human about that specific PR.

Replace line 10 with:

> - At fleet startup while the human is present, the orchestrator dispatches `scripts/warm-git-credentials.sh` to every implementation stream; each stream runs it in its clean assigned feature worktree before taking implementation work, and reruns it only if signing or SSH approval expires mid-session while the human is present.

### Multi-Agent Coordination

Replace the six bullets (lines 26 to 31) with these nine. The closing "See [Multi-Agent Coordination]" line stays. The roster detail, arbitration criteria, brief contents, heartbeat steps, and recovery paths live only in the runbook.

> - The fleet is one Herdr workspace with agents addressed by name: `orchestrator` (the human's proxy: dispatch, human gates, heartbeat, merges), `planner` (specs and plans only), `build1` and `build2` (implementation in their own worktrees), `reviewer` (design and code review).
> - Every agent loads this file at startup; the orchestrator's first prompt names your role; read `docs/multi-agent-coordination.md` for that role's rules before taking work.
> - Message an agent with `herdr agent prompt <name> "<your role>: <text>"` and read its reply with `herdr agent read <name> --source recent-unwrapped --lines N`. Review rounds run directly between planner and reviewer with a one-line notice to the orchestrator at request and at verdict.
> - Route human gates through the orchestrator: send `<role>: blocked on human gate: <what>` to `orchestrator` and wait.
> - The orchestrator produces no repository artifacts, verifies claims through its own subagents rather than in its own context, and briefs agents with only the problem, the human's rulings, undiscoverable details, and how to report back.
> - After 30 quiet minutes with in-flight work, the orchestrator checks the agent's Herdr state, has a subagent collect recent output, commit age, dirty files, and CPU delta, then prompts the agent unless it is blocked.
> - Announce every wait for a gate, review, or dependency to the orchestrator when it begins.
> - A PR reported approved or merge-ready must already be ready for review and must not be a draft.
> - Never end with only promised future work; state exactly what remains, and use commit age, dirty files, and CPU delta as evidence, never message recency or Herdr's `agent_status`.

Acceptance for this section is concision and every link resolving, not a screen size.

## Change 2: `docs/multi-agent-coordination.md`

Replace the whole file with the text below. Section order mirrors the `AGENTS.md` bullets so each bullet has one runbook section. The "Announce Blockers", "Report Merge Readiness", and "End Turns" sections keep their current wording apart from the role renames.

````markdown
# Multi-Agent Coordination

The root `AGENTS.md` carries the common-case rules. This runbook contains the operational procedure, rationale, and diagnostics an agent needs to work in the Herdr fleet, and that the orchestrator needs when a gate is blocked or an agent goes quiet.

## The Fleet

The fleet is one Herdr workspace with one agent per tab. Herdr addresses each agent by a unique live name.

| Name | Runtime | Role |
|---|---|---|
| `orchestrator` | Claude | The human's eyes, ears, and proxy. Dispatches work, relays human decisions, owns the quiet-agent heartbeat, arbitrates planner-versus-reviewer disagreements, and merges after asking the human about that specific PR. Produces no repository artifacts: no code, docs, plans, commits, or PRs. Briefs, relays, memory notes, and terse issue or PR decisions are fine. |
| `planner` | Claude (fable) | Writes specs and plans. Does not implement. Runs review rounds directly with the reviewer. |
| `build1`, `build2` | Codex | Implement in their own worktree and branch with disjoint files. All simulator work goes through `scripts/xcode-stream.sh`. |
| `reviewer` | Codex | Adversarial design review before implementation (correctness, over-engineering, missing cases that matter in practice) and independent code review before every merge. |

The orchestrator verifies agent claims (PR diff, CI, grep results) by delegating to its own subagents or workflows, not by reading the material in its own context.

### Briefs

A brief from the orchestrator to any agent contains exactly four things:

1. A one-sentence problem statement.
2. The human's rulings that are not open for redesign.
3. Real details the agent cannot discover itself, such as a decision made in conversation or a result observed on a device.
4. How to report back.

A brief never contains method, model, effort, or workflow guidance. The agent's own skills and the project docs supply those. Project conventions and operational facts live in project docs, never in any agent's private memory; a convention that exists only in memory is a doc defect to fix, not a fact to relay in briefs.

## Fleet Startup

Every agent auto-loads `AGENTS.md` when it starts. The orchestrator's first prompt names the agent's role. The agent then reads this runbook for that role's rules before taking work.

A Codex agent shows a "Hooks need review" trust prompt on its first start after a Herdr integration install, and Herdr reads that prompt as `idle`; answer it by hand before the first prompt. Codex registers its session with Herdr only on its first turn, so a Codex pane that has never been prompted does not restore after a Herdr restart.

While the human is present, the orchestrator dispatches `scripts/warm-git-credentials.sh` to every implementation stream. Each stream runs it in its clean assigned feature worktree before taking implementation work. If signing or SSH approval expires mid-session, the orchestrator dispatches a rerun only while the human is present; see Development Workflow for the AFK commit fallback.

## Messaging

Send work or a reply to an agent by name. Start every message with your own role and a colon, so the recipient's transcript shows who said what:

```bash
herdr agent prompt build1 "orchestrator: implement docs/superpowers/specs/<file>.md in .worktrees/build1-<issue>" --wait --timeout 600000
```

Read what an agent wrote:

```bash
herdr agent read build1 --source recent-unwrapped --lines 120
```

Builders and the reviewer report to the orchestrator, and the orchestrator forwards to other agents as needed. The one exception is the review loop: the planner prompts `reviewer` directly with the path of the document or PR, sends `planner: review requested for <path>` to the orchestrator, and after the verdict sends `planner: review verdict: <n> blocking, <m> non-blocking`. If a planner-reviewer disagreement survives two rounds, the planner escalates it to the orchestrator. Other direct agent-to-agent messaging happens only when the orchestrator asks for it.

### Delivery and readback

`herdr agent prompt --wait` returns at the first settled `idle`, `done`, or `blocked` state. A settled `blocked` state is not completion. If the recipient was already `working`, the wait can be satisfied by the end of its earlier turn, so read its output before treating the wait as an answer to your prompt.

When a prompt fails or a wait ends without the reply you expected:

- `agent_blocked`: the recipient is waiting at an approval or question dialog. Read the dialog with `herdr agent read <name>`. Do not answer another agent's dialog without the human's say-so. Keep your report and resend it once the recipient is ready for input again, which is `idle` or `done`; `done` is idle work that nobody has viewed yet, and CLI reads do not clear it.
- `agent_prompt_stalled`: Herdr saw no lifecycle change within five seconds. Inspect `herdr agent get` and `herdr agent read` before resending; the recipient may have consumed the prompt without a visible state change. Do not duplicate work on the strength of a stalled prompt.
- A read that stays truncated as `--lines` grows: the agent is on the terminal's alternate screen, and rows that left it are not recoverable. Ask the agent to write its complete reply as Markdown in a temporary directory and reply with only the path, then read the file. Use this only as a fallback.

### Agent state

`herdr agent get <name>` reports `agent_status` from Herdr screen detection:

- `idle`: ready for input and its tab has been seen in the focused Herdr UI.
- `done`: the same idle state after background work finished while the tab was not being watched.
- `working`: Herdr detected a working indicator.
- `blocked`: Herdr recognized an approval or question dialog.
- `unknown`: an agent is present but Herdr cannot classify it. This does not prove completion.

None of these states is evidence of progress. `working` means Herdr detected a working state, not that the task advanced. `idle` does not prove a particular instruction ran. Evidence of work is commit age, dirty files, and CPU delta in the agent's worktree, read in context: a low CPU delta during a remote model request or a delegated build is inconclusive, and a read-only review produces no repository changes.

## Route Human Gates Through the Orchestrator

The human speaks through the orchestrator. When you need a human decision, announce the block to the orchestrator the moment it starts, then wait:

```bash
herdr agent prompt orchestrator "build2: blocked on human gate: approve deleting the stale CloudKit zone"
```

The orchestrator relays authority the human already supplied or obtains it. Never guess at the human's answer and never answer your own gate.

### How the orchestrator arbitrates

When the planner and the reviewer disagree, the orchestrator decides when one side rests on something checkable (code, an existing invariant, a reproduced result) and the other does not. It applies KISS, YAGNI, and the right-sizing rule with first-hand knowledge of the human's intent, because these disagreements are often gold-plating or unlikely edge cases.

The orchestrator escalates to the human when the disagreement is about preference, product behaviour, scope, or blast radius (release, user data, security, user-facing text), and always after two unresolved rounds.

## Heartbeat a Quiet Agent

If an agent with in-flight work has sent nothing for 30 minutes, the orchestrator runs this sequence:

1. Read the agent's state with `herdr agent get <name>`. If it is `blocked`, have a subagent read the dialog with `herdr agent read <name> --source recent-unwrapped --lines 60`, route it as a human gate, and stop here; a prompt to a blocked agent is rejected.
2. Otherwise dispatch one subagent to collect evidence: the agent's recent output (`herdr agent read <name> --source recent-unwrapped --lines 120`) to see whether the last instruction was consumed, commit age and dirty files in the agent's worktree, and two CPU samples using the recipe below.
3. Read the subagent's evidence and prompt the agent directly, asking for evidence of work or an explicit blocker.

Evidence collection is delegated because the orchestrator does not verify in its own context. Scheduling, gate triage, and the decision to prompt stay with the orchestrator.

### Measure CPU Delta

Resolve the agent's process through Herdr, not by matching process names or environment variables. Run the recipe from a worktree of this repository, twice, a short interval apart, and compare the `TIME` column.

```bash
test "${HERDR_ENV:-}" = 1 || { echo "run inside a Herdr pane" >&2; exit 1; }
for tool in herdr jq git ps; do command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required" >&2; exit 1; }; done
target=build1
repo_common=$(git rev-parse --path-format=absolute --git-common-dir) || exit $?
agent_json=$(herdr agent get "$target") || exit $?
pane_id=$(jq -er '.result.agent.pane_id' <<<"$agent_json") || exit $?
expected=$(jq -er '.result.agent.agent' <<<"$agent_json") || exit $?
agent_cwd=$(jq -er '.result.agent.cwd' <<<"$agent_json") || exit $?
agent_common=$(git -C "$agent_cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || { status=$?; echo "$target runs in $agent_cwd, which is not a Git worktree" >&2; exit "$status"; }
[ "$agent_common" = "$repo_common" ] \
  || { echo "$target runs in $agent_cwd, which belongs to $agent_common, not this repository" >&2; exit 1; }
process_json=$(herdr pane process-info --pane "$pane_id") || exit $?
agent_pid=$(jq -er --arg expected "$expected" \
  '.result.process_info.foreground_processes | select(length == 1) | .[0] | select(.name == $expected) | .pid' \
  <<<"$process_json") || { status=$?; echo "pane $pane_id is not running exactly one $expected process" >&2; exit "$status"; }
ps -o pid=,time= -p "$agent_pid"
# Repeat after a short interval and compare TIME; use this with commit age and dirty files.
```

The recipe fails closed and preserves the failing command's exit status; only its own checks (environment, tools, and the repository comparison) exit 1. A missing Herdr environment or tool, an unknown name, an agent whose working directory is not a worktree of this repository, a pane whose single foreground process is not the expected agent binary, or a malformed JSON field is a diagnostic, never a healthy sample. The worktree check compares Git common directories, so a same-named agent from another project in the same Herdr session is refused before any sample is taken.

## Announce Blockers When They Begin

An agent entering any wait for a gate, review, or dependency sends a status to the orchestrator immediately. Include the exact condition and what becomes possible after it clears. Do not stay silent until a later heartbeat discovers the wait.

For a human gate, use the required prefix. For other waits, keep the state equally explicit:

```text
reviewer: blocked on review gate: waiting for build1 to push the fix commit for PR #123
```

## Report Merge Readiness Literally

Before reporting a PR approved or merge-ready, verify that it is already ready for review and not a draft. Include the exact head and base, check state, and independent review decision in the handoff. The orchestrator performs the merge, and only after asking the human about that specific PR.

### Calibrate Operator-Document Sign-Off

New or restructured operator flows require blocking reviewer approval, an executable walkthrough where applicable, and a human final read of the text. A tiny delta does not make the human read the text: `tiny` means prose-only, with no new or changed flow step and no new command. The planner classifies the delta; the reviewer may escalate that classification to the full gates.

Tiny deltas still require reviewer approval and green checks. The orchestrator names the delta as tiny in its per-PR merge ask, so the human can refuse the merge or, cheaply, revert by a new signed commit after it.

## End Turns With the Exact Remainder

Never end a turn merely announcing future work. If work remains, name the concrete remaining gate or action so the orchestrator can re-prompt without reconstructing state:

```text
build1: exact remainder: receive the reviewer's exact-head approval, then send the merge-ready packet to the orchestrator.
```

Once no work remains, report the completed outcome instead of promising another action.
````

## Change 3: `docs/development-workflow.md`

Line 20 currently reads "At fleet/session startup, while the human is present, the planner dispatches this warm-up to every implementation stream." Replace "the planner" with "the orchestrator".

In the "Xcode Stream" paragraph that begins "Every simulator build, test, and screenshot process tree enters through", append one sentence after "later runs by the same owner reuse its registered UUID.":

> In this fleet, `--agent` is your Herdr agent name (`build1`, `build2`, or `reviewer`) and `--session` is always `collab`; it is the simulator gate's ownership label, not a Herdr session identifier.

## Change 4: `.gitignore`

No change; local leftovers still exist. The human ruled that `.agent-mail/` and `.amqrc` remain in the main checkout, so retain the entire ignore block to avoid untracked noise.

## Verification

1. Active guidance must contain no retired fleet terms. Run this on the branch and require zero output:

   ```bash
   rg -n -i 'amq|am_me|am_root|agentctl|tmux|user mailbox|`user`|notifier_live|inbox/new' AGENTS.md docs/development-workflow.md docs/multi-agent-coordination.md
   ```

   Files under `docs/superpowers/plans/` and `docs/superpowers/specs/`, including this document, are historical and are not checked. `.gitignore` is also excluded under the Change 4 ruling because the retained `.amqrc` entry intentionally matches.
2. Run the CPU-delta recipe verbatim four ways and paste the transcripts into the PR: against a live builder from a worktree of this repository (expect a pid and time), against a name that does not exist (expect `agent_not_found` and exit 1), from a throwaway `git init` directory outside this repository (expect the "belongs to ... not this repository" refusal and exit 1), and with `HERDR_ENV` unset (expect "run inside a Herdr pane" and exit 1). All four were run against the reviewed text of this document on September 6, 2026 and behaved as stated.
3. Run `herdr agent prompt` against a live builder with the role-prefixed message format and read the reply with `herdr agent read`, and paste both into the PR.
4. Confirm every link in `AGENTS.md` resolves.

## Process

1. The reviewer does adversarial design review of this document. Review rounds run directly between planner and reviewer, with a one-line notice to the orchestrator at request and at verdict.
2. The planner revises in this worktree.
3. A builder implements the changes, with Change 4 left unchanged per the human ruling, in one PR from its own worktree, with the walkthrough transcripts in the PR body.
4. The reviewer approves the PR. The orchestrator asks the human, then merges. This is a restructured operator flow, so the human's final read of the text applies.

## Resolved Questions

All six questions from the first revision were ruled on by the human and the orchestrator and are now listed under Decided facts. No open questions remain.
