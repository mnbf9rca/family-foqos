#!/usr/bin/env bash
set -euo pipefail

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

echo "PASS: version increment gate cases"
