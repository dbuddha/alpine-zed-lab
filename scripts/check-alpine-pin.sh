#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

PIN_FILE=${ALPINE_PIN_FILE:-pins/alpine.toml}
export PIN_FILE
. scripts/lib/pin.sh

network=false
if [ "${1:-}" = "--network" ]; then
    network=true
elif [ "$#" -ne 0 ]; then
    printf 'usage: %s [--network]\n' "$0" >&2
    exit 2
fi

schema=$(pin_value schema)
repository=$(pin_value repository)
commit=$(pin_value commit)
visibility=$(pin_value visibility)
trace_manifest_path=$(pin_value trace_manifest_path)
trace_manifest_sha256=$(pin_value trace_manifest_sha256)

expected_keys='commit
repository
schema
trace_manifest_path
trace_manifest_sha256
visibility'
actual_keys=$(awk -F '[[:space:]]*=[[:space:]]*' '
    /^[[:space:]]*($|#)/ { next }
    NF != 2 { print "<invalid>"; next }
    { print $1 }
' "$PIN_FILE" | sort)
[ "$actual_keys" = "$expected_keys" ] || {
    printf 'Alpine pin schema fields differ from alpine-revision-pin/v2\n' >&2
    exit 1
}

[ "$schema" = "alpine-revision-pin/v2" ] || { printf 'unsupported Alpine pin schema: %s\n' "$schema" >&2; exit 1; }
[ "$repository" = "https://github.com/dbuddha/alpine-gpui.git" ] || { printf 'unexpected Alpine repository: %s\n' "$repository" >&2; exit 1; }
[ "$visibility" = "public-proprietary" ] || { printf 'unexpected Alpine visibility boundary: %s\n' "$visibility" >&2; exit 1; }
[ "$trace_manifest_path" = "pins/alpine-traces.tsv" ] || { printf 'unexpected Alpine trace manifest path: %s\n' "$trace_manifest_path" >&2; exit 1; }

case "$trace_manifest_path" in /*|*..*|*//*|*\\*) printf 'unsafe Alpine trace manifest path: %s\n' "$trace_manifest_path" >&2; exit 1 ;; esac
case "$commit" in *[!0-9a-f]*|'') printf 'commit must be a lowercase hexadecimal SHA\n' >&2; exit 1 ;; esac
[ "${#commit}" -eq 40 ] || { printf 'commit must contain 40 hexadecimal characters\n' >&2; exit 1; }
case "$trace_manifest_sha256" in *[!0-9a-f]*|'') printf 'trace manifest identity must be lowercase hexadecimal\n' >&2; exit 1 ;; esac
[ "${#trace_manifest_sha256}" -eq 64 ] || { printf 'trace manifest identity must contain 64 hexadecimal characters\n' >&2; exit 1; }

trace_manifest_file=${ALPINE_TRACE_MANIFEST_FILE:-$trace_manifest_path}
[ -f "$trace_manifest_file" ] || { printf 'Alpine trace manifest is missing: %s\n' "$trace_manifest_file" >&2; exit 1; }
actual_manifest_sha256=$(shasum -a 256 "$trace_manifest_file" | awk '{ print $1 }')
[ "$actual_manifest_sha256" = "$trace_manifest_sha256" ] || { printf 'Alpine trace manifest fingerprint mismatch\n' >&2; exit 1; }

awk -F '\t' '
    /^#/ { next }
    NF != 10 { print "trace manifest row must contain ten fields" > "/dev/stderr"; exit 1 }
    $1 !~ /^[a-z0-9-]+$/ { print "invalid trace identifier" > "/dev/stderr"; exit 1 }
    $2 != "alpine-scene-trace/v1" && $2 != "alpine-scene-trace/v2" { print "invalid trace schema" > "/dev/stderr"; exit 1 }
    $3 !~ /^assurance\/qualification\/v[12]\/[a-z0-9-]+\.toml$/ { print "invalid trace path" > "/dev/stderr"; exit 1 }
    $4 !~ /^[0-9a-f]{64}$/ || $5 !~ /^[0-9a-f]{64}$/ { print "invalid trace identity" > "/dev/stderr"; exit 1 }
    seen_id[$1]++ || seen_path[$3]++ { print "duplicate trace identity" > "/dev/stderr"; exit 1 }
    $6 == "none" && ($7 != "none" || $8 != "none" || $9 != "none" || $10 != "none") { print "partial absent pair identity" > "/dev/stderr"; exit 1 }
    $6 != "none" && ($6 !~ /^[a-z0-9-]+$/ || ($7 != "scroll" && $7 != "resize") || $8 !~ /^[0-9a-f]{64}$/ || ($9 != "0" && $9 != "1") || $10 != "2") { print "invalid pair identity" > "/dev/stderr"; exit 1 }
    $6 != "none" { key = $6 FS $7 FS $8; pair_count[key]++; pair_steps[key] += $9 + 1 }
    { count++ }
    END {
        if (count != 8) { print "trace manifest must contain eight fixtures" > "/dev/stderr"; exit 1 }
        for (key in pair_count) {
            if (pair_count[key] != 2 || pair_steps[key] != 3) {
                print "pair manifest must contain steps zero and one exactly once" > "/dev/stderr"; exit 1
            }
        }
    }
' "$trace_manifest_file"

if [ "$network" = true ]; then
    probe_root=$(mktemp -d /tmp/alpine-pin-check.XXXXXX)
    trap 'rm -rf "$probe_root"' EXIT HUP INT TERM
    git -C "$probe_root" init --bare --quiet
    GIT_TERMINAL_PROMPT=0 git -C "$probe_root" fetch --quiet --depth=1 "$repository" "$commit" || {
        printf 'Alpine commit %s cannot be fetched from the public origin\n' "$commit" >&2
        exit 1
    }
    git -C "$probe_root" cat-file -e "$commit^{commit}" || {
        printf 'Alpine object %s is not a commit\n' "$commit" >&2
        exit 1
    }
    rm -rf "$probe_root"
    trap - EXIT HUP INT TERM
fi

if [ -e .lab/alpine ] || [ -L .lab/alpine ]; then
    [ ! -L .lab/alpine ] || { printf '.lab/alpine must not be a symbolic link\n' >&2; exit 1; }
    [ -d .lab/alpine/.git ] || { printf '.lab/alpine is not a standalone Git checkout\n' >&2; exit 1; }
    checkout_commit=$(git -C .lab/alpine rev-parse HEAD)
    checkout_remote=$(git -C .lab/alpine remote get-url origin)
    [ "$checkout_commit" = "$commit" ] || { printf 'Alpine checkout is at %s, expected %s\n' "$checkout_commit" "$commit" >&2; exit 1; }
    repository_without_suffix=${repository%.git}
    case "$checkout_remote" in
        "$repository"|"$repository_without_suffix") ;;
        *) printf 'Alpine checkout origin is %s, expected %s\n' "$checkout_remote" "$repository" >&2; exit 1 ;;
    esac
    if git -C .lab/alpine symbolic-ref -q HEAD >/dev/null; then
        printf 'Alpine checkout HEAD must remain detached\n' >&2
        exit 1
    fi
    [ -z "$(git -C .lab/alpine status --porcelain)" ] || { printf 'Alpine checkout must remain clean\n' >&2; exit 1; }

    tab=$(printf '\t')
    while IFS="$tab" read -r fixture_id trace_schema trace_path trace_sha workload_hash pair_id pair_kind pair_hash pair_step pair_steps; do
        case "$fixture_id" in ''|'#'*) continue ;; esac
        trace_file=".lab/alpine/$trace_path"
        [ -f "$trace_file" ] || { printf 'Alpine checkout lacks %s\n' "$trace_path" >&2; exit 1; }
        actual_trace_sha=$(shasum -a 256 "$trace_file" | awk '{ print $1 }')
        [ "$actual_trace_sha" = "$trace_sha" ] || { printf 'Alpine trace fingerprint mismatch for %s\n' "$fixture_id" >&2; exit 1; }
        declared_schema=$(sed -nE 's/^schema = "([^"]+)"$/\1/p' "$trace_file")
        declared_id=$(sed -nE 's/^id = "([^"]+)"$/\1/p' "$trace_file" | head -1)
        declared_workload=$(sed -nE 's/^workload_hash = "([0-9a-f]{64})"$/\1/p' "$trace_file")
        canonical_workload=$(sed '/^workload_hash = /d' "$trace_file" | shasum -a 256 | awk '{ print $1 }')
        [ "$declared_schema" = "$trace_schema" ] && [ "$declared_id" = "$fixture_id" ] || { printf 'Alpine trace protocol identity mismatch for %s\n' "$fixture_id" >&2; exit 1; }
        [ "$declared_workload" = "$workload_hash" ] && [ "$canonical_workload" = "$workload_hash" ] || { printf 'Alpine trace workload identity mismatch for %s\n' "$fixture_id" >&2; exit 1; }
        declared_pair_id=$(awk '/^\[pair\]$/ { pair=1; next } pair && /^id = / { gsub(/^id = "|"$/, ""); print; exit }' "$trace_file")
        if [ "$pair_id" = none ]; then
            [ -z "$declared_pair_id" ] || { printf 'unexpected pair identity for %s\n' "$fixture_id" >&2; exit 1; }
        else
            declared_pair_kind=$(awk '/^\[pair\]$/ { pair=1; next } pair && /^kind = / { gsub(/^kind = "|"$/, ""); print; exit }' "$trace_file")
            declared_pair_hash=$(awk '/^\[pair\]$/ { pair=1; next } pair && /^sequence_hash = / { gsub(/^sequence_hash = "|"$/, ""); print; exit }' "$trace_file")
            declared_pair_step=$(awk '/^\[pair\]$/ { pair=1; next } pair && /^step = / { print $3; exit }' "$trace_file")
            declared_pair_steps=$(awk '/^\[pair\]$/ { pair=1; next } pair && /^steps = / { print $3; exit }' "$trace_file")
            [ "$declared_pair_id" = "$pair_id" ] && [ "$declared_pair_kind" = "$pair_kind" ] && [ "$declared_pair_hash" = "$pair_hash" ] && [ "$declared_pair_step" = "$pair_step" ] && [ "$declared_pair_steps" = "$pair_steps" ] || { printf 'Alpine trace pair identity mismatch for %s\n' "$fixture_id" >&2; exit 1; }
        fi
    done < "$trace_manifest_file"
fi

printf 'Alpine pin checks passed at %s for eight immutable fixtures\n' "$commit"
