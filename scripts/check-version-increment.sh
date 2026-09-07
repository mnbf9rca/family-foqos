#!/usr/bin/env bash
set -euo pipefail

PROJECT_FILE="FamilyFoqos.xcodeproj/project.pbxproj"

usage() {
  echo "Usage: $0 <base-ref> [head-ref]" >&2
}

unique_setting_value() {
  local ref=$1
  local setting=$2
  local project
  local values
  local count

  if ! project=$(git show "$ref:$PROJECT_FILE"); then
    echo "Unable to read $PROJECT_FILE at ref '$ref'." >&2
    return 1
  fi

  values=$(
    printf '%s\n' "$project" \
      | sed -nE "s/^[[:space:]]*${setting}[[:space:]]*=[[:space:]]*([^;]+);.*/\\1/p" \
      | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
      | sort -u
  )
  count=$(printf '%s\n' "$values" | awk 'NF { count += 1 } END { print count + 0 }')

  if [[ "$count" -eq 0 ]]; then
    echo "$setting is missing at ref '$ref'." >&2
    return 1
  fi
  if [[ "$count" -ne 1 ]]; then
    echo "$setting is inconsistent at ref '$ref':" >&2
    printf '  %s\n' "$values" >&2
    return 1
  fi

  printf '%s\n' "$values"
}

decimal_compare() {
  local left=$1
  local right=$2

  while [[ ${#left} -gt 1 && ${left:0:1} == "0" ]]; do
    left=${left:1}
  done
  while [[ ${#right} -gt 1 && ${right:0:1} == "0" ]]; do
    right=${right:1}
  done

  if [[ ${#left} -gt ${#right} ]]; then
    echo 1
  elif [[ ${#left} -lt ${#right} ]]; then
    echo -1
  elif [[ "$left" > "$right" ]]; then
    echo 1
  elif [[ "$left" < "$right" ]]; then
    echo -1
  else
    echo 0
  fi
}

version_is_greater() {
  local head_version=$1
  local base_version=$2
  local head_parts
  local base_parts
  local index
  local comparison

  IFS=. read -r -a head_parts <<<"$head_version"
  IFS=. read -r -a base_parts <<<"$base_version"

  for index in 0 1 2; do
    comparison=$(decimal_compare "${head_parts[$index]}" "${base_parts[$index]}")
    if [[ "$comparison" -gt 0 ]]; then
      return 0
    fi
    if [[ "$comparison" -lt 0 ]]; then
      return 1
    fi
  done

  return 1
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

for tool in git sed sort awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required" >&2; exit 1; }
done

base_ref=$1
head_ref=${2:-HEAD}

# Only a nonempty diff containing docs/ or Markdown paths can skip the bump.
# Disable renames so moving a build file into docs still counts its deletion.
if git diff --quiet --no-ext-diff --no-textconv --no-renames "$base_ref" "$head_ref" --; then
  : # Empty diffs keep the existing version requirement.
else
  status=$?
  [[ "$status" -eq 1 ]] || { echo "Unable to read PR diff." >&2; exit "$status"; }
  if git diff --quiet --no-ext-diff --no-textconv --no-renames "$base_ref" "$head_ref" -- \
    ':(top,glob,exclude)docs/**' ':(top,glob,exclude)**/*.md'; then
    echo "Version gate passed: docs-only diff; no version bump required."
    exit 0
  else
    status=$?
    [[ "$status" -eq 1 ]] || { echo "Unable to classify PR paths." >&2; exit "$status"; }
  fi
fi

base_marketing=$(unique_setting_value "$base_ref" MARKETING_VERSION)
head_marketing=$(unique_setting_value "$head_ref" MARKETING_VERSION)
base_build=$(unique_setting_value "$base_ref" CURRENT_PROJECT_VERSION)
head_build=$(unique_setting_value "$head_ref" CURRENT_PROJECT_VERSION)

if [[ ! "$base_marketing" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid MARKETING_VERSION at ref '$base_ref': $base_marketing" >&2
  exit 1
fi
if [[ ! "$head_marketing" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid MARKETING_VERSION at ref '$head_ref': $head_marketing" >&2
  exit 1
fi
if [[ ! "$base_build" =~ ^[0-9]+$ ]]; then
  echo "Invalid CURRENT_PROJECT_VERSION at ref '$base_ref': $base_build" >&2
  exit 1
fi
if [[ ! "$head_build" =~ ^[0-9]+$ ]]; then
  echo "Invalid CURRENT_PROJECT_VERSION at ref '$head_ref': $head_build" >&2
  exit 1
fi

failed=0
if ! version_is_greater "$head_marketing" "$base_marketing"; then
  echo "MARKETING_VERSION must increase (base: $base_marketing, head: $head_marketing)." >&2
  failed=1
fi
if [[ $(decimal_compare "$head_build" "$base_build") -ne 1 ]]; then
  echo "CURRENT_PROJECT_VERSION must increase (base: $base_build, head: $head_build)." >&2
  failed=1
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "Version gate passed: MARKETING_VERSION $base_marketing -> $head_marketing; CURRENT_PROJECT_VERSION $base_build -> $head_build."
