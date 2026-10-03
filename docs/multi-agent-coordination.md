# Multi-Agent Coordination

This runbook expands `AGENTS.md` with fleet procedures, gates, and diagnostics.

## The Fleet

Use one Herdr workspace, one agent per tab, and unique live names.

| Name | Runtime | Role |
|---|---|---|
| `orchestrator` | Claude | Dispatch, human gates, heartbeat, arbitration, and merges under the sign-off policy below. No repository artifacts except updating PR branches from main; no implementation/release work delegated to its subagents. Briefs, relays, memory notes, and terse issue/PR decisions are allowed. |
| `planner` | Codex (gpt-6-astra, high reasoning) | Writes specs and plans. Does not implement. Runs review rounds directly with the reviewer. |
| `build1`, `build2` | Codex (gpt-6.1-sol, high reasoning) | Implement in their own worktree and branch with disjoint files. All simulator work goes through `scripts/xcode-stream.sh`. |
| `reviewer` | Claude (Opus 5.5, high effort) | Adversarial design review before implementation (correctness, over-engineering, missing cases that matter in practice) and independent code review before every merge. |
| `auditor` | Codex (gpt-6-astra, high reasoning) | Read-only systematic audits and coverage checks of plans against findings and human rulings. Produces no repository artifacts; reports findings to the orchestrator for recording on the relevant issue. |

The reviewer uses a different model from the planner and builders.

The orchestrator delegates claim verification to its subagents or workflows, never its own context.

Review from your own working copy or read-only SHA commands; check another worktree’s dirt with `git --no-optional-locks -C <worktree> status --porcelain`. Never change another agent’s HEAD, branch, or files, or adopt its working directory.

### Briefs

A brief contains exactly four items: the problem in one sentence, fixed human rulings, undiscoverable details, and how to report back. Exclude method, model, effort, and workflow guidance; skills and project docs supply those. Project conventions belong in docs, never private agent memory; a memory-only convention is a doc defect.

## Fleet Startup

Every agent auto-loads `AGENTS.md`; the orchestrator names its role in the first prompt.

```text
orchestrator: you are <role>. Before taking work: read docs/multi-agent-coordination.md for the <role> rules, and load these skills: <skills for the role>. Reply with one line naming what you loaded, your role, and "exact remainder: none". Take no work until a brief arrives.
```

Reset agents only between unrelated work items; only the human resets the orchestrator. First record context-only findings/state on the relevant issue, then:

1. Record pane id and name from `herdr agent list`; shared cwd cannot identify a nameless agent.
2. Send `herdr agent prompt <pane> /new` for Codex or `/clear` for Claude; bare reset commands need no role prefix.
3. For Codex, read `herdr agent read <pane> --source visible`. At "Where should the new conversation run?", select "Current checkout" with `herdr agent send-keys <pane> up`/`down`, then `enter`. Only this reset dialog is pre-authorized; other dialogs require human authority.
4. Re-apply the name with `herdr agent rename <pane> <name>` after session re-registration.
5. Send the startup template to the pane id, naming the role again; re-check its name after the first turn.

- planner: herdr, communicating-clearly, writing-clearly, ponytail.
- build1/build2: herdr, ponytail.
- reviewer: herdr, communicating-clearly, writing-clearly, ponytail, ponytail-review.
- auditor: herdr, communicating-clearly, writing-clearly, ponytail.

Read a missing skill’s `SKILL.md` directly.

Take no unnamed gate, review, or confirmation step.

After Herdr integration installation, answer Codex’s "Hooks need review" trust dialog by hand before prompting; Herdr reports it as `idle`. Codex registers on its first turn; unprompted panes do not restore after Herdr restarts.

If `herdr agent start` returns `agent_pane_busy`, retry when shell startup finishes.

Codex re-registration can drop names. Before prompting, and after each first turn or `/new`, the orchestrator checks `herdr agent list` and restores missing names with `herdr agent rename <pane> <name>`. Others report unknown names to the orchestrator; do not rename panes themselves.

Credential warm-up, expiry, and AFK fallback follow [Development Workflow](development-workflow.md#warm-git-credentials).

## Messaging

Send `herdr agent prompt <name> "<your role>: <text>"`; read `herdr agent read <name> --source recent-unwrapped --lines N`. Prefix every message with your role and a colon.

Builders, reviewer, and auditor report through the orchestrator. Exception: planner prompts reviewer directly with the document/PR path and notifies the orchestrator at request and verdict, including blocking/non-blocking counts. The planner escalates to the orchestrator after two unresolved rounds; other direct messaging requires orchestrator instruction.

### Delivery and readback

The orchestrator never blocks its turn on `herdr agent prompt --wait` or `herdr agent wait`; send without waiting or wait in a background job. Other agents may wait.

`prompt --wait` returns at the first settled `idle`, `done`, or `blocked`; blocked is not complete. An already-working recipient may settle its earlier turn; read the reply before attributing completion to your prompt.

When a prompt fails or a wait ends without the reply you expected:

- `agent_blocked`: read the dialog; never answer without human authority. Retain and resend your report once `idle`/`done`; CLI reads do not clear `done`.
- `agent_prompt_stalled`: no lifecycle change within five seconds; inspect `herdr agent get` and `read` before resending, since the prompt may have been consumed.
- Persistent truncation as `--lines` grows: alternate-screen rows may be lost. Only then request the complete reply in a temporary Markdown file and read the returned path.

### Agent state

`herdr agent get <name>` reports screen state: `idle` is ready and viewed, `done` is ready after unwatched work, `working` shows a work indicator, `blocked` shows a dialog, and `unknown` is unclassified. These states and message recency prove neither progress nor instruction completion. Use commit age, dirty files, and CPU delta in context; low CPU during remote requests/delegated builds is inconclusive, and read-only reviews produce no edits.

## Route Human Gates Through the Orchestrator

Announce `"<role>: blocked on human gate: <decision>"` to the orchestrator immediately and wait; it relays existing authority or obtains it. Never guess the answer or answer your own gate. The orchestrator batches human questions in plain words, with concrete examples and recommendations, omitting internal IDs. When the human delegates approval to an agent, act on that agent’s verdict without re-escalating. Delegated approval covers only its named scope; PR merge authority requires that specific PR, except docs under the policy below. Record every human ruling on the relevant issue when made. For blocked credits, credentials, or tooling, present options to the human; do not assign implementation to orchestrator subagents.

### How the orchestrator arbitrates

Existing behavior in a spec is deliberate only when backed by a recorded human ruling; every agent must check.

The orchestrator resolves disagreements when one side has checkable evidence and the other does not, applying KISS, YAGNI, right-sizing, and the human’s intent.

Escalate preference, product behavior, scope, release, user data, security, or user-facing text to the human, and always after two unresolved rounds.

## Heartbeat a Quiet Agent

If an agent with in-flight work has sent nothing for 30 minutes, the orchestrator runs this sequence:

1. Read the agent's state with `herdr agent get <name>`. If it is `blocked`, have a subagent read the dialog with `herdr agent read <name> --source recent-unwrapped --lines 60`, route it as a human gate, and stop here; a prompt to a blocked agent is rejected.
2. Otherwise dispatch one subagent to collect evidence: the agent's recent output (`herdr agent read <name> --source recent-unwrapped --lines 120`) to see whether the last instruction was consumed, commit age and dirty files in the agent's worktree, and two CPU samples using the recipe below.
3. Read the subagent's evidence and prompt the agent directly, asking for evidence of work or an explicit blocker.

The orchestrator retains scheduling, gate triage, and the prompt decision; evidence collection is delegated.

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

The recipe preserves child failures and exits 1 for its own checks. Missing tools/environment, malformed fields, wrong repository, or a pane without exactly the expected foreground agent are diagnostics, never healthy samples; Git common-directory comparison rejects same-named agents from other projects.

## Announce Blockers When They Begin

Immediately report every gate, review, or dependency wait to the orchestrator, naming the exact condition and what clearing it enables; use the required human-gate prefix. Do not wait for a heartbeat.

## Investigate Unexplained Behavior

For unexplained hangs, errors, or platform behavior, research online early (Apple docs/forums, GitHub issues, Stack Overflow) before deep local digging or improbable theories. Report links alongside local evidence, per the [human ruling](https://github.com/mnbf9rca/family-foqos/issues/507#issuecomment-5973667912).

## Report Merge Readiness Literally

Specs and multi-slice plans land in implementation PRs, never separate docs PRs; builders branch from the approved spec/plan head. Shared-file slices may stack sequentially within one owning stream, updated by signed merge commits pushed normally, never rebase or force. After a parent is squash-merged, merge main into the child and let GitHub retarget its base; the diff-comparison rule below determines renewed review. Concurrent streams still reserve disjoint files. See the [recorded ruling](https://github.com/mnbf9rca/family-foqos/issues/507#issuecomment-5973689700).

Report approval/readiness only for a non-draft PR; include exact head/base, checks, and independent review. The orchestrator merges: docs follow the policy below; other PRs require specific human approval.

For an up-to-date-branch requirement, the orchestrator may merge main into the PR branch through GitHub. Retain review only if the new diff against main equals the approved diff against its base and new-head checks are green; otherwise obtain fresh review. Notify the owner to fetch and fast-forward or merge before pushing again. Specific human approval still applies except for docs.

Only the human approves a fork PR's workflow run; agents never approve it. Version bumps for a fork PR go onto the fork branch through maintainer edits, preserving the contributor's commits.

Label source PRs `greptile-review` once, after reviewer findings are addressed and the author considers the PR merge-ready; each re-review is paid. Never label spec-only, docs-only, version-only, or small follow-up PRs.

Greptile’s summary is in the PR description (`gh pr view N --json body`); its `Greptile Review` check reports completion, not cleared findings. Judge summary findings/confidence and unresolved inline threads separately. After every push to an already-labelled PR, the pushing agent immediately comments `@greptileai re-review`, including orchestrator updates from main, per the [new ruling](https://github.com/mnbf9rca/family-foqos/issues/507#issuecomment-5970570092). If the latest head still lacks a review after about 30 minutes (including unanswered initial-label or re-review requests), the orchestrator may post the same command under the [fallback ruling](https://github.com/mnbf9rca/family-foqos/issues/507#issuecomment-5969255530). The portal retrigger needs human login; do not remove and re-add the label.

Keep PR prose lean: one short description with concise test evidence, updated in place, and one reviewer verdict comment per head. Send progress, handovers, and long evidence directly to the orchestrator. Tool/agent interfaces remain available, including re-review commands and review-thread replies. Record durable evidence once, briefly, on the relevant issue.

### Calibrate Operator-Document Sign-Off

The human does no final read of operator/process docs, including new or restructured flows; reviewer approval and green checks authorize orchestrator merge under the [human ruling](https://github.com/mnbf9rca/family-foqos/issues/507#issuecomment-5969279559).

## End Turns With the Exact Remainder

Name the exact remaining gate/action when work remains; never end with only promised future work. Otherwise report the completed outcome.
