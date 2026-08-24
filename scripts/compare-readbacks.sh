#!/bin/sh
set -eu

max_channel_delta=0
if [ "${1:-}" = "--max-channel-delta" ]; then
    [ "$#" -ge 2 ] || { printf 'missing maximum channel delta\n' >&2; exit 2; }
    max_channel_delta=$2
    shift 2
fi

if [ "$#" -lt 3 ]; then
    printf 'usage: %s [--max-channel-delta 0..255] EXPECTED_BYTES REFERENCE_BGRA CANDIDATE_BGRA [CANDIDATE_BGRA...]\n' "$0" >&2
    exit 2
fi

case "$max_channel_delta" in *[!0-9]*|'') printf 'maximum channel delta must be an integer\n' >&2; exit 1 ;; esac
[ "$max_channel_delta" -le 255 ] || { printf 'maximum channel delta must not exceed 255\n' >&2; exit 1; }

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

max_observed_channel_delta=0
for candidate in "$@"; do
    candidate_delta=$(
        (cmp -l "$reference_readback" "$candidate" || true) | awk '
            function octal(value, result, position) {
                result = 0
                for (position = 1; position <= length(value); position += 1) {
                    result = result * 8 + substr(value, position, 1)
                }
                return result
            }
            {
                delta = octal($2) - octal($3)
                if (delta < 0) delta = -delta
                if (delta > maximum) maximum = delta
            }
            END { print maximum + 0 }
        '
    )
    [ "$candidate_delta" -le "$max_channel_delta" ] || {
        printf 'readback %s differs from reference %s by %s channel units, limit is %s\n' \
            "$candidate" "$reference_readback" "$candidate_delta" "$max_channel_delta" >&2
        exit 1
    }
    if [ "$candidate_delta" -gt "$max_observed_channel_delta" ]; then
        max_observed_channel_delta=$candidate_delta
    fi
done

readback_sha256=$(shasum -a 256 "$reference_readback" | awk '{ print $1 }')
printf 'compact BGRA8 equivalence passed reference_sha256=%s max_channel_delta=%s max_observed_channel_delta=%s\n' \
    "$readback_sha256" "$max_channel_delta" "$max_observed_channel_delta"
