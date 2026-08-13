# Multi-Agent Coordination

The root `AGENTS.md` carries the six common-case rules. This runbook contains the operational
procedure, rationale, and diagnostics a planner needs when a gate is blocked or an agent goes
quiet.

## Route Human Gates Through the Planner

The maintainer speaks through the planner session. Never post a real `gate/*` approval request to
the AMQ `user` mailbox and wait. On the agent's normal planner thread, announce the block when it
starts:

```text
blocked on human gate: <what>
```

The planner relays authority already supplied by the maintainer or obtains it. A user-mailbox sweep
is part of every quiet-agent heartbeat because a parked request may otherwise remain unread even
after the same decision is resolved through the planner.

## Heartbeat a Quiet Agent

If an agent with in-flight work has sent no message for 30 minutes, the planner performs all five
steps in order:

1. Drain the planner inbox.
2. Inspect the target agent's `inbox/new` to determine whether instructions were consumed.
3. Sweep the AMQ `user` mailbox for parked gates.
4. Inspect commit age, dirty files, and CPU delta as work evidence.
5. Ping the agent directly.

`notifier_live` is only wake-process evidence. Message recency and presence flags do not prove that
the agent is working. A heartbeat combines repository state with CPU delta, and its ping asks the
agent to report either evidence of work or an explicit blocker.

### Measure CPU Delta

Use the ownership path that actually launched the target agent and sample its cumulative CPU time
twice. Never borrow a fleet session from another project merely because it contains the same role
name; that process is not this project's agent.

For an `agentctl`-managed agent, resolve the role's tmux pane through that project's managed fleet.
Set `target_role` to the quiet agent and `fleet_session` to the session that owns it:

```bash
fleet_session="${AGENTCTL_SESSION:?set the managed fleet session}"
target_role=build1
status_json=$(agentctl status --session "$fleet_session" --json)
pane_id=$(jq -r --arg role "$target_role" \
  '.agents[] | select(.role == $role) | .pane_id' <<<"$status_json")
[ -n "$pane_id" ] || { echo "no pane for role $target_role" >&2; exit 1; }
pane_pid=$(tmux display-message -p -t "$pane_id" '#{pane_pid}')
ps -o pid=,time= -p "$pane_pid"
# Repeat after a short interval and compare TIME; use this with commit age and dirty files.
```

For an agent not managed by `agentctl`, match its main executable, `AM_ME` role, and this project's
exact `AM_ROOT`. Descendants inherit the AMQ environment, so set `agent_executable` to the main
process (`codex` or `claude`) rather than matching every inherited process:

```bash
target_role=build1
agent_executable=codex
project_am_root="${AM_ROOT:?run inside the project AMQ session}"
ps eww -axo pid=,time=,comm=,command= | awk \
  -v executable="$agent_executable" \
  -v target="$target_role" \
  -v role="AM_ME=$target_role" \
  -v root="AM_ROOT=$project_am_root" '
    {
      executable_name = $3
      sub(/^.*\//, "", executable_name)
      if (executable_name != executable) next
      has_role = has_root = 0
      for (field = 4; field <= NF; field++) {
        if ($field == role) has_role = 1
        if ($field == root) has_root = 1
      }
      if (has_role && has_root) {
        count++
        agent_pid = $1
        agent_time = $2
      }
    }
    END {
      if (count != 1) {
        printf "expected exactly one %s agent process for role %s under %s; found %d\n", \
          executable, target, root, count > "/dev/stderr"
        exit 1
      }
      print agent_pid, agent_time
    }'
# Repeat after a short interval and compare TIME; use this with commit age and dirty files.
```

Both paths fail closed: an unknown role, wrong executable, wrong project root, missing fleet, or
ambiguous process count is a diagnostic, never a healthy sample.

## Announce Blockers When They Begin

An agent entering any wait for a gate, review, or dependency sends a status immediately. Include
the exact condition and what becomes possible after it clears. Do not stay silent until a later
heartbeat discovers the wait.

For a human gate, use the required prefix. For other waits, keep the state equally explicit:

```text
blocked on review gate: independent exact-head review is pending
```

## Report Merge Readiness Literally

Before reporting a PR approved or merge-ready, verify that it is already ready for review and not a
draft. Include the exact head/base, check state, and independent review decision in the handoff.
Only the role authorized by the current workflow performs the merge.

### Calibrate Operator-Document Sign-Off

New or restructured operator flows require blocking reviewer approval, an executable walkthrough
where applicable, and a maintainer final read. A tiny delta does not make the maintainer a blocking
gate: `tiny` means prose-only, with no new or changed flow step and no new command. The planner
classifies the delta; the reviewer may escalate that classification to the full gates.

Tiny deltas still require reviewer approval, green checks, and planner merge. Name the delta in the
planner's next maintainer-facing report. That notice, plus a cheap revert by new commit, provides a
retroactive veto; there is no wall-clock veto window.

## End Turns With the Exact Remainder

Never end a turn merely announcing future work. If work remains, name the concrete remaining gate
or action so the planner can re-prompt without reconstructing state:

```text
Exact remainder: receive maintainer final-diff sign-off, then send the merge-ready packet to the planner.
```

Once no work remains, report the completed outcome instead of promising another action.
