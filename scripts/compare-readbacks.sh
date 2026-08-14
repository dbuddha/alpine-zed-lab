#!/bin/sh
set -eu

if [ "$#" -lt 3 ]; then
    printf 'usage: %s EXPECTED_BYTES REFERENCE_BGRA CANDIDATE_BGRA [CANDIDATE_BGRA...]\n' "$0" >&2
    exit 2
fi

expected_bytes=$1
reference_readback=$2
shift 2

case "$expected_bytes" in *[!0-9]*|'') printf 'expected byte count must be a positive integer\n' >&2; exit 1 ;; esac
[ "$expected_bytes" -gt 0 ] || { printf 'expected byte count must be positive\n' >&2; exit 1; }

for readback in "$reference_readback" "$@"; do
    [ -f "$readback" ] && [ ! -L "$readback" ] || { printf 'missing regular readback: %s\n' "$readback" >&2; exit 1; }
    actual_bytes=$(wc -c < "$readback" | tr -d '[:space:]')
    [ "$actual_bytes" = "$expected_bytes" ] || {
        printf 'readback %s has %s bytes, expected %s\n' "$readback" "$actual_bytes" "$expected_bytes" >&2
        exit 1
    }
done

for candidate in "$@"; do
    cmp -s "$reference_readback" "$candidate" || {
        printf 'readback %s differs from reference %s\n' "$candidate" "$reference_readback" >&2
        exit 1
    }
done

readback_sha256=$(shasum -a 256 "$reference_readback" | awk '{ print $1 }')
printf 'exact compact BGRA8 equivalence passed at %s\n' "$readback_sha256"
