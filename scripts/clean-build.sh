#!/bin/bash
set -euo pipefail

target="${IOS_SIM_GATE_DERIVED_DATA_PATH:-}"
[[ -n "$target" ]] || {
  echo "clean-build: requires IOS_SIM_GATE_DERIVED_DATA_PATH from ios-sim-gate" >&2
  exit 1
}
[[ "$target" == /* ]] || {
  echo "clean-build: refusing relative DerivedData path: $target" >&2
  exit 1
}

project_root="$HOME/Library/Caches/ios-sim-gate/DerivedData/family-foqos"
case "$target" in
  "$project_root"/*) ;;
  *)
    echo "clean-build: refusing path outside Family Foqos gate storage: $target" >&2
    exit 1
    ;;
esac

relative=${target#"$project_root"/}
case "/$relative/" in
  */../*|*/./*)
    echo "clean-build: refusing traversal-like DerivedData path: $target" >&2
    exit 1
    ;;
esac

IFS=/ read -r agent owner_scope extra <<<"$relative"
if [[ -z "$agent" || -z "$owner_scope" || -n "${extra:-}" ]]; then
  echo "clean-build: refusing non-owner DerivedData path: $target" >&2
  exit 1
fi
[[ "$agent" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
  echo "clean-build: refusing invalid gate agent path: $target" >&2
  exit 1
}
if [[ "$owner_scope" != "no-session" &&
  ! "$owner_scope" =~ ^session-[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  echo "clean-build: refusing invalid gate session path: $target" >&2
  exit 1
fi

if [[ ! -e "$target" && ! -L "$target" ]]; then
  echo "DerivedData already absent: $target"
  exit 0
fi

canonical_root=$(cd "$project_root" && pwd -P)
canonical_parent=$(cd "$(dirname "$target")" && pwd -P)
canonical_target="$canonical_parent/$(basename "$target")"
[[ "$canonical_target" == "$canonical_root/$agent/$owner_scope" ]] || {
  echo "clean-build: refusing path whose canonical parent escapes gate storage: $target" >&2
  exit 1
}

rm -rf -- "$target"
echo "Cleaned gate-owned DerivedData: $target"
