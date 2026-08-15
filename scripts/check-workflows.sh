#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

workflow_files=$(find .github/workflows -type f -name '*.yml' -print | sort)
[ -n "$workflow_files" ] || { printf 'no GitHub workflows found\n' >&2; exit 1; }

uses_count=0
for workflow in $workflow_files; do
    while IFS= read -r action; do
        uses_count=$((uses_count + 1))
        case "$action" in
            ./*) continue ;;
            *@*) action_ref=${action##*@} ;;
            *) printf 'action is not pinned: %s\n' "$action" >&2; exit 1 ;;
        esac
        case "$action_ref" in *[!0-9a-f]*|'') printf 'action is not pinned by a lowercase full SHA: %s\n' "$action" >&2; exit 1 ;; esac
        [ "${#action_ref}" -eq 40 ] || { printf 'action is not pinned by a 40-character SHA: %s\n' "$action" >&2; exit 1; }
    done <<EOF
$(sed -n 's/^[[:space:]]*- uses:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$workflow")
EOF
done

[ "$uses_count" -gt 0 ] || { printf 'no GitHub Actions references found\n' >&2; exit 1; }

gpui_retention=$(awk '
    /name: gpui-oracle-/ { artifact = 1; next }
    artifact && /retention-days:/ { print $2; exit }
' .github/workflows/ci.yml)
[ "$gpui_retention" = 90 ] || {
    printf 'GPUI qualification artifacts must be retained for exactly 90 days\n' >&2
    exit 1
}

printf 'workflow pin checks passed\n'
