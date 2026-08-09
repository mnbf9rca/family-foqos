#!/bin/bash
set -euo pipefail

export PATH="$(brew --prefix ruby)/bin:$PATH"

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
