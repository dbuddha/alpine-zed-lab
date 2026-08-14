#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

test_dir=$(mktemp -d /tmp/alpine-zed-policy.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

cp pins/zed.toml "$test_dir/zed.toml"
PIN_FILE="$test_dir/zed.toml" scripts/check-pin.sh >/dev/null

sed 's/e17dc4f9d50db73a458b64dcce50ecd4878b98a3/not-a-sha/' pins/zed.toml > "$test_dir/zed.toml"
if PIN_FILE="$test_dir/zed.toml" scripts/check-pin.sh >/dev/null 2>&1; then
    printf 'invalid commit fixture unexpectedly passed\n' >&2
    exit 1
fi

sed '/^schema =/p' pins/zed.toml > "$test_dir/duplicate-schema.toml"
cat pins/zed.toml >> "$test_dir/duplicate-schema.toml"
if PIN_FILE="$test_dir/duplicate-schema.toml" scripts/check-pin.sh >/dev/null 2>&1; then
    printf 'duplicate field fixture unexpectedly passed\n' >&2
    exit 1
fi

cp pins/zed.toml "$test_dir/unknown-field.toml"
printf 'unreviewed = "value"\n' >> "$test_dir/unknown-field.toml"
if PIN_FILE="$test_dir/unknown-field.toml" scripts/check-pin.sh >/dev/null 2>&1; then
    printf 'unknown field fixture unexpectedly passed\n' >&2
    exit 1
fi

sed 's/tag = "v1.15.0"/tag = "main"/' pins/zed.toml > "$test_dir/mutable-tag.toml"
if PIN_FILE="$test_dir/mutable-tag.toml" scripts/check-pin.sh >/dev/null 2>&1; then
    printf 'mutable tag fixture unexpectedly passed\n' >&2
    exit 1
fi

sed 's|repository = "https://github.com/zed-industries/zed.git"|repository = "https://example.invalid/zed.git"|' pins/zed.toml > "$test_dir/wrong-remote.toml"
if PIN_FILE="$test_dir/wrong-remote.toml" scripts/check-pin.sh >/dev/null 2>&1; then
    printf 'wrong remote fixture unexpectedly passed\n' >&2
    exit 1
fi

mkdir -p "$test_dir/patches/upstream" "$test_dir/patches/alpine-metal"
printf 'fixture\n' > "$test_dir/patches/valid.patch"
valid_hash=$(shasum -a 256 "$test_dir/patches/valid.patch" | awk '{ print $1 }')
printf '%s %s\n' "$valid_hash" patches/valid.patch > "$test_dir/patches/upstream/series"
: > "$test_dir/patches/alpine-metal/series"
LAB_ROOT="$test_dir" scripts/check-series.sh >/dev/null

printf '%s %s\n' "$valid_hash" patches/../escaped.patch > "$test_dir/patches/upstream/series"
if LAB_ROOT="$test_dir" scripts/check-series.sh >/dev/null 2>&1; then
    printf 'unsafe patch path fixture unexpectedly passed\n' >&2
    exit 1
fi

printf '%064d %s\n' 0 patches/valid.patch > "$test_dir/patches/upstream/series"
if LAB_ROOT="$test_dir" scripts/check-series.sh >/dev/null 2>&1; then
    printf 'patch fingerprint mismatch fixture unexpectedly passed\n' >&2
    exit 1
fi

boundary_root="$test_dir/boundary"
mkdir -p "$boundary_root/patches/upstream" "$boundary_root/patches/alpine-metal"
printf '.lab/\nartifacts/\n' > "$boundary_root/.gitignore"
: > "$boundary_root/patches/upstream/series"
: > "$boundary_root/patches/alpine-metal/series"
git -C "$boundary_root" init -q
git -C "$boundary_root" add .gitignore patches
LAB_ROOT="$boundary_root" scripts/check-license-boundary.sh >/dev/null

mkdir -p "$boundary_root/vendor/zed"
printf 'forbidden\n' > "$boundary_root/vendor/zed/source.rs"
git -C "$boundary_root" add vendor/zed/source.rs
if LAB_ROOT="$boundary_root" scripts/check-license-boundary.sh >/dev/null 2>&1; then
    printf 'tracked Zed source fixture unexpectedly passed\n' >&2
    exit 1
fi

git -C "$boundary_root" rm --cached -r -q vendor
mkdir -p "$boundary_root/artifacts"
printf 'forbidden\n' > "$boundary_root/artifacts/result.json"
git -C "$boundary_root" add -f artifacts/result.json
if LAB_ROOT="$boundary_root" scripts/check-license-boundary.sh >/dev/null 2>&1; then
    printf 'tracked generated artifact fixture unexpectedly passed\n' >&2
    exit 1
fi

printf 'policy regression tests passed\n'
