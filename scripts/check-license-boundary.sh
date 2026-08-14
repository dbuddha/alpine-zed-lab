#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
default_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_root=${LAB_ROOT:-$default_root}
cd "$repo_root"

tracked_paths=$(git ls-files --cached --others --exclude-standard)
forbidden_file=$(mktemp /tmp/alpine-zed-lab-forbidden.XXXXXX)
trap 'rm -f "$forbidden_file"' EXIT HUP INT TERM

git check-ignore -q .lab/alpine-policy-probe || { printf '.lab must remain ignored\n' >&2; exit 1; }
git check-ignore -q artifacts/alpine-policy-probe || { printf 'artifacts must remain ignored\n' >&2; exit 1; }

if printf '%s\n' "$tracked_paths" | awk '
    /^\.lab\// || /^artifacts\// || /^vendor\/zed(\/|$)/ { print; found = 1 }
    END { exit found ? 0 : 1 }
' > "$forbidden_file"; then
    printf 'tracked upstream source or generated artifacts are forbidden:\n' >&2
    sed 's/^/  /' "$forbidden_file" >&2
    exit 1
fi

LAB_ROOT="$repo_root" "$script_dir/check-series.sh" >/dev/null

printf 'license-boundary checks passed\n'
