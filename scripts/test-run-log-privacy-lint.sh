#!/bin/bash
set -euo pipefail

required_commands=(bundle dirname env rg)
for required_command in "${required_commands[@]}"; do
  command -v "$required_command" >/dev/null || {
    echo "FAIL: required command not found: $required_command" >&2
    exit 127
  }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/run-log-privacy-lint.sh"

[[ -x "$RUNNER" ]] || {
  echo "FAIL: Log Privacy Lint runner is missing or not executable"
  exit 1
}

BUNDLER_ENV=$(bundle exec env)
printf '%s\n' "$BUNDLER_ENV" | rg '^RUBYOPT=' >/dev/null || {
  echo "FAIL: bundle exec did not provide the RUBYOPT poison"
  exit 1
}
printf '%s\n' "$BUNDLER_ENV" | rg '^RUBYLIB=' >/dev/null || {
  echo "FAIL: bundle exec did not provide the RUBYLIB poison"
  exit 1
}

OUTPUT=$(bundle exec "$RUNNER" "$REPO_ROOT")
[[ "$OUTPUT" == *"Log privacy lint passed:"* ]] || {
  echo "FAIL: lint runner did not survive Bundler's Ruby environment"
  echo "$OUTPUT"
  exit 1
}

echo "PASS: Log Privacy Lint runner sanitizes Bundler's Ruby environment"
