#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

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
tag=$(pin_value tag)
commit=$(pin_value commit)
application_license=$(pin_value application_license)
application_manifest_path=$(pin_value application_manifest_path)
license_path=$(pin_value license_path)
license_sha256=$(pin_value license_sha256)

expected_keys='application_license
application_manifest_path
commit
license_path
license_sha256
repository
schema
tag'
actual_keys=$(awk -F '[[:space:]]*=[[:space:]]*' '
    /^[[:space:]]*($|#)/ { next }
    NF != 2 { print "<invalid>"; next }
    { print $1 }
' "$pin_file" | sort)
[ "$actual_keys" = "$expected_keys" ] || {
    printf 'pin schema fields differ from alpine-zed-pin/v1\n' >&2
    exit 1
}

[ "$schema" = "alpine-zed-pin/v1" ] || { printf 'unsupported pin schema: %s\n' "$schema" >&2; exit 1; }
[ "$repository" = "https://github.com/zed-industries/zed.git" ] || { printf 'unexpected Zed repository: %s\n' "$repository" >&2; exit 1; }
printf '%s\n' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || { printf 'Zed tag must be stable SemVer: %s\n' "$tag" >&2; exit 1; }
[ "$application_license" = "GPL-3.0-or-later" ] || { printf 'unexpected application license: %s\n' "$application_license" >&2; exit 1; }
[ "$application_manifest_path" = "crates/zed/Cargo.toml" ] || { printf 'unexpected application manifest: %s\n' "$application_manifest_path" >&2; exit 1; }
[ "$license_path" = "LICENSE-GPL" ] || { printf 'unexpected upstream license path: %s\n' "$license_path" >&2; exit 1; }

case "$commit" in
    *[!0-9a-f]*|'') printf 'Zed commit must be a lowercase hexadecimal SHA\n' >&2; exit 1 ;;
esac
[ "${#commit}" -eq 40 ] || { printf 'Zed commit must contain 40 hexadecimal characters\n' >&2; exit 1; }

case "$license_sha256" in
    *[!0-9a-f]*|'') printf 'license hash must be lowercase hexadecimal\n' >&2; exit 1 ;;
esac
[ "${#license_sha256}" -eq 64 ] || { printf 'license hash must contain 64 hexadecimal characters\n' >&2; exit 1; }

if [ "$network" = true ]; then
    resolved=$(git ls-remote "$repository" "refs/tags/$tag" "refs/tags/$tag^{}" | awk -v tag="refs/tags/$tag" '
        $2 == tag { direct = $1 }
        $2 == tag "^{}" { peeled = $1 }
        END {
            if (peeled != "") print peeled
            else print direct
        }
    ')
    [ "$resolved" = "$commit" ] || {
        printf 'tag %s resolved to %s, expected %s\n' "$tag" "${resolved:-missing}" "$commit" >&2
        exit 1
    }
    remote_license_sha256=$(curl -fsSL "https://raw.githubusercontent.com/zed-industries/zed/$commit/$license_path" | shasum -a 256 | awk '{ print $1 }')
    [ "$remote_license_sha256" = "$license_sha256" ] || { printf 'remote upstream license fingerprint mismatch\n' >&2; exit 1; }
    remote_application_license=$(curl -fsSL "https://raw.githubusercontent.com/zed-industries/zed/$commit/$application_manifest_path" | awk -F '[[:space:]]*=[[:space:]]*' '$1 == "license" { gsub(/^"|"$/, "", $2); print $2 }')
    [ "$remote_application_license" = "$application_license" ] || { printf 'remote Zed application license declaration mismatch\n' >&2; exit 1; }
fi

if [ -e .lab/zed ] || [ -L .lab/zed ]; then
    [ ! -L .lab/zed ] || { printf '.lab/zed must not be a symbolic link\n' >&2; exit 1; }
    [ -d .lab/zed/.git ] || { printf '.lab/zed is not a standalone Git checkout\n' >&2; exit 1; }
    checkout_commit=$(git -C .lab/zed rev-parse HEAD)
    checkout_remote=$(git -C .lab/zed remote get-url origin)
    checkout_tag_commit=$(git -C .lab/zed rev-parse "refs/tags/$tag^{commit}")
    [ "$checkout_commit" = "$commit" ] || { printf 'checkout is at %s, expected %s\n' "$checkout_commit" "$commit" >&2; exit 1; }
    [ "$checkout_tag_commit" = "$commit" ] || { printf 'checkout tag resolves to %s, expected %s\n' "$checkout_tag_commit" "$commit" >&2; exit 1; }
    [ "$checkout_remote" = "$repository" ] || { printf 'checkout origin is %s, expected %s\n' "$checkout_remote" "$repository" >&2; exit 1; }
    if git -C .lab/zed symbolic-ref -q HEAD >/dev/null; then
        printf 'checkout HEAD must remain detached\n' >&2
        exit 1
    fi
    [ -z "$(git -C .lab/zed status --porcelain)" ] || { printf 'base Zed checkout must remain clean\n' >&2; exit 1; }
    [ -f ".lab/zed/$license_path" ] || { printf 'checkout lacks %s\n' "$license_path" >&2; exit 1; }
    [ -f ".lab/zed/$application_manifest_path" ] || { printf 'checkout lacks %s\n' "$application_manifest_path" >&2; exit 1; }
    checkout_license_sha256=$(shasum -a 256 ".lab/zed/$license_path" | awk '{ print $1 }')
    [ "$checkout_license_sha256" = "$license_sha256" ] || { printf 'upstream license fingerprint mismatch\n' >&2; exit 1; }
    checkout_application_license=$(awk -F '[[:space:]]*=[[:space:]]*' '$1 == "license" { gsub(/^"|"$/, "", $2); print $2 }' ".lab/zed/$application_manifest_path")
    [ "$checkout_application_license" = "$application_license" ] || { printf 'Zed application license declaration mismatch\n' >&2; exit 1; }
fi

printf 'Zed pin checks passed for %s at %s\n' "$tag" "$commit"
