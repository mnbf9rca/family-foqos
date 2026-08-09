# Biometric Credential Warm-Up Design (#363)

**Status:** Proposed
**Scope:** Planner and subagent startup protocol; no application-code changes
**Related:** #365 (move App Store Connect credentials to 1Password + direnv)

## Problem

This repository signs Git commits with 1Password's SSH signing agent and pushes to GitHub over
SSH. Either operation can request biometric approval. If the first request occurs when an agent
finishes unattended work, the agent stalls at the delivery boundary even though the code is
ready.

The planner needs a startup warm-up that happens while the human is present. It must exercise
both independent credential paths without changing the assigned feature branch or leaving a
remote branch behind:

1. Create a signed, empty commit on a disposable local branch to exercise Git commit signing.
2. Perform an SSH `git push --dry-run` from that commit to exercise push authentication.

Recent observation—27 signed commits followed by one prompted push—shows that successful commit
signing does not prove that SSH push authentication is warm. It does not establish how either
cache is scoped or how long it remains valid.

## Constraints

- The planner sends the warm-up as the first instruction to every implementation subagent while
  the human is present. Real task work does not begin until both checks succeed.
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
trap cleanup_warmup EXIT

push_url="$(git remote get-url --push origin)"
case "${push_url}" in
  git@*|ssh://*) ;;
  *)
    echo "origin push URL is not SSH; refusing an irrelevant warm-up" >&2
    exit 1
    ;;
esac

git switch -c "${scratch_branch}" "${starting_head}"
git commit -S --allow-empty -m "chore: biometric warm-up (discard)"
git push --dry-run origin "HEAD:refs/heads/${scratch_branch}"

cleanup_warmup
trap - EXIT
```

The helper must report the signing and push stages separately. Its cleanup trap is best-effort so
it does not hide the original failure; after any nonzero exit, the planner verifies the starting
branch/`HEAD`, a clean status, and absence of the scratch branch before retrying or assigning
work. Scratch names include the agent label, UTC time, and process ID to avoid collisions.

### Cache scope and lifetime

**OPEN/UNVERIFIED:** it is not yet known whether 1Password approval is cached per operation,
key, agent process, terminal, Codex subagent, macOS login session, or time window. The observation
of 27 successful signed commits and one prompted push is consistent with several of those models.
It proves only that signing and pushing can have different approval state.

Run a timestamped experiment before choosing an expiry interval:

1. Record UTC time, agent identity, terminal identity, process context, and whether the screen was
   locked. Do not record credential material.
2. With the human present, run the recommended signing and push warm-up and record prompt/no-prompt
   independently for each stage.
3. Repeat disposable signed commits and SSH push dry runs after 5, 15, 30, and 60 minutes from the
   same agent and terminal.
4. At the same offsets, test a fresh subagent and fresh terminal without deliberately approving
   another prompt first.
5. Repeat one controlled sequence across screen lock/unlock if the maintainer is comfortable doing
   so.
6. Publish only timings and prompt outcomes. Use the shortest reproducible expiry boundary when
   setting any future refresh interval.

Until that experiment establishes a safe bound, the only valid warm-up assertion is timestamped:
“signing and SSH push authentication succeeded at `<UTC time>`.” If either operation prompts or
fails later, its warm state has expired regardless of elapsed time.

### Expiry policy and fallbacks

The expiry response is deliberately conservative because this policy is load-bearing:

| Situation | Required action | Why |
|---|---|---|
| Planner startup; human present | Run both warm-up stages per subagent | Establishes a point-in-time baseline for each agent |
| Either stage expires; human present | Repeat the full warm-up and update its timestamp | Avoids inferring shared cache state |
| Human absent; final change can be represented as one server-side commit | Use GitHub `createCommitOnBranch` through the authorized connector | Complements local Git without bypassing signing or SSH settings |
| Human absent; local commits or push topology must be preserved | Stop at an operator gate and wait | API commit creation cannot faithfully replace the required push |
| Warm-up cleanup cannot restore the starting state | Stop and report exact branch, `HEAD`, and status | Real work must not begin in an ambiguous scratch state |

The GitHub API fallback must not be used to rewrite history, force an update, conceal unsigned
local commits, or approximate a multi-commit result. It is suitable when the remote branch and
expected head are known and one server-side commit accurately represents the intended delivery.

### Relationship to #365 and `op` authentication

#365 should decide the App Store Connect secret path independently:

| #365 choice | App Store Connect warm-up | Git signing warm-up | SSH push warm-up | Tradeoff |
|---|---|---|---|---|
| Interactive user account with `op read` | Run a no-output probe while the human is present; discard the value | Still required | Still required | Preserves user-scoped vault access but adds a third biometric/cache dependency |
| 1Password service account token | Validate non-interactive `op` access without printing values | Still required | Still required | Removes the `op` biometric dependency, but introduces token storage, scope, and rotation duties |
| Plaintext `~/.appstoreconnect` retained | None | Still required | Still required | Avoids an `op` prompt but leaves the plaintext-secret risk #365 is intended to remove |

If #365 keeps interactive `op read`, its startup probe must redirect the secret value away from
logs and use only the command exit status. A service account changes only 1Password CLI
authentication. It does not unlock the 1Password SSH agent for commit signing or GitHub pushes.

## Exact AGENTS.md diff

After the warm-up helper exists and has been manually validated, add the following literal text
under the repository's key rules:

```diff
+  - **WARM BIOMETRIC GIT CREDENTIALS BEFORE DELEGATING IMPLEMENTATION.** While the human is
+    present, the planner's first instruction to every implementation subagent must be to run the
+    repository biometric warm-up helper in its clean assigned worktree. The helper creates a
+    signed `--allow-empty` commit on a uniquely named local scratch branch, verifies an SSH
+    `git push --dry-run`, restores the exact starting branch or detached `HEAD`, and deletes the
+    scratch branch. The disposable commit must never be merged or pushed. Commit signing and SSH
+    push authentication are separate checks; real task work starts only after both succeed and
+    the planner records the UTC completion time. A successful warm-up is point-in-time evidence,
+    not a guarantee that approval lasts for the session. If either check expires, repeat it while
+    the human is present. If the human is absent, use an authorized GitHub server-side commit only
+    when it exactly represents the intended single-commit change; otherwise stop at an operator
+    gate. Never disable signing, amend, force-push, expose credentials, or leave the worktree on a
+    scratch ref to bypass a biometric prompt.
```

The final documentation should replace “repository biometric warm-up helper” with its checked-in
path when the helper is implemented. Landing the mandate and the helper together avoids directing
agents to a command that does not exist.

## Rollout

1. Implement a small repository helper that follows the recommended flow, emits separate stage
   results, and never prints credential material. Review it before changing AGENTS.md.
2. Test cleanup without network or Xcode: successful run, signing failure, non-SSH origin, dry-run
   failure, starting detached `HEAD`, and an injected interruption after scratch-branch creation.
3. With the maintainer present, run it in two clean disposable worktrees and confirm each returns
   to the starting branch/commit with clean status and no local scratch branch.
4. Confirm `git ls-remote --heads origin 'scratch/biometric-warmup/*'` finds no remote branch after
   the dry-run validation.
5. Run the timestamped cache experiment above. Record signing and push outcomes separately and
   keep cache lifetime marked unverified until the results are reproducible.
6. Coordinate with #365: choose interactive `op` versus a scoped service account, document token
   ownership and rotation if applicable, and retain the two Git warm-up stages in either case.
7. Land the exact AGENTS.md addition with the validated helper. Train planners to send it before
   implementation instructions and to preserve the warm-up timestamp in task status.
8. Audit the first week of tasks for leftover scratch refs, blocked end-of-task pushes, and cache
   expiry. Any failure returns the workflow to explicit operator gates until its cause is known.
