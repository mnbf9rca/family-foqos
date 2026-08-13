#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
subject="$repo_root/scripts/warm-git-credentials.sh"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$test_root/bin"
cat >"$test_root/bin/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$WARM_TEST_LOG"
command_name=${1:-}
shift || true
case "$command_name ${1:-}" in
  "rev-parse --is-inside-work-tree") echo true ;;
  "status --porcelain")
    [[ ${WARM_TEST_SCENARIO:-} == dirty ]] && echo ' M user-file'
    exit 0
    ;;
  "branch --show-current") cat "$WARM_TEST_BRANCH" ;;
  "remote get-url") echo "${WARM_TEST_REMOTE:-git@github.com:mnbf9rca/family-foqos.git}" ;;
  "switch -c")
    [[ ${WARM_TEST_SCENARIO:-} == switch_create_fail ]] && exit 41
    printf '%s\n' "$2" >"$WARM_TEST_BRANCH"
    printf '%s\n' "$2" >"$WARM_TEST_SCRATCH"
    ;;
  "switch "*)
    [[ ${WARM_TEST_SCENARIO:-} == switch_restore_fail ]] && exit 44
    printf '%s\n' "$1" >"$WARM_TEST_BRANCH"
    ;;
  "commit -S")
    [[ ${WARM_TEST_SCENARIO:-} == commit_fail ]] && exit 42
    exit 0
    ;;
  "push --dry-run")
    [[ ${WARM_TEST_SCENARIO:-} == push_fail ]] && exit 43
    exit 0
    ;;
  "show-ref --verify") [[ -s "$WARM_TEST_SCRATCH" ]] || exit 1 ;;
  "branch -D") : >"$WARM_TEST_SCRATCH" ;;
  *) echo "unexpected fake git call: $command_name $*" >&2; exit 90 ;;
esac
FAKE_GIT
chmod +x "$test_root/bin/git"

run_case() {
  local scenario=$1
  local branch=${2-feature/387}
  local remote=${3-git@github.com:mnbf9rca/family-foqos.git}
  case_root="$test_root/$scenario"
  mkdir -p "$case_root"
  printf '%s\n' "$branch" >"$case_root/branch"
  : >"$case_root/scratch"
  : >"$case_root/log"
  set +e
  output=$(
    PATH="$test_root/bin:/usr/bin:/bin" \
      WARM_TEST_SCENARIO="$scenario" \
      WARM_TEST_REMOTE="$remote" \
      WARM_TEST_BRANCH="$case_root/branch" \
      WARM_TEST_SCRATCH="$case_root/scratch" \
      WARM_TEST_LOG="$case_root/log" \
      "$subject" 2>&1
  )
  result=$?
  set -e
}

[[ -x "$subject" ]] || fail "warm-up script is missing or not executable"

run_case success
[[ $result -eq 0 ]] || fail "success returned $result: $output; calls: $(tr '\n' ';' <"$case_root/log")"
[[ $(cat "$case_root/branch") == feature/387 ]] || fail "success did not restore branch"
[[ ! -s "$case_root/scratch" ]] || fail "success did not delete scratch branch"
rg -q '^commit -S --allow-empty -m chore: biometric warm-up \(discard\)$' "$case_root/log" || fail "signed scratch commit missing"
rg -q '^push --dry-run origin HEAD:refs/heads/scratch/biometric-warmup/' "$case_root/log" || fail "SSH dry-run missing"

run_case dirty
[[ $result -eq 1 && $output == *"worktree must be clean"* ]] || fail "dirty tree did not fail closed"

run_case success ''
[[ $result -eq 1 && $output == *"named feature branch"* ]] || fail "unnamed branch did not fail closed"

run_case success main
[[ $result -eq 1 && $output == *"feature branch, not main"* ]] || fail "default branch did not fail closed"

run_case success feature/387 https://github.com/mnbf9rca/family-foqos.git
[[ $result -eq 1 && $output == *"SSH push URL"* ]] || fail "HTTPS remote did not fail closed"

run_case switch_create_fail
[[ $result -eq 41 ]] || fail "scratch creation failure status was $result, expected 41"
[[ $(cat "$case_root/branch") == feature/387 && ! -s "$case_root/scratch" ]] || fail "scratch creation failure changed worktree state"

run_case commit_fail
[[ $result -eq 42 ]] || fail "commit failure status was $result, expected 42"
[[ $(cat "$case_root/branch") == feature/387 && ! -s "$case_root/scratch" ]] || fail "commit failure did not clean up"

run_case push_fail
[[ $result -eq 43 ]] || fail "push failure status was $result, expected 43"
[[ $(cat "$case_root/branch") == feature/387 && ! -s "$case_root/scratch" ]] || fail "push failure did not clean up"

run_case switch_restore_fail
[[ $result -eq 44 ]] || fail "cleanup failure status was $result, expected 44"

echo "PASS: Git credential warm-up fails closed and restores its worktree"
