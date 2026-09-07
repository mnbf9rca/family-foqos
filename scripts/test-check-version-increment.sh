#!/usr/bin/env bash
set -euo pipefail

for tool in dirname mktemp rm mkdir git bash; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required" >&2; exit 1; }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE_SCRIPT="$REPO_ROOT/scripts/check-version-increment.sh"
TEST_ROOT=$(mktemp -d)

cleanup() {
  if [[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

if [[ ! -f "$GATE_SCRIPT" ]]; then
  echo "FAIL: version increment gate script is missing"
  exit 1
fi

write_project() {
  local marketing_version=$1
  local build_version=$2
  local second_marketing_version=${3:-$marketing_version}
  local second_build_version=${4:-$build_version}

  mkdir -p "$TEST_ROOT/FamilyFoqos.xcodeproj"
  printf '%s\n' \
    'buildSettings = {' \
    "  CURRENT_PROJECT_VERSION = $build_version;" \
    "  MARKETING_VERSION = $marketing_version;" \
    '};' \
    'buildSettings = {' \
    "  CURRENT_PROJECT_VERSION = $second_build_version;" \
    "  MARKETING_VERSION = $second_marketing_version;" \
    '};' \
    >"$TEST_ROOT/FamilyFoqos.xcodeproj/project.pbxproj"
}

commit_fixture() {
  local marketing_version=$1
  local build_version=$2
  local second_marketing_version=${3:-$marketing_version}
  local second_build_version=${4:-$build_version}

  write_project \
    "$marketing_version" \
    "$build_version" \
    "$second_marketing_version" \
    "$second_build_version"
  git -C "$TEST_ROOT" add FamilyFoqos.xcodeproj/project.pbxproj
  git -C "$TEST_ROOT" commit -q -m "fixture $marketing_version ($build_version)"
  git -C "$TEST_ROOT" rev-parse HEAD
}

run_gate() {
  local head_ref=$1
  set +e
  GATE_OUTPUT=$(cd "$TEST_ROOT" && bash "$GATE_SCRIPT" "$BASE_REF" "$head_ref" 2>&1)
  GATE_STATUS=$?
  set -e
}

expect_pass() {
  local description=$1
  local head_ref=$2
  run_gate "$head_ref"
  if [[ "$GATE_STATUS" -ne 0 ]]; then
    echo "FAIL: $description should pass"
    echo "$GATE_OUTPUT"
    exit 1
  fi
}

expect_fail() {
  local description=$1
  local head_ref=$2
  run_gate "$head_ref"
  if [[ "$GATE_STATUS" -eq 0 ]]; then
    echo "FAIL: $description should fail"
    echo "$GATE_OUTPUT"
    exit 1
  fi
}

git -C "$TEST_ROOT" init -q
git -C "$TEST_ROOT" config user.name "Version Gate Test"
git -C "$TEST_ROOT" config user.email "version-gate@example.invalid"
git -C "$TEST_ROOT" config commit.gpgsign false

BASE_REF=$(commit_fixture 1.2.3 10)

head_ref=$(commit_fixture 1.2.4 11)
expect_pass "both versions increasing" "$head_ref"

head_ref=$(commit_fixture 1.2.3 12)
expect_fail "unchanged marketing version" "$head_ref"

head_ref=$(commit_fixture 1.2.5 10)
expect_fail "unchanged build version" "$head_ref"

head_ref=$(commit_fixture 1.2.2 13)
expect_fail "decreased marketing version" "$head_ref"

head_ref=$(commit_fixture 1.2.6 9)
expect_fail "decreased build version" "$head_ref"

head_ref=$(commit_fixture 1.10.0 14)
expect_pass "multi-digit semantic version increase" "$head_ref"

head_ref=$(commit_fixture 1.2 15)
expect_fail "malformed marketing version" "$head_ref"

head_ref=$(commit_fixture 1.2.7 16 1.2.8 16)
expect_fail "inconsistent project versions" "$head_ref"

expect_fail "empty diff" "$BASE_REF"

# Restore unchanged versions; only the paths added below differ from the base.
write_project 1.2.3 10
mkdir -p "$TEST_ROOT/docs" "$TEST_ROOT/notes"
printf 'documentation\n' >"$TEST_ROOT/README.md"
printf 'nested documentation\n' >"$TEST_ROOT/notes/guide.md"
printf 'diagram\n' >"$TEST_ROOT/docs/diagram.svg"
git -C "$TEST_ROOT" add .
git -C "$TEST_ROOT" commit -q -m "docs only"
head_ref=$(git -C "$TEST_ROOT" rev-parse HEAD)
expect_pass "docs-only diff without a version bump" "$head_ref"

printf 'source\n' >"$TEST_ROOT/App.swift"
git -C "$TEST_ROOT" add App.swift
git -C "$TEST_ROOT" commit -q -m "mixed docs and source"
head_ref=$(git -C "$TEST_ROOT" rev-parse HEAD)
expect_fail "mixed diff without a version bump" "$head_ref"

BASE_REF=$head_ref
git -C "$TEST_ROOT" mv App.swift docs/App.swift
git -C "$TEST_ROOT" commit -q -m "move source into docs"
head_ref=$(git -C "$TEST_ROOT" rev-parse HEAD)
expect_fail "source-to-doc rename" "$head_ref"

BASE_REF=$head_ref
mkdir -p "$TEST_ROOT/.github/workflows"
printf 'name: test\n' >"$TEST_ROOT/.github/workflows/test.yml"
git -C "$TEST_ROOT" add .github
git -C "$TEST_ROOT" commit -q -m "workflow change"
head_ref=$(git -C "$TEST_ROOT" rev-parse HEAD)
expect_fail "workflow change without a version bump" "$head_ref"

# A classifier failure must not look like an empty list of build paths.
(
  # shellcheck disable=SC2329 # Exported into the gate subprocess.
  git() {
    case "$*" in
      *':(top,glob,exclude)'*) return 73 ;;
      *) command git "$@" ;;
    esac
  }
  export -f git
  expect_fail "path classification unavailable" "$head_ref"
  [[ "$GATE_STATUS" -eq 73 ]] || { echo "FAIL: classifier status was not preserved"; exit 1; }
)

expect_fail "unreadable diff" missing-ref
if [[ "$GATE_STATUS" -ne 128 ]]; then
  echo "FAIL: unreadable diff should preserve Git status 128, got $GATE_STATUS"
  exit 1
fi

echo "PASS: version increment gate cases"
