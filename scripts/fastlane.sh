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
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:-}" in
  screenshots|beta|release|verify_export)
    if ! command -v xcbeautify >/dev/null 2>&1; then
      echo "xcbeautify is required. Install it with: brew install xcbeautify" >&2
      exit 127
    fi
    if ! xcbeautify --version >/dev/null 2>&1; then
      echo "xcbeautify is unavailable. Reinstall it with: brew install xcbeautify" >&2
      exit 1
    fi
    ;;
esac

case "${1:-}" in
  beta|release|verify_export|pull_metadata|check_asc_key)
    if ! command -v op >/dev/null 2>&1; then
      echo "1Password CLI 'op' is required for credential-using Fastlane lanes." >&2
      exit 127
    fi
    ;;
esac

export BUNDLE_PATH="$repo_root/vendor/bundle"
export BUNDLE_FROZEN=true

if ! command -v bundle >/dev/null 2>&1; then
  echo "Bundler is required. Reinstall Homebrew Ruby with: brew reinstall ruby" >&2
  exit 127
fi
if ! bundle --version >/dev/null 2>&1; then
  echo "Bundler is unavailable. Reinstall Homebrew Ruby with: brew reinstall ruby" >&2
  exit 1
fi

if ! bundle check >/dev/null 2>&1; then
  echo "Installing locked Fastlane dependencies in $BUNDLE_PATH" >&2
  if ! bundle install; then
    echo "Fastlane dependencies could not be installed in $BUNDLE_PATH" >&2
    exit 1
  fi
fi

case "${1:-}" in
  beta|release|verify_export|pull_metadata|check_asc_key)
    exec op run --env-file "$(dirname "$0")/../fastlane/asc.env" -- \
      bundle exec fastlane "$@"
    ;;
  *)
    exec bundle exec fastlane "$@"
    ;;
esac
