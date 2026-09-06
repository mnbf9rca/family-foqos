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
