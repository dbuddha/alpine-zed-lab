#!/bin/sh
set -eu

root=artifacts/workflow-gate-tests
rm -rf "$root"
mkdir -p "$root/reference"
trap 'rm -rf "$root"' EXIT HUP INT TERM
cp .github/workflows/*.yml "$root/reference/"

WORKFLOW_ROOT="$root/reference" scripts/check-workflows.sh >/dev/null

assert_rejected() {
    name=$1
    old=$2
    new=$3
    fixture="$root/$name"
    cp -R "$root/reference" "$fixture"
    python3 - "$fixture/ci.yml" "$old" "$new" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
old = sys.argv[2]
new = sys.argv[3]
text = path.read_text(encoding="utf-8")
if text.count(old) != 1:
    raise SystemExit(f"expected exactly one mutation target: {old!r}")
path.write_text(text.replace(old, new), encoding="utf-8")
PY
    if WORKFLOW_ROOT="$fixture" scripts/check-workflows.sh >"$root/$name.log" 2>&1; then
        printf 'invalid aggregate workflow unexpectedly passed: %s\n' "$name" >&2
        exit 1
    fi
}

assert_rejected missing-job '  ci-pass:' '  ci-pass-removed:'
assert_rejected missing-stable-name '    name: ci-pass' '    name: aggregate-removed'
assert_rejected missing-always '  ci-pass:
    name: ci-pass
    if: always()' '  ci-pass:
    name: ci-pass
    if: success()'
assert_rejected missing-oracle-need \
    '    needs: [policy, provision, paired-protocol, gpui-oracle-equivalence]' \
    '    needs: [policy, provision, paired-protocol]'
assert_rejected missing-policy-result \
    '          POLICY_RESULT: ${{ needs.policy.result }}' \
    '          POLICY_RESULT_REMOVED: ${{ needs.policy.result }}'
assert_rejected policy-not-required \
    '          test "$POLICY_RESULT" = success' \
    '          test "$POLICY_RESULT" = failure'
assert_rejected provision-not-required \
    '          test "$PROVISION_RESULT" = success' \
    '          test "$PROVISION_RESULT" = failure'
assert_rejected protocol-not-required \
    '          test "$PAIRED_PROTOCOL_RESULT" = success' \
    '          test "$PAIRED_PROTOCOL_RESULT" = failure'
assert_rejected oracle-not-required \
    '          test "$GPUI_ORACLE_RESULT" = success' \
    '          test "$GPUI_ORACLE_RESULT" = failure'

printf 'aggregate workflow gate controls passed\n'
