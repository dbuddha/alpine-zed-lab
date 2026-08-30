#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

test_dir=$(mktemp -d /tmp/alpine-zed-policy.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

cp pins/zed.toml "$test_dir/zed.toml"
PIN_FILE="$test_dir/zed.toml" scripts/check-pin.sh >/dev/null

cp pins/alpine.toml "$test_dir/alpine.toml"
cp pins/alpine-traces.tsv "$test_dir/alpine-traces.tsv"
ALPINE_PIN_FILE="$test_dir/alpine.toml" scripts/check-alpine-pin.sh >/dev/null

sed 's/665beaa69adb80c6bf34de911aefa6e874813ae1/not-a-sha/' pins/alpine.toml > "$test_dir/invalid-alpine-commit.toml"
if ALPINE_PIN_FILE="$test_dir/invalid-alpine-commit.toml" scripts/check-alpine-pin.sh >/dev/null 2>&1; then
    printf 'invalid Alpine commit fixture unexpectedly passed\n' >&2
    exit 1
fi

cp pins/alpine.toml "$test_dir/unknown-alpine-field.toml"
printf 'unreviewed = "value"\n' >> "$test_dir/unknown-alpine-field.toml"
if ALPINE_PIN_FILE="$test_dir/unknown-alpine-field.toml" scripts/check-alpine-pin.sh >/dev/null 2>&1; then
    printf 'unknown Alpine pin field unexpectedly passed\n' >&2
    exit 1
fi

sed 's|trace_manifest_path = "pins/alpine-traces.tsv"|trace_manifest_path = "../traces.tsv"|' pins/alpine.toml > "$test_dir/unsafe-alpine-path.toml"
if ALPINE_PIN_FILE="$test_dir/unsafe-alpine-path.toml" scripts/check-alpine-pin.sh >/dev/null 2>&1; then
    printf 'unsafe Alpine trace manifest path unexpectedly passed\n' >&2
    exit 1
fi

sed 's|sequence_manifest_path = "assurance/qualification/sequences/atlas-lifecycle-v1.toml"|sequence_manifest_path = "../sequence.toml"|' pins/alpine.toml > "$test_dir/unsafe-alpine-sequence-path.toml"
if ALPINE_PIN_FILE="$test_dir/unsafe-alpine-sequence-path.toml" scripts/check-alpine-pin.sh >/dev/null 2>&1; then
    printf 'unsafe Alpine sequence manifest path unexpectedly passed\n' >&2
    exit 1
fi

cp pins/alpine-traces.tsv "$test_dir/corrupt-alpine-traces.tsv"
printf 'unreviewed\n' >> "$test_dir/corrupt-alpine-traces.tsv"
if ALPINE_TRACE_MANIFEST_FILE="$test_dir/corrupt-alpine-traces.tsv" scripts/check-alpine-pin.sh >/dev/null 2>&1; then
    printf 'corrupt Alpine trace manifest unexpectedly passed\n' >&2
    exit 1
fi

sed 's/afa696780de42292510c3b19bd60602149455fd921ceefc3f6e7f0dcf00b67d4/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' pins/alpine.toml > "$test_dir/wrong-alpine-manifest-hash.toml"
if ALPINE_PIN_FILE="$test_dir/wrong-alpine-manifest-hash.toml" scripts/check-alpine-pin.sh >/dev/null 2>&1; then
    printf 'wrong Alpine trace manifest fingerprint unexpectedly passed\n' >&2
    exit 1
fi

sed 's/12c6a78b4baf93735158cac39cb5b4cf709df42cd30b650b9563c9ec37956e0b/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' pins/alpine.toml > "$test_dir/wrong-alpine-sequence-hash.toml"
if ALPINE_PIN_FILE="$test_dir/wrong-alpine-sequence-hash.toml" scripts/check-alpine-pin.sh >/dev/null 2>&1; then
    printf 'wrong Alpine sequence manifest fingerprint unexpectedly passed\n' >&2
    exit 1
fi

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

printf '\000\001\002\003\004\005\006\007' > "$test_dir/cpu.bgra"
cp "$test_dir/cpu.bgra" "$test_dir/alpine.bgra"
cp "$test_dir/cpu.bgra" "$test_dir/gpui.bgra"
scripts/compare-readbacks.sh 8 "$test_dir/cpu.bgra" "$test_dir/alpine.bgra" "$test_dir/gpui.bgra" >/dev/null
printf '\377' >> "$test_dir/gpui.bgra"
if scripts/compare-readbacks.sh 8 "$test_dir/cpu.bgra" "$test_dir/alpine.bgra" "$test_dir/gpui.bgra" >/dev/null 2>&1; then
    printf 'wrong-length GPUI readback unexpectedly passed\n' >&2
    exit 1
fi
cp "$test_dir/cpu.bgra" "$test_dir/gpui.bgra"
printf '\377' | dd of="$test_dir/gpui.bgra" bs=1 seek=0 conv=notrunc 2>/dev/null
if scripts/compare-readbacks.sh 8 "$test_dir/cpu.bgra" "$test_dir/alpine.bgra" "$test_dir/gpui.bgra" >/dev/null 2>&1; then
    printf 'different GPUI pixels unexpectedly passed\n' >&2
    exit 1
fi
cp "$test_dir/cpu.bgra" "$test_dir/gpui.bgra"
printf '\001' | dd of="$test_dir/gpui.bgra" bs=1 seek=0 conv=notrunc 2>/dev/null
scripts/compare-readbacks.sh --max-channel-delta 1 8 "$test_dir/cpu.bgra" "$test_dir/gpui.bgra" >/dev/null
printf '\002' | dd of="$test_dir/gpui.bgra" bs=1 seek=0 conv=notrunc 2>/dev/null
if scripts/compare-readbacks.sh --max-channel-delta 1 8 "$test_dir/cpu.bgra" "$test_dir/gpui.bgra" >/dev/null 2>&1; then
    printf 'out-of-tolerance GPUI pixels unexpectedly passed\n' >&2
    exit 1
fi

revision_root="$test_dir/revision-root"
mkdir -p "$revision_root"
git -C "$revision_root" init -q
git -C "$revision_root" config user.email test@example.invalid
git -C "$revision_root" config user.name 'Alpine policy test'
printf 'identified\n' > "$revision_root/input.txt"
git -C "$revision_root" add input.txt
git -C "$revision_root" commit -q -m 'test: establish revision fixture'
expected_revision=$(git -C "$revision_root" rev-parse HEAD)
actual_revision=$(LAB_ROOT="$revision_root" scripts/read-lab-revision.sh)
[ "$actual_revision" = "$expected_revision" ] || {
    printf 'clean lab revision did not match its committed fixture\n' >&2
    exit 1
}
printf 'unidentified\n' >> "$revision_root/input.txt"
if LAB_ROOT="$revision_root" scripts/read-lab-revision.sh >/dev/null 2>&1; then
    printf 'dirty lab revision fixture unexpectedly passed\n' >&2
    exit 1
fi

workflow_root="$test_dir/workflows"
mkdir -p "$workflow_root"
cp .github/workflows/*.yml "$workflow_root/"
sed 's/retention-days: 90/retention-days: 7/' \
    .github/workflows/ci.yml > "$workflow_root/ci.yml"
if WORKFLOW_ROOT="$workflow_root" scripts/check-workflows.sh >/dev/null 2>&1; then
    printf 'short qualification retention fixture unexpectedly passed\n' >&2
    exit 1
fi

printf 'policy regression tests passed\n'
