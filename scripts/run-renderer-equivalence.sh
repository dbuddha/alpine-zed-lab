#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

mode=full
if [ "${1:-}" = "--adapter-only" ]; then
    mode=adapter-only
    shift
fi
if [ "$#" -ne 1 ]; then
    printf 'usage: %s [--adapter-only] artifacts/OUTPUT_DIRECTORY\n' "$0" >&2
    exit 2
fi

output_dir=$1
case "$output_dir" in
    artifacts/*) ;;
    *) printf 'output directory must be a repository-relative path below artifacts/\n' >&2; exit 1 ;;
esac
case "$output_dir" in *..*|*//*|*\\*) printf 'output directory contains an unsafe component\n' >&2; exit 1 ;; esac
[ ! -e "$output_dir" ] && [ ! -L "$output_dir" ] || { printf 'output directory already exists: %s\n' "$output_dir" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || { printf 'renderer equivalence requires macOS\n' >&2; exit 1; }
[ "$(uname -m)" = "arm64" ] || { printf 'renderer equivalence requires Apple Silicon\n' >&2; exit 1; }

scripts/check-pin.sh
scripts/check-alpine-pin.sh
scripts/check-adapter-patch.sh

PIN_FILE=pins/zed.toml
. scripts/lib/pin.sh
zed_commit=$(pin_value commit)
PIN_FILE=pins/alpine.toml
. scripts/lib/pin.sh
alpine_commit=$(pin_value commit)
trace_manifest_path=$(pin_value trace_manifest_path)
trace_manifest_sha256=$(pin_value trace_manifest_sha256)
unset PIN_FILE

trace_manifest="$repo_root/$trace_manifest_path"
output_absolute="$repo_root/$output_dir"
mkdir -p "$output_absolute"

mkdir -p .lab/variants
variant_checkout="$repo_root/.lab/variants/alpine-metal"
[ ! -e "$variant_checkout" ] && [ ! -L "$variant_checkout" ] || {
    printf 'disposable Alpine Metal variant path already exists: %s\n' "$variant_checkout" >&2
    exit 1
}
cleanup() {
    if [ -d "$variant_checkout" ]; then
        git -C .lab/zed worktree remove --force "$variant_checkout" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT HUP INT TERM

git -C .lab/zed worktree add --detach "$variant_checkout" "$zed_commit"
while IFS=' ' read -r expected_hash patch_path extra; do
    case "$expected_hash" in ''|'#'*) continue ;; esac
    [ -z "${extra:-}" ] || { printf 'invalid Alpine adapter series entry\n' >&2; exit 1; }
    git -C "$variant_checkout" apply --check "$repo_root/$patch_path"
    git -C "$variant_checkout" apply "$repo_root/$patch_path"
done < patches/alpine-metal/series
git -C "$variant_checkout" diff --check
zed_toolchain=$(sed -nE 's/^channel = "([^"]+)"$/\1/p' "$variant_checkout/rust-toolchain.toml")
[ -n "$zed_toolchain" ] || { printf 'pinned Zed checkout lacks a Rust toolchain channel\n' >&2; exit 1; }
rustup component add rustfmt clippy --toolchain "$zed_toolchain"

shader_mode=offline-metallib
feature_arguments=
if [ "${ALPINE_ZED_RUNTIME_SHADERS:-0}" = "1" ]; then
    shader_mode=runtime-source-unqualified
    feature_arguments='--features runtime-shaders'
fi

cargo "+$zed_toolchain" fmt \
    --manifest-path "$variant_checkout/Cargo.toml" \
    --package alpine_trace_adapter \
    -- --check
# Intentional word splitting selects one optional Cargo feature argument pair.
# shellcheck disable=SC2086
CARGO_TARGET_DIR="$repo_root/.lab/target/zed-adapter" cargo "+$zed_toolchain" clippy \
    --manifest-path "$variant_checkout/Cargo.toml" \
    --locked \
    -p alpine_trace_adapter \
    --all-targets \
    $feature_arguments \
    -- -D warnings
# Intentional word splitting selects one optional Cargo feature argument pair.
# shellcheck disable=SC2086
CARGO_TARGET_DIR="$repo_root/.lab/target/zed-adapter" cargo "+$zed_toolchain" test \
    --manifest-path "$variant_checkout/Cargo.toml" \
    --locked \
    -p alpine_trace_adapter \
    --all-targets \
    $feature_arguments

coverage_performed=false
coverage_tool_version=not-run
if [ "${ALPINE_ZED_COVERAGE:-0}" = "1" ]; then
    command -v cargo-llvm-cov >/dev/null 2>&1 || {
        printf 'cargo-llvm-cov is required when ALPINE_ZED_COVERAGE=1\n' >&2
        exit 1
    }
    rustup component add llvm-tools-preview --toolchain "$zed_toolchain"
    coverage_tool_version=$(cargo llvm-cov --version | tr ' ' '-')
    # Intentional word splitting selects one optional Cargo feature argument pair.
    # shellcheck disable=SC2086
    CARGO_TARGET_DIR="$repo_root/.lab/target/zed-adapter-coverage" cargo "+$zed_toolchain" llvm-cov \
        --manifest-path "$variant_checkout/Cargo.toml" \
        --locked \
        -p alpine_trace_adapter \
        --lib \
        $feature_arguments \
        --json \
        --summary-only \
        --output-path "$output_absolute/coverage.json" \
        --fail-under-lines 95 \
        --fail-under-functions 90
    coverage_performed=true
fi

mutation_performed=false
mutation_tool_version=not-run
if [ "${ALPINE_ZED_MUTATION:-0}" = "1" ]; then
    command -v cargo-mutants >/dev/null 2>&1 || {
        printf 'cargo-mutants is required when ALPINE_ZED_MUTATION=1\n' >&2
        exit 1
    }
    mutation_tool_version=$(cargo mutants --version | tr ' ' '-')
    # Intentional word splitting selects one optional Cargo feature argument pair.
    # shellcheck disable=SC2086
    cargo "+$zed_toolchain" mutants \
        --manifest-path "$variant_checkout/Cargo.toml" \
        -p alpine_trace_adapter \
        --file 'crates/alpine_trace_adapter/src/lib.rs' \
        --jobs 4 \
        --minimum-test-timeout 20 \
        --output "$output_absolute/mutation" \
        $feature_arguments
    mutation_performed=true
fi

if [ "$mode" = full ]; then
    state=equivalent
    direct_metal_performed=true
else
    state=gpui-oracle-equivalent
    direct_metal_performed=false
fi
patch_series_sha256=$(shasum -a 256 patches/alpine-metal/series | awk '{ print $1 }')
os_version=$(sw_vers -productVersion)
hardware_arch=$(uname -m)
alpine_toolchain=$(sed -nE 's/^channel = "([^"]+)"$/\1/p' "$repo_root/.lab/alpine/rust-toolchain.toml")
[ -n "$alpine_toolchain" ] || { printf 'pinned Alpine checkout lacks a Rust toolchain channel\n' >&2; exit 1; }
alpine_rustc=$(rustc "+$alpine_toolchain" --version | tr ' ' '-')
zed_rustc=$(rustc "+$zed_toolchain" --version | tr ' ' '-')
generated_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
lab_revision=$(scripts/read-lab-revision.sh)

scripts/check-pin.sh
scripts/check-alpine-pin.sh

adapter_value() {
    key=$1
    log=$2
    sed -nE "s/.*(^|[[:space:]])${key}=([^[:space:]]+).*/\\2/p" "$log"
}

fixture_count=0
pending_manifests=
tab=$(printf '\t')
while IFS="$tab" read -r fixture_id trace_schema trace_path scene_trace_sha256 workload_hash pair_id pair_kind pair_sequence_hash pair_step pair_steps; do
    case "$fixture_id" in ''|'#'*) continue ;; esac
    trace="$repo_root/.lab/alpine/$trace_path"
    fixture_dir="$output_absolute/$fixture_id"
    mkdir -p "$fixture_dir"

    CARGO_TARGET_DIR="$repo_root/.lab/target/alpine" cargo run \
        --manifest-path "$repo_root/.lab/alpine/Cargo.toml" \
        --locked \
        -p alpine-assurance \
        -- render-scene-reference "$trace" "$fixture_dir/cpu-oracle.bgra" \
        > "$fixture_dir/cpu-oracle.log"
    if [ "$mode" = full ]; then
        CARGO_TARGET_DIR="$repo_root/.lab/target/alpine" cargo run \
            --manifest-path "$repo_root/.lab/alpine/Cargo.toml" \
            --locked \
            -p alpine-assurance \
            -- render-scene-native "$trace" "$fixture_dir/alpine-metal.bgra" \
            > "$fixture_dir/alpine-metal.log"
    fi
    # Intentional word splitting selects one optional Cargo feature argument pair.
    # shellcheck disable=SC2086
    CARGO_TARGET_DIR="$repo_root/.lab/target/zed-adapter" cargo "+$zed_toolchain" run \
        --manifest-path "$variant_checkout/Cargo.toml" \
        --locked \
        -p alpine_trace_adapter \
        $feature_arguments \
        -- "$trace" "$fixture_dir/gpui-metal.bgra" \
        > "$fixture_dir/gpui-metal.log"

    pixel_width=$(sed -nE 's/^pixel_width = ([0-9]+)$/\1/p' "$trace")
    pixel_height=$(sed -nE 's/^pixel_height = ([0-9]+)$/\1/p' "$trace")
    [ -n "$pixel_width" ] && [ -n "$pixel_height" ] || { printf 'trace lacks exact pixel dimensions: %s\n' "$fixture_id" >&2; exit 1; }
    expected_bytes=$((pixel_width * pixel_height * 4))
    if [ "$mode" = full ]; then
        scripts/compare-readbacks.sh --max-channel-delta 1 \
            "$expected_bytes" \
            "$fixture_dir/cpu-oracle.bgra" \
            "$fixture_dir/alpine-metal.bgra" \
            "$fixture_dir/gpui-metal.bgra" \
            > "$fixture_dir/equivalence.log"
        scripts/compare-readbacks.sh \
            "$expected_bytes" \
            "$fixture_dir/alpine-metal.bgra" \
            "$fixture_dir/gpui-metal.bgra" \
            > "$fixture_dir/exact-metal-equivalence.log"
        alpine_sha256=$(shasum -a 256 "$fixture_dir/alpine-metal.bgra" | awk '{ print $1 }')
        exact_metal_equivalence=true
    else
        scripts/compare-readbacks.sh --max-channel-delta 1 \
            "$expected_bytes" \
            "$fixture_dir/cpu-oracle.bgra" \
            "$fixture_dir/gpui-metal.bgra" \
            > "$fixture_dir/equivalence.log"
        alpine_sha256=not-run
        exact_metal_equivalence=false
    fi
    oracle_max_observed_channel_delta=$(sed -nE 's/.*max_observed_channel_delta=([0-9]+).*/\1/p' "$fixture_dir/equivalence.log")
    case "$oracle_max_observed_channel_delta" in ''|*[!0-9]*) printf 'missing oracle delta for %s\n' "$fixture_id" >&2; exit 1 ;; esac
    if [ "$oracle_max_observed_channel_delta" -eq 0 ]; then
        exact_pixel_equivalence=true
    else
        exact_pixel_equivalence=false
    fi

    cpu_sha256=$(shasum -a 256 "$fixture_dir/cpu-oracle.bgra" | awk '{ print $1 }')
    gpui_sha256=$(shasum -a 256 "$fixture_dir/gpui-metal.bgra" | awk '{ print $1 }')
    [ "$(adapter_value trace_schema "$fixture_dir/gpui-metal.log")" = "$trace_schema" ] || { printf 'adapter trace schema drift for %s\n' "$fixture_id" >&2; exit 1; }
    [ "$(adapter_value id "$fixture_dir/gpui-metal.log")" = "$fixture_id" ] || { printf 'adapter trace identifier drift for %s\n' "$fixture_id" >&2; exit 1; }
    [ "$(adapter_value workload_hash "$fixture_dir/gpui-metal.log")" = "$workload_hash" ] || { printf 'adapter workload drift for %s\n' "$fixture_id" >&2; exit 1; }
    [ "$(adapter_value pair_id "$fixture_dir/gpui-metal.log")" = "$pair_id" ] || { printf 'adapter pair identifier drift for %s\n' "$fixture_id" >&2; exit 1; }
    [ "$(adapter_value pair_kind "$fixture_dir/gpui-metal.log")" = "$pair_kind" ] || { printf 'adapter pair kind drift for %s\n' "$fixture_id" >&2; exit 1; }
    [ "$(adapter_value pair_sequence_hash "$fixture_dir/gpui-metal.log")" = "$pair_sequence_hash" ] || { printf 'adapter pair hash drift for %s\n' "$fixture_id" >&2; exit 1; }
    [ "$(adapter_value pair_step "$fixture_dir/gpui-metal.log")" = "$pair_step" ] || { printf 'adapter pair step drift for %s\n' "$fixture_id" >&2; exit 1; }
    [ "$(adapter_value pair_steps "$fixture_dir/gpui-metal.log")" = "$pair_steps" ] || { printf 'adapter pair count drift for %s\n' "$fixture_id" >&2; exit 1; }
    adaptation_clips=$(adapter_value adaptation_clips "$fixture_dir/gpui-metal.log")
    adaptation_operations=$(adapter_value adaptation_operations "$fixture_dir/gpui-metal.log")
    adaptation_quads=$(adapter_value adaptation_quads "$fixture_dir/gpui-metal.log")
    adaptation_glyphs=$(adapter_value adaptation_glyphs "$fixture_dir/gpui-metal.log")
    adaptation_resources=$(adapter_value adaptation_resources "$fixture_dir/gpui-metal.log")
    adaptation_resource_bytes=$(adapter_value adaptation_resource_bytes "$fixture_dir/gpui-metal.log")
    adaptation_atlas_allocations=$(adapter_value adaptation_atlas_allocations "$fixture_dir/gpui-metal.log")
    for value in "$adaptation_clips" "$adaptation_operations" "$adaptation_quads" "$adaptation_glyphs" "$adaptation_resources" "$adaptation_resource_bytes" "$adaptation_atlas_allocations"; do
        case "$value" in ''|*[!0-9]*) printf 'invalid adaptation counter for %s\n' "$fixture_id" >&2; exit 1 ;; esac
    done

    manifest_tmp="$fixture_dir/.qualification.toml.tmp"
    cat > "$manifest_tmp" <<EOF
schema = "alpine-renderer-equivalence/v2"
state = "$state"
comparison_level = "renderer-only"
lab_revision = "$lab_revision"
zed_revision = "$zed_commit"
alpine_revision = "$alpine_commit"
trace_manifest_sha256 = "$trace_manifest_sha256"
trace_schema = "$trace_schema"
trace_id = "$fixture_id"
trace_path = "$trace_path"
scene_trace_sha256 = "$scene_trace_sha256"
workload_hash = "$workload_hash"
pair_id = "$pair_id"
pair_kind = "$pair_kind"
pair_sequence_hash = "$pair_sequence_hash"
pair_step = "$pair_step"
pair_steps = "$pair_steps"
pixel_width = $pixel_width
pixel_height = $pixel_height
pixel_format = "compact-bgra8-premultiplied"
cpu_oracle_sha256 = "$cpu_sha256"
alpine_metal_sha256 = "$alpine_sha256"
gpui_metal_sha256 = "$gpui_sha256"
cpu_oracle_channel_tolerance = 1
cpu_oracle_max_observed_channel_delta = $oracle_max_observed_channel_delta
cpu_oracle_equivalence_within_tolerance = true
exact_pixel_equivalence = $exact_pixel_equivalence
exact_metal_equivalence = $exact_metal_equivalence
direct_metal_performed = $direct_metal_performed
adaptation_clips = $adaptation_clips
adaptation_operations = $adaptation_operations
adaptation_quads = $adaptation_quads
adaptation_glyphs = $adaptation_glyphs
adaptation_resources = $adaptation_resources
adaptation_resource_bytes = $adaptation_resource_bytes
adaptation_atlas_allocations = $adaptation_atlas_allocations
adaptation_timing_performed = false
renderer_timing_performed = false
patch_series_sha256 = "$patch_series_sha256"
shader_mode = "$shader_mode"
adapter_build_profile = "debug"
os_version = "$os_version"
architecture = "$hardware_arch"
alpine_rustc = "$alpine_rustc"
zed_rustc = "$zed_rustc"
coverage_performed = $coverage_performed
coverage_tool_version = "$coverage_tool_version"
mutation_performed = $mutation_performed
mutation_tool_version = "$mutation_tool_version"
generated_at_utc = "$generated_at_utc"
timing_performed = false
memory_performed = false
performance_qualified = false
EOF
    pending_manifests="$pending_manifests $manifest_tmp"
    fixture_count=$((fixture_count + 1))
done < "$trace_manifest"

[ "$fixture_count" -eq 8 ] || { printf 'renderer set must execute eight fixtures\n' >&2; exit 1; }
set_manifest_tmp="$output_absolute/.qualification-set.toml.tmp"
cat > "$set_manifest_tmp" <<EOF
schema = "alpine-renderer-equivalence-set/v2"
state = "$state"
comparison_level = "renderer-only"
lab_revision = "$lab_revision"
zed_revision = "$zed_commit"
alpine_revision = "$alpine_commit"
trace_manifest_path = "$trace_manifest_path"
trace_manifest_sha256 = "$trace_manifest_sha256"
fixture_count = $fixture_count
direct_metal_performed = $direct_metal_performed
cpu_oracle_channel_tolerance = 1
cpu_oracle_equivalence_within_tolerance_all = true
exact_metal_equivalence_all = $direct_metal_performed
patch_series_sha256 = "$patch_series_sha256"
shader_mode = "$shader_mode"
coverage_performed = $coverage_performed
mutation_performed = $mutation_performed
generated_at_utc = "$generated_at_utc"
adaptation_timing_performed = false
renderer_timing_performed = false
memory_performed = false
performance_qualified = false
EOF
for manifest_tmp in $pending_manifests; do
    mv "$manifest_tmp" "${manifest_tmp%.tmp}"
done
mv "$set_manifest_tmp" "$output_absolute/qualification-set.toml"

printf '%s bounded-oracle equivalence set recorded for %s fixtures in %s\n' "$mode" "$fixture_count" "$output_dir/qualification-set.toml"
