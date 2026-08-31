#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

workflow_root=${WORKFLOW_ROOT:-.github/workflows}
workflow_files=$(find "$workflow_root" -type f -name '*.yml' -print | sort)
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
' "$workflow_root/ci.yml")
[ "$gpui_retention" = 90 ] || {
    printf 'GPUI qualification artifacts must be retained for exactly 90 days\n' >&2
    exit 1
}

ci_workflow="$workflow_root/ci.yml"
ci_pass_block=$(awk '
    /^  ci-pass:$/ { inside = 1 }
    inside && /^  [A-Za-z0-9_-]+:$/ && $0 != "  ci-pass:" { exit }
    inside { print }
' "$ci_workflow")
[ "$(grep -c '^  ci-pass:$' "$ci_workflow")" -eq 1 ] || {
    printf 'CI must define exactly one aggregate ci-pass job\n' >&2
    exit 1
}
[ "$(grep -c '^    name: ci-pass$' "$ci_workflow")" -eq 1 ] || {
    printf 'aggregate job must publish the stable ci-pass check name\n' >&2
    exit 1
}
printf '%s\n' "$ci_pass_block" | grep -Fq '    if: always()' || {
    printf 'aggregate ci-pass must run after failed or cancelled dependencies\n' >&2
    exit 1
}
printf '%s\n' "$ci_pass_block" |
    grep -Fq '    needs: [policy, provision, paired-protocol, gpui-oracle-equivalence, physical-sampler-bundle]' || {
    printf 'aggregate ci-pass must depend on every required lab gate\n' >&2
    exit 1
}

for binding in \
    'POLICY_RESULT: ${{ needs.policy.result }}' \
    'PROVISION_RESULT: ${{ needs.provision.result }}' \
    'PAIRED_PROTOCOL_RESULT: ${{ needs.paired-protocol.result }}' \
    'GPUI_ORACLE_RESULT: ${{ needs.gpui-oracle-equivalence.result }}' \
    'PHYSICAL_SAMPLER_RESULT: ${{ needs.physical-sampler-bundle.result }}'
do
    printf '%s\n' "$ci_pass_block" | grep -Fq "$binding" || {
        printf 'aggregate ci-pass is missing result binding: %s\n' "$binding" >&2
        exit 1
    }
done

for result in POLICY PROVISION PAIRED_PROTOCOL GPUI_ORACLE PHYSICAL_SAMPLER; do
    printf '%s\n' "$ci_pass_block" |
        grep -Fq "test \"\$${result}_RESULT\" = success" || {
        printf 'aggregate ci-pass does not require success from %s\n' "$result" >&2
        exit 1
    }
done

physical_retention=$(awk '
    /name: physical-sampler-candidate-/ { artifact = 1; next }
    artifact && /retention-days:/ { print $2; exit }
' "$ci_workflow")
[ "$physical_retention" = 90 ] || {
    printf 'physical sampler candidates must be retained for exactly 90 days\n' >&2
    exit 1
}
grep -Fq '    needs: [ci-pass, policy, gpui-oracle-equivalence]' "$ci_workflow" || {
    printf 'physical sampler publication must wait for aggregate ci-pass and oracle evidence\n' >&2
    exit 1
}

printf 'workflow pin checks passed\n'
