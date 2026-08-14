#!/bin/sh
set -eu

default_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
lab_root=${LAB_ROOT:-$default_root}
cd "$lab_root"

if [ "$#" -eq 0 ]; then
    set -- patches/upstream/series patches/alpine-metal/series
fi

for series in "$@"; do
    [ -f "$series" ] || { printf 'missing patch series: %s\n' "$series" >&2; exit 1; }
    while IFS=' ' read -r expected_hash patch_path extra; do
        case "$expected_hash" in ''|'#'*) continue ;; esac
        [ -z "${extra:-}" ] || { printf '%s has an invalid series entry\n' "$series" >&2; exit 1; }
        case "$expected_hash" in *[!0-9a-f]*|'') printf '%s has an invalid hash\n' "$series" >&2; exit 1 ;; esac
        [ "${#expected_hash}" -eq 64 ] || { printf '%s hash must contain 64 hexadecimal characters\n' "$series" >&2; exit 1; }
        case "$patch_path" in *..*|*//*|*\\*) printf '%s has an unsafe patch path: %s\n' "$series" "$patch_path" >&2; exit 1 ;; esac
        case "$patch_path" in patches/*.patch) ;; *) printf '%s has an invalid patch path: %s\n' "$series" "$patch_path" >&2; exit 1 ;; esac
        [ -f "$patch_path" ] || { printf 'missing patch: %s\n' "$patch_path" >&2; exit 1; }
        actual_hash=$(shasum -a 256 "$patch_path" | awk '{ print $1 }')
        [ "$actual_hash" = "$expected_hash" ] || { printf 'patch fingerprint mismatch: %s\n' "$patch_path" >&2; exit 1; }
    done < "$series"
done

printf 'patch-series checks passed\n'
