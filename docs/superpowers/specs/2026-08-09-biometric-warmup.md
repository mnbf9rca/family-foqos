# Biometric Warm-up for Agent Sessions (#363)

**Status:** Approved for the repository's `AGENTS.md`
**Scope:** Exact session-start `AGENTS.md` rule and brief expiry fallback.

## Exact AGENTS.md addition

Add this under the repository's key rules:

````diff
+  - **WARM GIT CREDENTIALS BEFORE DELEGATING IMPLEMENTATION.** At session start, while the human
+    is present, every implementation subagent must warm both 1Password-backed Git paths in its
+    clean assigned worktree before real work. Run this block so commit-signing and SSH prompts
+    happen while the human can touch the sensor:
+
+    ```bash
+    (
+      set -e
+      test -z "$(git status --porcelain)"
+      start_branch="$(git branch --show-current)"
+      test -n "$start_branch"
+      case "$(git remote get-url --push origin)" in git@*|ssh://*) ;; *) exit 1 ;; esac
+      scratch="scratch/biometric-warmup/$(date -u +%Y%m%dT%H%M%SZ)-$$"
+      git switch -c "$scratch"
+      trap 'git switch "$start_branch"; git branch -D "$scratch"' EXIT
+      git commit -S --allow-empty -m "chore: biometric warm-up (discard)"
+      git push --dry-run origin "HEAD:refs/heads/$scratch"
+    )
+    ```
+
+    The dry run must use the SSH push URL and must not create a remote ref. Start real work only
+    after the block succeeds and the assigned worktree is back on its starting branch and clean.
````

If signing or SSH approval expires mid-session, rerun the block while the human is present. If the
human is absent, commit-only work may use the authorized GitHub `createCommitOnBranch` API when one
server-side commit exactly represents the change; otherwise wait. Never disable signing, create an
unsigned production commit, amend, or force-push to evade a prompt.

The separate `op` prompt is handled by #365's service-account credential path, not this Git warm-up.
