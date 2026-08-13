#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "warm-git-credentials: $*" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || fail "git is required"
[[ $(git rev-parse --is-inside-work-tree 2>/dev/null) == true ]] || fail "run inside a Git worktree"
[[ -z $(git status --porcelain) ]] || fail "worktree must be clean"

start_branch=$(git branch --show-current)
[[ -n $start_branch ]] || fail "run from a named feature branch"
case "$start_branch" in
  main | master | release/v1) fail "run from a feature branch, not $start_branch" ;;
esac

push_url=$(git remote get-url --push origin)
case "$push_url" in
  git@* | ssh://*) ;;
  *) fail "origin must use an SSH push URL" ;;
esac

scratch="scratch/biometric-warmup/$(date -u +%Y%m%dT%H%M%SZ)-$$"

cleanup() {
  local result=$?
  local cleanup_result=0
  local current_branch
  trap - EXIT
  set +e

  current_branch=$(git branch --show-current)
  if [[ $current_branch != "$start_branch" ]]; then
    git switch "$start_branch"
    cleanup_result=$?
  fi
  if git show-ref --verify --quiet "refs/heads/$scratch"; then
    git branch -D "$scratch"
    branch_result=$?
    if [[ $cleanup_result -eq 0 && $branch_result -ne 0 ]]; then
      cleanup_result=$branch_result
    fi
  fi
  if [[ $cleanup_result -eq 0 ]]; then
    [[ $(git branch --show-current) == "$start_branch" ]] || cleanup_result=1
    [[ -z $(git status --porcelain) ]] || cleanup_result=1
  fi

  [[ $result -ne 0 ]] || result=$cleanup_result
  exit "$result"
}
trap cleanup EXIT

git switch -c "$scratch"
git commit -S --allow-empty -m "chore: biometric warm-up (discard)"
git push --dry-run origin "HEAD:refs/heads/$scratch"
