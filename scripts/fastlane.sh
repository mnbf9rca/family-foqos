#!/bin/bash
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required to run Fastlane. Install Homebrew, then run: brew install ruby" >&2
  exit 127
fi

if ! ruby_prefix="$(brew --prefix ruby 2>/dev/null)" || [[ -z "$ruby_prefix" ]]; then
  echo "Homebrew Ruby is required to run Fastlane. Install it with: brew install ruby" >&2
  exit 1
fi

export PATH="$ruby_prefix/bin:$PATH"

case "${1:-}" in
  beta|release|pull_metadata|check_asc_key)
    if ! command -v op >/dev/null 2>&1; then
      echo "1Password CLI 'op' is required for credential-using Fastlane lanes." >&2
      exit 127
    fi
    exec op run --env-file "$(dirname "$0")/../fastlane/asc.env" -- \
      bundle exec fastlane "$@"
    ;;
  *)
    exec bundle exec fastlane "$@"
    ;;
esac
