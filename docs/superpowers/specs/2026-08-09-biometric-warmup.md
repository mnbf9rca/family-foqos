# Session Credential Warm-up Design (#363)

**Status:** Proposed
**Scope:** Session Credential Warm-up interface and subagent startup protocol; no application-code
changes
**Related:** #365 (move App Store Connect credentials to 1Password + direnv)

## Problem

This repository signs Git commits with 1Password's SSH signing agent and pushes to GitHub over
SSH. Either operation can request biometric approval. If the first request occurs when an agent
finishes unattended work, the agent stalls at the delivery boundary even though the code is
ready.

The planner needs a named **Session Credential Warm-up** that happens while the human is present.
It must exercise both independent Git credential paths without changing the assigned feature
branch or leaving a remote branch behind:

1. Create a signed, empty commit on a disposable local branch to exercise Git commit signing.
2. Perform an SSH `git push --dry-run` from that commit to exercise push authentication.

Recent observation—27 signed commits followed by one prompted push—shows that successful commit
signing does not prove that SSH push authentication is warm. It does not establish how either
cache is scoped or how long it remains valid.

## Constraints

- The planner sends the warm-up as the first instruction to every implementation subagent while
  the human is present. Real task work does not begin until every declared stage succeeds.
- At dispatch, the planner declares which credentials the session will need: Git commit signing,
  GitHub SSH push authentication, and either personal/biometric or service-account `op` access when
  the task reads 1Password secrets. The warm-up runs and reports every declared stage.
- The assigned worktree must be clean before warm-up. The procedure must restore its exact
  starting branch or detached `HEAD` and delete the disposable branch on success or failure.
- The disposable commit is always `git commit -S --allow-empty`; it is never merged, rebased, or
  copied into production history.
- Commit signing and SSH push authentication are separate gates and must be tested separately.
- The configured push URL must use SSH. An HTTPS dry run would not warm the required SSH path.
- Warm-up must not create or delete a remote branch. `git push --dry-run` is the default; an
  actual scratch push is reserved for a deliberate diagnostic with maintainer approval.
- The protocol must never disable signing, amend a commit, force-push, or expose private keys,
  tokens, credential output, or values read from 1Password.
- Cache scope and lifetime are **OPEN/UNVERIFIED**. The protocol cannot promise that approval
  lasts for the rest of a terminal, agent, task, or workday.
- If approval expires while the human is absent, the response must preserve repository policy:
  use an authorized server-side commit path when it fits, or wait for the operator. Do not evade
  the prompt.
- #365 may add a third 1Password path for App Store Connect secrets. Warming or replacing that
  path does not warm Git signing or GitHub SSH authentication.

## Options considered

### Option A: local scratch commit plus SSH push dry run

Create a uniquely named local scratch branch from the starting commit, make one signed empty
commit, and dry-run a push of that commit to a same-named remote ref. Restore the starting state
and delete the local scratch branch with an exit trap.

**Advantages**

- Exercises both credential paths without modifying a production branch.
- Does not leave a commit in production history or a branch on GitHub.
- Avoids evaluating server-side branch rules or creating unrelated audit events; those are outside
  credential warm-up and could reject a real scratch push for irrelevant reasons.
- Is safe to repeat per subagent and can be wrapped in a small auditable helper.
- A failure identifies which path—signing or push authentication—needs human action.

**Disadvantages**

- A push dry run exercises authentication and ref validation but not the server's final ref
  update. It cannot prove permission to complete every future push.
- The procedure temporarily changes the checked-out local branch and therefore needs reliable
  cleanup.
- Success is only a point-in-time signal; it does not establish cache expiry.

### Option B: push and delete a real remote scratch branch

Make the same signed scratch commit, push it to GitHub, then delete the remote ref and local
branch.

**Advantages**

- Exercises the complete remote write path, including authorization to update and delete a ref.
- More closely matches the eventual feature-branch push.

**Disadvantages**

- Creates externally visible repository state for every agent startup.
- Cleanup can fail after the push, leaving remote litter and an ambiguous ownership problem.
- Branch protection, audit events, automation, and notifications may trigger on a meaningless
  ref.
- It is unnecessary for the reported biometric stall, which occurs during authentication.

This is appropriate only as a maintainer-run diagnostic if dry-run behavior is shown not to
exercise the relevant prompt.

### Option C: signed local commit only, with GitHub API as the delivery path

Warm only commit signing. If local push later blocks, create the final commit with GitHub's
`createCommitOnBranch` mutation instead of pushing over SSH.

**Advantages**

- Has the smallest local warm-up surface.
- The GitHub API can create a server-side commit when the human is absent and the intended change
  is already represented accurately on the remote branch.

**Disadvantages**

- Does not warm or test SSH push authentication.
- The API is not a drop-in replacement for pushing arbitrary local commit graphs, multiple
  commits, tags, or non-text state.
- Makes normal delivery depend on a fallback that is unsuitable for many tasks.

`createCommitOnBranch` is valuable as a bounded fallback, not as a substitute for warming the
normal push path.

## Recommendation

**DECIDED:** adopt Option A. At planner initialization, every implementation subagent runs a
local scratch-branch procedure while the human is present. The planner records separate success
for the signed empty commit and the SSH push dry run before releasing real work.

### Session Credential Warm-up interface

**DECIDED:** **Session Credential Warm-up** is the exact cross-document interface name. It replaces
the informal “session-start unlock step” wording. #363 owns this interface; #365 and later
credential consumers declare their needs to it without depending on its implementation.

Inputs are planner-owned and declared at dispatch:

- the session/agent identity and clean assigned worktree;
- the required credential stages: `git-signing`, `git-ssh-push`, and, when applicable,
  `op-personal` or `op-service-account`;
- the SSH push remote; and
- for service-account mode, an operator-approved secret-store injection source or launcher—not the
  token value in a task message, command argument, repository file, or log.

**OPEN-FOR-MAINTAINER:** select the operator-approved injection source or launcher if #365's
service-account mode is adopted.

The interface warms and reports these stages independently:

1. `git-signing`: create and verify the signed disposable commit.
2. `git-ssh-push`: authenticate an SSH push dry run without creating a remote ref.
3. `op-personal`: when the declared 1Password mode is biometric, execute a no-output `op read`
   probe for a permitted non-secret fact or discard the secret value before logging. A successful
   Git stage says nothing about this stage.
4. `op-service-account`: when service-account mode is declared, this step is the boundary where
   `OP_SERVICE_ACCOUNT_TOKEN` enters the worker environment from the operator-approved injector.
   The step owns redacting output, never echoing or persisting the token, and validating access with
   a no-output probe. It does not manufacture or retrieve the token through repository code.

The output is one passed/failed/not-run result and UTC completion time per declared stage, with no
credential values. Real work starts only when every required stage passes. The expiry policy below
is part of the interface: any later prompt or authentication failure expires that individual
stage, and the planner applies the human-present retry or human-absent fallback without inferring
that the other stages share cache state.

The proposed helper performs the equivalent of the following. A repository script should encode
this flow before the AGENTS.md rule is landed; the literal shell is included to make state and
cleanup semantics reviewable.

```bash
set -euo pipefail

if test -n "$(git status --porcelain)"; then
  echo "Biometric warm-up requires a clean worktree" >&2
  exit 1
fi

starting_head="$(git rev-parse HEAD)"
starting_branch="$(git symbolic-ref --quiet --short HEAD || true)"
agent_label="$(printf '%s' "${AM_ME:-agent}" | tr -c 'A-Za-z0-9._-' '-')"
scratch_branch="scratch/biometric-warmup/${agent_label}-$(date -u +%Y%m%dT%H%M%SZ)-$$"

cleanup_warmup() {
  if test -n "${starting_branch}"; then
    git switch "${starting_branch}" >/dev/null 2>&1 || true
  else
    git switch --detach "${starting_head}" >/dev/null 2>&1 || true
  fi
  git branch -D "${scratch_branch}" >/dev/null 2>&1 || true
}

verify_warmup_cleanup() {
  test "$(git rev-parse HEAD)" = "${starting_head}" || return 1
  if test -n "${starting_branch}"; then
    test "$(git symbolic-ref --quiet --short HEAD)" = "${starting_branch}" || return 1
  else
    test -z "$(git symbolic-ref --quiet --short HEAD || true)" || return 1
  fi
  test -z "$(git status --porcelain)" || return 1
  ! git show-ref --verify --quiet "refs/heads/${scratch_branch}"
}
trap cleanup_warmup EXIT

handle_warmup_signal() {
  exit_code="$1"
  trap - EXIT HUP INT TERM
  cleanup_warmup
  exit "${exit_code}"
}
trap 'handle_warmup_signal 129' HUP
trap 'handle_warmup_signal 130' INT
trap 'handle_warmup_signal 143' TERM

push_url="$(git remote get-url --push origin)"
case "${push_url}" in
  git@*|ssh://*) ;;
  *)
    echo "origin push URL is not SSH; refusing an irrelevant warm-up" >&2
    exit 1
    ;;
esac

git switch -c "${scratch_branch}" "${starting_head}"

signing_status="failed"
signing_exit=0
signature_result="N"
if git commit -S --allow-empty -m "chore: biometric warm-up (discard)"; then
  if signature_result="$(git log -1 --format=%G?)"; then
    case "${signature_result}" in
      G|U) signing_status="passed" ;;
      *) signing_exit=1 ;;
    esac
  else
    signing_exit=$?
  fi
else
  signing_exit=$?
fi
signing_completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'stage=git-signing status=%s exit=%s signature=%s completed_at=%s\n' \
  "${signing_status}" "${signing_exit}" "${signature_result}" "${signing_completed_at}"

push_status="not-run"
push_exit=0
if test "${signing_status}" = "passed"; then
  if git push --dry-run origin "HEAD:refs/heads/${scratch_branch}"; then
    push_status="passed"
  else
    push_exit=$?
    push_status="failed"
  fi
fi
push_completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'stage=git-ssh-push status=%s exit=%s completed_at=%s\n' \
  "${push_status}" "${push_exit}" "${push_completed_at}"

if test "${signing_status}" != "passed" || test "${push_status}" != "passed"; then
  exit 1
fi

cleanup_warmup
if ! verify_warmup_cleanup; then
  echo "stage=cleanup status=failed; operator inspection required" >&2
  exit 1
fi
trap - EXIT HUP INT TERM
```

The helper reports signing and push separately even when signing fails; in that case push is
reported as `not-run`, and the helper exits nonzero only after both outcomes are emitted. A
successful commit is accepted only when Git reports a good (`G`) or good-with-unknown-trust (`U`)
signature. Its cleanup trap is best-effort so it does not hide the original failure; explicit
`HUP`, `INT`, and `TERM` handlers restore state and preserve conventional signal exit codes. After
any nonzero exit, the planner verifies the starting branch/`HEAD`, a clean status, and absence of
the scratch branch before retrying or assigning work. Scratch names include the agent label, UTC
time, and process ID to avoid collisions.

### Cache scope and lifetime

**OPEN/UNVERIFIED:** it is not yet known whether 1Password approval is cached per operation,
key, agent process, terminal, Codex subagent, macOS login session, or time window. The observation
of 27 successful signed commits and one prompted push is consistent with several of those models.
It proves only that signing and pushing can have different approval state.

Run a timestamped experiment before choosing an expiry interval:

1. Record UTC time, agent identity, terminal identity, process context, and whether the screen was
   locked. Do not record credential material.
2. With the human present, run every planner-declared Session Credential Warm-up stage and record
   prompt/no-prompt independently for Git signing, SSH push, and personal `op` access when used.
3. Repeat disposable signed commits, SSH push dry runs, and the no-output personal `op` probe after
   5, 15, 30, and 60 minutes from the same agent and terminal.
4. At the same offsets, test a fresh subagent and fresh terminal without deliberately approving
   another prompt first.
5. Repeat one controlled sequence across screen lock/unlock if the maintainer is comfortable doing
   so.
6. Publish only timings and prompt outcomes. Use the shortest reproducible expiry boundary when
   setting any future refresh interval.

Until that experiment establishes a safe bound, valid assertions are per-stage and timestamped,
for example: “Git signing succeeded at `<UTC time>`; SSH push authentication succeeded at `<UTC
time>`; personal `op` access succeeded at `<UTC time>`.” If an operation prompts or fails later,
that stage's warm state has expired regardless of elapsed time.

### Expiry policy and fallbacks

The expiry response is deliberately conservative because this policy is load-bearing:

| Situation | Required action | Why |
|---|---|---|
| Planner startup; human present | Run every declared warm-up stage per subagent | Establishes a point-in-time baseline for each agent |
| Any stage expires; human present | Repeat the expired stage and update its timestamp | Avoids inferring shared cache state |
| Human absent; final change can be represented as one server-side commit | Use GitHub `createCommitOnBranch` through the authorized connector | Complements local Git without bypassing signing or SSH settings |
| Human absent; local commits or push topology must be preserved | Stop at an operator gate and wait | API commit creation cannot faithfully replace the required push |
| Warm-up cleanup cannot restore the starting state | Stop and report exact branch, `HEAD`, and status | Real work must not begin in an ambiguous scratch state |

The GitHub API fallback must not be used to rewrite history, force an update, conceal unsigned
local commits, or approximate a multi-commit result. It is suitable when the remote branch and
expected head are known and one server-side commit accurately represents the intended delivery.

### Relationship to #365 and `op` authentication

#365 consumes the **Session Credential Warm-up** interface and decides the App Store Connect secret
path independently:

| #365 choice | App Store Connect warm-up | Git signing warm-up | SSH push warm-up | Tradeoff |
|---|---|---|---|---|
| Interactive user account with `op read` | Run a no-output probe while the human is present; discard the value | Still required | Still required | Preserves user-scoped vault access but adds a third biometric/cache dependency |
| 1Password service account token | Validate non-interactive `op` access without printing values | Still required | Still required | Removes the `op` biometric dependency, but introduces token storage, scope, and rotation duties |

If #365 keeps interactive `op read`, its startup probe must redirect the secret value away from
logs and use only the command exit status. A service account changes only 1Password CLI
authentication. It does not unlock the 1Password SSH agent for commit signing or GitHub pushes.
Retaining a standing plaintext `~/.appstoreconnect` key is #365's rejected Option C, not a supported
Session Credential Warm-up mode.

## Exact AGENTS.md diff

After the warm-up helper exists and has been manually validated, add the following literal text
under the repository's key rules:

```markdown
  - **RUN THE SESSION CREDENTIAL WARM-UP BEFORE DELEGATING IMPLEMENTATION.** While the human is
    present, the planner declares which credentials each implementation subagent will need and
    makes the Session Credential Warm-up its first instruction. Required stages are Git commit
    signing, GitHub SSH push authentication, and either personal/biometric or service-account `op`
    access when the task reads 1Password. The Git helper runs in the clean assigned worktree: it
    creates and verifies a signed `--allow-empty` commit on a unique local scratch branch, verifies
    an SSH `git push --dry-run`, reports both outcomes, restores the exact starting branch or
    detached `HEAD`, and deletes the scratch branch. The disposable commit must never be merged or
    pushed. In personal mode, warm `op` with a no-output probe. In service-account mode, this step
    is where the operator-approved injector places `OP_SERVICE_ACCOUNT_TOKEN` in the environment;
    never log, echo, persist, or put that token in a task message or command argument. Real work
    starts only after every declared stage passes and the planner records per-stage UTC times. This
    is point-in-time evidence, not a guarantee that approval lasts for the session. If a stage
    expires, repeat it while the human is present. If the human is absent, use an authorized GitHub
    server-side commit only when it exactly represents the intended single-commit change; otherwise
    stop at an operator gate. Never disable signing, amend, force-push, expose credentials, or leave
    the worktree on a scratch ref to bypass a biometric prompt.
```

The final documentation should replace the conceptual Git helper wording with its checked-in path
when the helper is implemented. Landing the mandate and the helper together avoids directing agents
to a command that does not exist.

## Rollout

1. Implement the Session Credential Warm-up coordinator and small Git helper that follow the
   recommended flow, emit separate stage results/timestamps, and never print credential material.
   Review them before changing AGENTS.md.
2. Test cleanup without network or Xcode: successful run, signing failure with push reported
   `not-run`, invalid signature state, non-SSH origin, dry-run failure, starting detached `HEAD`, and
   injected `HUP`, `INT`, and `TERM` after scratch-branch creation.
3. With the maintainer present, run it in two clean disposable worktrees and confirm each returns
   to the starting branch/commit with clean status and no local scratch branch.
4. Confirm `git ls-remote --heads origin 'scratch/biometric-warmup/*'` finds no remote branch after
   the dry-run validation.
5. Run the timestamped cache experiment above. Record signing, push, and personal `op` outcomes
   separately and keep cache lifetime marked unverified until the results are reproducible.
6. Coordinate with #365 using the exact **Session Credential Warm-up** interface name. Choose
   interactive `op` versus a scoped service account, test redacted token injection/no-logging when
   applicable, and retain the two Git warm-up stages in either case.
7. Land the exact AGENTS.md addition with the validated helper. Train planners to send it before
   implementation instructions and to preserve the warm-up timestamp in task status.
8. Audit the first week of tasks for leftover scratch refs, blocked end-of-task pushes, and cache
   expiry. Any failure returns the workflow to explicit operator gates until its cause is known.
