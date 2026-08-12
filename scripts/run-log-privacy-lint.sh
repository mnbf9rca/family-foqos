#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "error: Usage: run-log-privacy-lint.sh REPO_ROOT" >&2
  exit 2
fi

[ -x /usr/bin/env ] || {
  echo "error: Log Privacy Lint requires macOS env at /usr/bin/env" >&2
  exit 2
}
[ -x /usr/bin/ruby ] || {
  echo "error: Log Privacy Lint requires macOS system Ruby at /usr/bin/ruby" >&2
  exit 2
}

repo_root=$1
exec /usr/bin/env -i \
  /usr/bin/ruby "$repo_root/scripts/check-log-privacy.rb" --root "$repo_root"
