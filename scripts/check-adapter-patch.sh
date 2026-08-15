#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

if [ ! -d .lab/zed/.git ]; then
    printf 'adapter patch application skipped because the ignored Zed checkout is absent\n'
    exit 0
fi

scripts/check-pin.sh >/dev/null
while IFS=' ' read -r expected_hash patch_path extra; do
    case "$expected_hash" in ''|'#'*) continue ;; esac
    [ -z "${extra:-}" ] || { printf 'invalid Alpine adapter series entry\n' >&2; exit 1; }
    git -C .lab/zed apply --check "$repo_root/$patch_path"
done < patches/alpine-metal/series

printf 'Alpine adapter patches apply to the exact clean Zed pin\n'
