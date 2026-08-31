#!/bin/sh
set -eu

fail() {
    printf 'physical sampler build error: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 3 ] || fail 'expected OUTPUT ORACLE_DIRECTORY WORKFLOW_RUN_ID'
output=$1
oracle=$2
workflow_run_id=$3
case "$output" in artifacts/*) ;; *) fail 'output must be beneath artifacts' ;; esac
case "$workflow_run_id" in ''|*[!0-9]*) fail 'workflow run id must be numeric' ;; esac
[ ! -e "$output" ] && [ ! -L "$output" ] || fail 'output already exists'
[ -d "$oracle" ] && [ ! -L "$oracle" ] || fail 'oracle directory is missing or symbolic'
[ "$(uname -s)" = Darwin ] || fail 'bundle construction requires macOS'
[ "$(uname -m)" = arm64 ] || fail 'bundle construction requires arm64'
command -v xcrun >/dev/null 2>&1 || fail 'xcrun is required'
xcrun --sdk macosx --find metal >/dev/null 2>&1 || fail 'offline Metal compiler is required'
xcrun --sdk macosx --find metallib >/dev/null 2>&1 || fail 'offline metallib compiler is required'

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"
lab_revision=$(git rev-parse HEAD)
[ -z "$(git status --porcelain)" ] || fail 'lab checkout must be clean'
workflow_sha=${GITHUB_SHA:-$lab_revision}
[ "$workflow_sha" = "$lab_revision" ] || fail 'workflow source identity differs from lab checkout'

toml_value() {
    file=$1
    key=$2
    sed -nE "s/^${key} = \"([^\"]*)\"$/\\1/p" "$file"
}

hash_file() {
    shasum -a 256 "$1" | awk '{ print $1 }'
}

alpine_revision=$(toml_value pins/alpine.toml commit)
zed_revision=$(toml_value pins/zed.toml commit)
trace_manifest_sha256=$(toml_value pins/alpine.toml trace_manifest_sha256)
for identity in "$lab_revision" "$alpine_revision" "$zed_revision" "$trace_manifest_sha256"; do
    case "$identity" in *[!0-9a-f]*|'') fail 'source identity is not lowercase hexadecimal' ;; esac
done
[ "${#lab_revision}" -eq 40 ] || fail 'lab revision length drifted'
[ "${#alpine_revision}" -eq 40 ] || fail 'Alpine revision length drifted'
[ "${#zed_revision}" -eq 40 ] || fail 'Zed revision length drifted'
[ "${#trace_manifest_sha256}" -eq 64 ] || fail 'trace manifest hash length drifted'

oracle_set="$oracle/qualification-set.toml"
oracle_equivalence="$oracle/realistic-code-viewport/equivalence.log"
oracle_cpu="$oracle/realistic-code-viewport/cpu-oracle.bgra"
oracle_gpui="$oracle/realistic-code-viewport/gpui-metal.bgra"
for file in "$oracle_set" "$oracle_equivalence" "$oracle_cpu" "$oracle_gpui"; do
    [ -f "$file" ] && [ ! -L "$file" ] || fail "oracle evidence is missing or symbolic: $file"
done
[ "$(toml_value "$oracle_set" schema)" = alpine-renderer-equivalence-set/v2 ] || fail 'oracle schema drifted'
[ "$(toml_value "$oracle_set" state)" = gpui-oracle-equivalent ] || fail 'oracle state is not equivalent'
[ "$(toml_value "$oracle_set" lab_revision)" = "$lab_revision" ] || fail 'oracle lab revision drifted'
[ "$(toml_value "$oracle_set" alpine_revision)" = "$alpine_revision" ] || fail 'oracle Alpine revision drifted'
[ "$(toml_value "$oracle_set" zed_revision)" = "$zed_revision" ] || fail 'oracle Zed revision drifted'
[ "$(toml_value "$oracle_set" trace_manifest_sha256)" = "$trace_manifest_sha256" ] || fail 'oracle trace manifest drifted'
[ "$(toml_value "$oracle_set" shader_mode)" = offline-metallib ] || fail 'oracle did not use offline metallib shaders'
[ "$(toml_value "$oracle_set" performance_qualified)" = false ] || fail 'oracle unexpectedly claims performance qualification'
patch_series_sha256=$(toml_value "$oracle_set" patch_series_sha256)
case "$patch_series_sha256" in *[!0-9a-f]*|'') fail 'oracle patch-series identity is invalid' ;; esac
[ "${#patch_series_sha256}" -eq 64 ] || fail 'oracle patch-series identity length drifted'

trace_row=$(awk -F '\t' '$1 == "realistic-code-viewport" { print; found++ } END { if (found != 1) exit 1 }' pins/alpine-traces.tsv) || fail 'realistic code viewport trace row is not unique'
tab=$(printf '\t')
IFS="$tab" read -r trace_id trace_schema trace_path trace_sha256 workload_hash _rest <<EOF
$trace_row
EOF
[ "$trace_schema" = alpine-scene-trace/v2 ] || fail 'physical trace must use scene schema v2'
trace_source=".lab/alpine/$trace_path"
[ -f "$trace_source" ] && [ ! -L "$trace_source" ] || fail 'pinned physical trace is missing'
[ "$(hash_file "$trace_source")" = "$trace_sha256" ] || fail 'pinned physical trace bytes drifted'

scripts/check-pin.sh
scripts/check-alpine-pin.sh
scripts/check-adapter-patch.sh

work_root=$(mktemp -d .lab/physical-sampler.XXXXXX)
variant_checkout="$work_root/zed"
target_root="$work_root/target"
candidate="$work_root/candidate"
bundle="$candidate/physical-samplers"
cleanup() {
    if [ -d "$variant_checkout" ]; then
        git -C .lab/zed worktree remove --force "$variant_checkout" >/dev/null 2>&1 || true
    fi
    rm -rf "$work_root"
}
trap cleanup EXIT HUP INT TERM

git -C .lab/zed worktree add --detach "$variant_checkout" "$zed_revision" >/dev/null
while IFS=' ' read -r expected_hash patch_path extra; do
    case "$expected_hash" in ''|'#'*) continue ;; esac
    [ -z "${extra:-}" ] || fail 'adapter patch series entry has extra fields'
    [ "$(hash_file "$patch_path")" = "$expected_hash" ] || fail "adapter patch hash drifted: $patch_path"
    git -C "$variant_checkout" apply --check "$repo_root/$patch_path"
    git -C "$variant_checkout" apply "$repo_root/$patch_path"
done < patches/alpine-metal/series
git -C "$variant_checkout" diff --check

zed_toolchain=$(sed -nE 's/^channel = "([^"]+)"$/\1/p' "$variant_checkout/rust-toolchain.toml")
alpine_toolchain=$(sed -nE 's/^channel = "([^"]+)"$/\1/p' .lab/alpine/rust-toolchain.toml)
[ -n "$zed_toolchain" ] && [ -n "$alpine_toolchain" ] || fail 'pinned Rust toolchain is missing'

CARGO_TARGET_DIR="$target_root/zed" cargo "+$zed_toolchain" build \
    --release --locked --manifest-path "$variant_checkout/Cargo.toml" \
    -p alpine_trace_adapter
CARGO_TARGET_DIR="$target_root/alpine" cargo "+$alpine_toolchain" build \
    --release --locked --manifest-path .lab/alpine/Cargo.toml \
    -p alpine-assurance

gpui_binary="$target_root/zed/release/alpine_trace_adapter"
alpine_binary="$target_root/alpine/release/alpine-assurance"
[ -x "$gpui_binary" ] && [ -x "$alpine_binary" ] || fail 'release sampler executable is missing'
gpui_metallibs=$(find "$target_root/zed/release/build" -type f -path '*/out/shaders.metallib' -print)
[ "$(printf '%s\n' "$gpui_metallibs" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ] || fail 'expected exactly one generated GPUI metallib'
gpui_metallib=$gpui_metallibs
alpine_metallib=.lab/alpine/shaders/offscreen.metallib
[ -f "$alpine_metallib" ] && [ ! -L "$alpine_metallib" ] || fail 'pinned Alpine metallib is missing'

mkdir -p "$bundle/bin" "$bundle/oracle/realistic-code-viewport" "$bundle/provenance" "$bundle/source/patches"
cp "$alpine_binary" "$bundle/bin/alpine-assurance"
cp "$gpui_binary" "$bundle/bin/alpine-trace-adapter"
chmod 755 "$bundle/bin/alpine-assurance" "$bundle/bin/alpine-trace-adapter"
cp "$alpine_metallib" "$bundle/provenance/alpine-offscreen.metallib"
cp "$gpui_metallib" "$bundle/provenance/gpui-shaders.metallib"
cp "$oracle_set" "$bundle/oracle/qualification-set.toml"
cp "$oracle_equivalence" "$bundle/oracle/realistic-code-viewport/equivalence.log"
cp "$oracle_cpu" "$bundle/oracle/realistic-code-viewport/cpu-oracle.bgra"
cp "$oracle_gpui" "$bundle/oracle/realistic-code-viewport/gpui-metal.bgra"
cp "$trace_source" "$bundle/source/realistic-code-viewport.toml"
cp pins/alpine.toml "$bundle/source/alpine.toml"
cp pins/zed.toml "$bundle/source/zed.toml"
cp patches/alpine-metal/series "$bundle/source/series"
cp patches/alpine-metal/0001-add-gpui-scene-trace-adapter.patch "$bundle/source/patches/0001.patch"
cp patches/alpine-metal/0002-add-gpui-renderer-sampling.patch "$bundle/source/patches/0002.patch"
cargo "+$alpine_toolchain" rustc -Vv > "$bundle/provenance/alpine-rustc.txt"
cargo "+$zed_toolchain" rustc -Vv > "$bundle/provenance/zed-rustc.txt"
xcodebuild -version > "$bundle/provenance/xcode.txt"
xcrun --sdk macosx --show-sdk-version > "$bundle/provenance/sdk.txt"
sw_vers > "$bundle/provenance/macos.txt"

cat > "$bundle/manifest.toml" <<EOF
schema = "alpine-zed-physical-sampler-bundle/v1"
candidate = true
lab_revision = "$lab_revision"
workflow_sha = "$workflow_sha"
workflow_run_id = "$workflow_run_id"
alpine_revision = "$alpine_revision"
zed_revision = "$zed_revision"
patch_series_sha256 = "$patch_series_sha256"
trace_manifest_sha256 = "$trace_manifest_sha256"
trace_id = "$trace_id"
trace_schema = "$trace_schema"
workload_hash = "$workload_hash"
architecture = "arm64"
build_profile = "release"
shader_mode = "offline-metallib"
alpine_sampler_path = "bin/alpine-assurance"
alpine_sampler_sha256 = "$(hash_file "$bundle/bin/alpine-assurance")"
gpui_sampler_path = "bin/alpine-trace-adapter"
gpui_sampler_sha256 = "$(hash_file "$bundle/bin/alpine-trace-adapter")"
alpine_metallib_path = "provenance/alpine-offscreen.metallib"
alpine_metallib_sha256 = "$(hash_file "$bundle/provenance/alpine-offscreen.metallib")"
gpui_metallib_path = "provenance/gpui-shaders.metallib"
gpui_metallib_sha256 = "$(hash_file "$bundle/provenance/gpui-shaders.metallib")"
oracle_set_path = "oracle/qualification-set.toml"
oracle_set_sha256 = "$(hash_file "$bundle/oracle/qualification-set.toml")"
oracle_equivalence_path = "oracle/realistic-code-viewport/equivalence.log"
oracle_equivalence_sha256 = "$(hash_file "$bundle/oracle/realistic-code-viewport/equivalence.log")"
oracle_cpu_path = "oracle/realistic-code-viewport/cpu-oracle.bgra"
oracle_cpu_sha256 = "$(hash_file "$bundle/oracle/realistic-code-viewport/cpu-oracle.bgra")"
oracle_gpui_path = "oracle/realistic-code-viewport/gpui-metal.bgra"
oracle_gpui_sha256 = "$(hash_file "$bundle/oracle/realistic-code-viewport/gpui-metal.bgra")"
trace_path = "source/realistic-code-viewport.toml"
trace_sha256 = "$(hash_file "$bundle/source/realistic-code-viewport.toml")"
alpine_pin_path = "source/alpine.toml"
alpine_pin_sha256 = "$(hash_file "$bundle/source/alpine.toml")"
zed_pin_path = "source/zed.toml"
zed_pin_sha256 = "$(hash_file "$bundle/source/zed.toml")"
patch_series_path = "source/series"
patch_series_file_sha256 = "$(hash_file "$bundle/source/series")"
patch_one_path = "source/patches/0001.patch"
patch_one_sha256 = "$(hash_file "$bundle/source/patches/0001.patch")"
patch_two_path = "source/patches/0002.patch"
patch_two_sha256 = "$(hash_file "$bundle/source/patches/0002.patch")"
alpine_rustc_path = "provenance/alpine-rustc.txt"
alpine_rustc_sha256 = "$(hash_file "$bundle/provenance/alpine-rustc.txt")"
zed_rustc_path = "provenance/zed-rustc.txt"
zed_rustc_sha256 = "$(hash_file "$bundle/provenance/zed-rustc.txt")"
xcode_path = "provenance/xcode.txt"
xcode_sha256 = "$(hash_file "$bundle/provenance/xcode.txt")"
sdk_path = "provenance/sdk.txt"
sdk_sha256 = "$(hash_file "$bundle/provenance/sdk.txt")"
macos_path = "provenance/macos.txt"
macos_sha256 = "$(hash_file "$bundle/provenance/macos.txt")"
ci_pass_required = true
timing_performed = false
memory_performed = false
performance_qualified = false
performance_claim = "none"
EOF

tar -cf "$candidate/physical-samplers.tar" -C "$candidate" physical-samplers
archive_bytes=$(wc -c < "$candidate/physical-samplers.tar" | tr -d ' ')
[ "$archive_bytes" -gt 0 ] && [ "$archive_bytes" -le 536870912 ] || fail 'candidate archive size is outside the 512 MiB bound'
(cd "$candidate" && shasum -a 256 physical-samplers.tar > physical-samplers.tar.sha256)
mkdir -p "$(dirname "$output")"
mv "$candidate" "$output"
printf 'built physical sampler candidate for lab=%s run=%s; timing_performed=false performance_claim=none\n' "$lab_revision" "$workflow_run_id"
