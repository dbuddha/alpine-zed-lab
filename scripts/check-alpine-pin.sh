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
scene_trace_path=$(pin_value scene_trace_path)
scene_trace_sha256=$(pin_value scene_trace_sha256)
workload_hash=$(pin_value workload_hash)

expected_keys='commit
repository
scene_trace_path
scene_trace_sha256
schema
visibility
workload_hash'
actual_keys=$(awk -F '[[:space:]]*=[[:space:]]*' '
    /^[[:space:]]*($|#)/ { next }
    NF != 2 { print "<invalid>"; next }
    { print $1 }
' "$PIN_FILE" | sort)
[ "$actual_keys" = "$expected_keys" ] || {
    printf 'Alpine pin schema fields differ from alpine-revision-pin/v1\n' >&2
    exit 1
}

[ "$schema" = "alpine-revision-pin/v1" ] || { printf 'unsupported Alpine pin schema: %s\n' "$schema" >&2; exit 1; }
[ "$repository" = "https://github.com/dbuddha/alpine-gpui.git" ] || { printf 'unexpected Alpine repository: %s\n' "$repository" >&2; exit 1; }
[ "$visibility" = "public-proprietary" ] || { printf 'unexpected Alpine visibility boundary: %s\n' "$visibility" >&2; exit 1; }
[ "$scene_trace_path" = "assurance/qualification/v1/scene.toml" ] || { printf 'unexpected Alpine scene trace path: %s\n' "$scene_trace_path" >&2; exit 1; }

case "$scene_trace_path" in /*|*..*|*//*|*\\*) printf 'unsafe Alpine scene trace path: %s\n' "$scene_trace_path" >&2; exit 1 ;; esac
case "$commit" in *[!0-9a-f]*|'') printf 'commit must be a lowercase hexadecimal SHA\n' >&2; exit 1 ;; esac
[ "${#commit}" -eq 40 ] || { printf 'commit must contain 40 hexadecimal characters\n' >&2; exit 1; }
for value in "$scene_trace_sha256" "$workload_hash"; do
    case "$value" in *[!0-9a-f]*|'') printf 'trace identities must be lowercase hexadecimal\n' >&2; exit 1 ;; esac
    [ "${#value}" -eq 64 ] || { printf 'trace identities must contain 64 hexadecimal characters\n' >&2; exit 1; }
done

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
    [ -f ".lab/alpine/$scene_trace_path" ] || { printf 'Alpine checkout lacks %s\n' "$scene_trace_path" >&2; exit 1; }
    checkout_trace_sha256=$(shasum -a 256 ".lab/alpine/$scene_trace_path" | awk '{ print $1 }')
    [ "$checkout_trace_sha256" = "$scene_trace_sha256" ] || { printf 'Alpine scene trace fingerprint mismatch\n' >&2; exit 1; }
    declared_workload_hash=$(sed -nE 's/^workload_hash = "([0-9a-f]{64})"$/\1/p' ".lab/alpine/$scene_trace_path")
    [ "$declared_workload_hash" = "$workload_hash" ] || { printf 'Alpine scene trace workload identity mismatch\n' >&2; exit 1; }
    canonical_workload_hash=$(sed '/^workload_hash = /d' ".lab/alpine/$scene_trace_path" | shasum -a 256 | awk '{ print $1 }')
    [ "$canonical_workload_hash" = "$workload_hash" ] || { printf 'Alpine scene trace canonical hash mismatch\n' >&2; exit 1; }
fi

printf 'Alpine pin checks passed at %s for workload %s\n' "$commit" "$workload_hash"
