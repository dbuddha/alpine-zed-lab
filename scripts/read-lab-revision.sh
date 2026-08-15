#!/bin/sh
set -eu

repo_root=${LAB_ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}

git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    printf 'lab root is not a Git worktree: %s\n' "$repo_root" >&2
    exit 1
}

lab_revision=$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
    printf 'lab root has no committed revision: %s\n' "$repo_root" >&2
    exit 1
}

case "$lab_revision" in
    *[!0-9a-f]*|'')
        printf 'lab revision is not a lowercase Git SHA: %s\n' "$lab_revision" >&2
        exit 1
        ;;
esac
[ "${#lab_revision}" -eq 40 ] || {
    printf 'lab revision must contain 40 hexadecimal characters\n' >&2
    exit 1
}

tracked_changes=$(git -C "$repo_root" status --porcelain --untracked-files=no)
[ -z "$tracked_changes" ] || {
    printf 'lab worktree has tracked changes that are not identified by %s\n' "$lab_revision" >&2
    exit 1
}

printf '%s\n' "$lab_revision"
