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
sequence_manifest_path=$(pin_value sequence_manifest_path)
sequence_manifest_sha256=$(pin_value sequence_manifest_sha256)
unset PIN_FILE

trace_manifest="$repo_root/$trace_manifest_path"
sequence_manifest="$repo_root/.lab/alpine/$sequence_manifest_path"
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
        --dir "$variant_checkout" \
        -p alpine_trace_adapter \
        --file 'crates/alpine_trace_adapter/src/lib.rs' \
        --file 'crates/alpine_trace_adapter/src/sequence.rs' \
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

    manifest_tmp="$fixture_dir/qualification.toml.tmp"
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

if [ "$shader_mode" = offline-metallib ]; then
    sampling_trace_path=$(awk -F "$tab" '$1 == "realistic-code-viewport" { print $3 }' "$trace_manifest")
    [ -n "$sampling_trace_path" ] || { printf 'realistic code viewport sampling trace is missing\n' >&2; exit 1; }
    sampling_trace="$repo_root/.lab/alpine/$sampling_trace_path"
    sampling_dir="$output_absolute/renderer-sampling-smoke"
    mkdir -p "$sampling_dir"
    CARGO_TARGET_DIR="$repo_root/.lab/target/zed-adapter" cargo "+$zed_toolchain" run \
        --manifest-path "$variant_checkout/Cargo.toml" \
        --locked \
        -p alpine_trace_adapter \
        -- --benchmark "$sampling_trace" "$sampling_dir/gpui-metal.csv" 2 3 \
        > "$sampling_dir/gpui-metal.log"
    [ "$(adapter_value schema "$sampling_dir/gpui-metal.log")" = alpine-zed-gpui-renderer-samples/v1 ] || { printf 'GPUI sampling schema drifted\n' >&2; exit 1; }
    [ "$(adapter_value id "$sampling_dir/gpui-metal.log")" = realistic-code-viewport ] || { printf 'GPUI sampling fixture drifted\n' >&2; exit 1; }
    [ "$(adapter_value admission_iterations "$sampling_dir/gpui-metal.log")" = 1 ] || { printf 'GPUI sampling admission count drifted\n' >&2; exit 1; }
    [ "$(adapter_value warmup_iterations "$sampling_dir/gpui-metal.log")" = 2 ] || { printf 'GPUI sampling warmup count drifted\n' >&2; exit 1; }
    [ "$(adapter_value sample_count "$sampling_dir/gpui-metal.log")" = 3 ] || { printf 'GPUI sampling count drifted\n' >&2; exit 1; }
    [ "$(adapter_value measurement_stage "$sampling_dir/gpui-metal.log")" = renderer-submit-readback ] || { printf 'GPUI sampling stage drifted\n' >&2; exit 1; }
    [ "$(adapter_value renderer_timing_performed "$sampling_dir/gpui-metal.log")" = true ] || { printf 'GPUI sampling timing marker drifted\n' >&2; exit 1; }
    [ "$(adapter_value performance_qualified "$sampling_dir/gpui-metal.log")" = false ] || { printf 'GPUI sampling qualification marker drifted\n' >&2; exit 1; }
    awk -F, '
        NR == 1 { if ($1 != "sample_index" || $2 != "elapsed_ns") exit 1; next }
        $1 != NR - 2 || $2 !~ /^[0-9]+$/ || $2 == 0 { exit 1 }
        END { if (NR != 4) exit 1 }
    ' "$sampling_dir/gpui-metal.csv" || { printf 'GPUI sampling CSV drifted\n' >&2; exit 1; }
    CARGO_TARGET_DIR="$repo_root/.lab/target/zed-adapter" cargo "+$zed_toolchain" run \
        --manifest-path "$variant_checkout/Cargo.toml" \
        --locked \
        -p alpine_trace_adapter \
        -- --profile "$sampling_trace" "$sampling_dir/gpui-metal-profile.csv" 2 3 \
        > "$sampling_dir/gpui-metal-profile.log"
    [ "$(adapter_value schema "$sampling_dir/gpui-metal-profile.log")" = alpine-zed-gpui-renderer-profile/v1 ] || { printf 'GPUI profile schema drifted\n' >&2; exit 1; }
    [ "$(adapter_value id "$sampling_dir/gpui-metal-profile.log")" = realistic-code-viewport ] || { printf 'GPUI profile fixture drifted\n' >&2; exit 1; }
    [ "$(adapter_value observer_perturbed "$sampling_dir/gpui-metal-profile.log")" = true ] || { printf 'GPUI profile observer marker drifted\n' >&2; exit 1; }
    [ "$(adapter_value ordinary_samples_unchanged "$sampling_dir/gpui-metal-profile.log")" = true ] || { printf 'GPUI ordinary-sample marker drifted\n' >&2; exit 1; }
    [ "$(adapter_value performance_qualified "$sampling_dir/gpui-metal-profile.log")" = false ] || { printf 'GPUI profile qualification marker drifted\n' >&2; exit 1; }
    awk -F, '
        NR == 1 {
            expected = "sample_index,resource_preparation_ns,instance_write_ns,command_buffer_ns,render_encoding_ns,readback_encoding_performed,readback_encoding_ns,commit_ns,completion_wait_ns,gpu_execution_available,gpu_execution_ns,readback_compaction_ns,total_ns"
            if ($0 != expected) exit 1
            next
        }
        $1 != NR - 2 { exit 1 }
        $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/ { exit 1 }
        $6 != "true" && $6 != "false" { exit 1 }
        $6 == "true" && $7 !~ /^[0-9]+$/ { exit 1 }
        $6 == "false" && $7 != "" { exit 1 }
        $8 !~ /^[0-9]+$/ || $9 !~ /^[0-9]+$/ { exit 1 }
        $10 != "true" && $10 != "false" { exit 1 }
        $10 == "true" && $11 !~ /^[0-9]+$/ { exit 1 }
        $10 == "false" && $11 != "" { exit 1 }
        $12 !~ /^[0-9]+$/ || $13 !~ /^[0-9]+$/ || $13 == 0 { exit 1 }
        END { if (NR != 4) exit 1 }
    ' "$sampling_dir/gpui-metal-profile.csv" || { printf 'GPUI profile CSV drifted\n' >&2; exit 1; }
fi

sequence_dir="$output_absolute/atlas-lifecycle"
mkdir -p "$sequence_dir"
(
    cd "$repo_root/.lab/alpine"
    CARGO_TARGET_DIR="$repo_root/.lab/target/alpine" cargo run \
        --manifest-path Cargo.toml \
        --locked \
        -p alpine-assurance \
        -- validate-trace-sequence "$sequence_manifest_path" \
        > "$sequence_dir/alpine-sequence-validation.log"
)
if [ "$mode" = full ]; then
    (
        cd "$repo_root/.lab/alpine"
        CARGO_TARGET_DIR="$repo_root/.lab/target/alpine" cargo run \
            --manifest-path Cargo.toml \
            --locked \
            -p alpine-assurance \
            -- render-trace-sequence-native \
            "$sequence_manifest_path" \
            "$sequence_dir/alpine-metal-lifecycle.toml" \
            > "$sequence_dir/alpine-metal-lifecycle.log"
    )
    alpine_sequence_sha256=$(shasum -a 256 "$sequence_dir/alpine-metal-lifecycle.toml" | awk '{ print $1 }')
else
    alpine_sequence_sha256=not-run
fi
# Intentional word splitting selects one optional Cargo feature argument pair.
# shellcheck disable=SC2086
CARGO_TARGET_DIR="$repo_root/.lab/target/zed-adapter" cargo "+$zed_toolchain" run \
    --manifest-path "$variant_checkout/Cargo.toml" \
    --locked \
    -p alpine_trace_adapter \
    $feature_arguments \
    -- --sequence "$sequence_manifest" "$repo_root/.lab/alpine" "$sequence_dir/gpui" \
    > "$sequence_dir/gpui-atlas-lifecycle.log"

[ "$(adapter_value visible_steps "$sequence_dir/gpui-atlas-lifecycle.log")" = 5 ] || { printf 'GPUI lifecycle visible-step count drifted\n' >&2; exit 1; }
[ "$(adapter_value renderer_generations "$sequence_dir/gpui-atlas-lifecycle.log")" = 2 ] || { printf 'GPUI lifecycle renderer-generation count drifted\n' >&2; exit 1; }
[ "$(adapter_value atlas_allocations "$sequence_dir/gpui-atlas-lifecycle.log")" = 4 ] || { printf 'GPUI lifecycle allocation count drifted\n' >&2; exit 1; }
[ "$(adapter_value atlas_replacements "$sequence_dir/gpui-atlas-lifecycle.log")" = 2 ] || { printf 'GPUI lifecycle replacement count drifted\n' >&2; exit 1; }

gpui_sequence_evidence="$sequence_dir/gpui/gpui-atlas-lifecycle.toml"
[ -f "$gpui_sequence_evidence" ] || { printf 'GPUI lifecycle evidence is missing\n' >&2; exit 1; }
sequence_rows="$sequence_dir/.gpui-steps.tsv"
awk -F ' = ' '
    function clean(value) { gsub(/^"|"$/, "", value); return value }
    function emit() {
        if (active) print sequence "\t" transition "\t" scene "\t" workload "\t" readback
    }
    /^\[\[steps\]\]$/ { emit(); active = 1; sequence = transition = scene = workload = readback = ""; next }
    active && $1 == "sequence" { sequence = $2; next }
    active && $1 == "transition" { transition = clean($2); next }
    active && $1 == "scene_path" { scene = clean($2); next }
    active && $1 == "workload_hash" { workload = clean($2); next }
    active && $1 == "readback_path" { readback = clean($2); next }
    END { emit() }
' "$gpui_sequence_evidence" > "$sequence_rows"
[ "$(wc -l < "$sequence_rows" | tr -d ' ')" -eq 6 ] || { printf 'GPUI lifecycle evidence must contain six ordered steps\n' >&2; exit 1; }

gpui_sequence_sha256=$(shasum -a 256 "$gpui_sequence_evidence" | awk '{ print $1 }')
sequence_qualification_tmp="$sequence_dir/.qualification.toml.tmp"
cat > "$sequence_qualification_tmp" <<EOF
schema = "alpine-renderer-atlas-lifecycle-equivalence/v1"
state = "$state"
comparison_level = "renderer-only"
lab_revision = "$lab_revision"
zed_revision = "$zed_commit"
alpine_revision = "$alpine_commit"
sequence_manifest_path = "$sequence_manifest_path"
sequence_manifest_sha256 = "$sequence_manifest_sha256"
gpui_sequence_evidence_sha256 = "$gpui_sequence_sha256"
alpine_sequence_evidence_sha256 = "$alpine_sequence_sha256"
visible_steps = 5
renderer_generations = 2
adapter_atlas_allocations = 4
adapter_atlas_replacements = 2
cpu_oracle_channel_tolerance = 1
cpu_oracle_equivalence_within_tolerance_all = true
direct_metal_performed = $direct_metal_performed
adaptation_timing_performed = false
renderer_timing_performed = false
memory_performed = false
performance_qualified = false
generated_at_utc = "$generated_at_utc"
EOF

sequence_count=0
sequence_visible_count=0
while IFS="$tab" read -r sequence transition scene_path workload_hash readback_path; do
    case "$sequence:$transition" in
        0:full-admission|1:compatible-reuse|2:content-replacement|3:capacity-replacement|4:teardown|5:full-resynchronization) ;;
        *) printf 'GPUI lifecycle step identity drifted: %s:%s\n' "$sequence" "$transition" >&2; exit 1 ;;
    esac
    if [ "$transition" = teardown ]; then
        [ "$scene_path" = none ] && [ "$workload_hash" = none ] && [ "$readback_path" = none ] || { printf 'GPUI teardown retained visible evidence\n' >&2; exit 1; }
        cat >> "$sequence_qualification_tmp" <<EOF

[[steps]]
sequence = $sequence
transition = "$transition"
scene_path = "none"
workload_hash = "none"
expected_cpu_bytes = 0
cpu_oracle_sha256 = "none"
gpui_metal_sha256 = "none"
cpu_oracle_max_observed_channel_delta = 0
semantic_and_pixel_equivalent = true
EOF
    else
        case "$scene_path" in assurance/qualification/v2/*.toml) ;; *) printf 'unsafe GPUI lifecycle scene path: %s\n' "$scene_path" >&2; exit 1 ;; esac
        case "$readback_path" in step-[0-9]-gpui-metal.bgra) ;; *) printf 'unsafe GPUI lifecycle readback path: %s\n' "$readback_path" >&2; exit 1 ;; esac
        scene="$repo_root/.lab/alpine/$scene_path"
        declared_workload=$(sed -nE 's/^workload_hash = "([0-9a-f]{64})"$/\1/p' "$scene")
        [ "$declared_workload" = "$workload_hash" ] || { printf 'GPUI lifecycle workload drifted at step %s\n' "$sequence" >&2; exit 1; }
        cpu_readback="$sequence_dir/step-$sequence-cpu-oracle.bgra"
        CARGO_TARGET_DIR="$repo_root/.lab/target/alpine" cargo run \
            --manifest-path "$repo_root/.lab/alpine/Cargo.toml" \
            --locked \
            -p alpine-assurance \
            -- render-scene-reference "$scene" "$cpu_readback" \
            > "$sequence_dir/step-$sequence-cpu-oracle.log"
        pixel_width=$(sed -nE 's/^pixel_width = ([0-9]+)$/\1/p' "$scene")
        pixel_height=$(sed -nE 's/^pixel_height = ([0-9]+)$/\1/p' "$scene")
        [ -n "$pixel_width" ] && [ -n "$pixel_height" ] || { printf 'lifecycle scene lacks exact dimensions at step %s\n' "$sequence" >&2; exit 1; }
        expected_bytes=$((pixel_width * pixel_height * 4))
        scripts/compare-readbacks.sh --max-channel-delta 1 \
            "$expected_bytes" \
            "$cpu_readback" \
            "$sequence_dir/gpui/$readback_path" \
            > "$sequence_dir/step-$sequence-equivalence.log"
        max_delta=$(sed -nE 's/.*max_observed_channel_delta=([0-9]+).*/\1/p' "$sequence_dir/step-$sequence-equivalence.log")
        case "$max_delta" in ''|*[!0-9]*) printf 'missing lifecycle oracle delta at step %s\n' "$sequence" >&2; exit 1 ;; esac
        cpu_sha256=$(shasum -a 256 "$cpu_readback" | awk '{ print $1 }')
        gpui_sha256=$(shasum -a 256 "$sequence_dir/gpui/$readback_path" | awk '{ print $1 }')
        cat >> "$sequence_qualification_tmp" <<EOF

[[steps]]
sequence = $sequence
transition = "$transition"
scene_path = "$scene_path"
workload_hash = "$workload_hash"
expected_cpu_bytes = $expected_bytes
cpu_oracle_sha256 = "$cpu_sha256"
gpui_metal_sha256 = "$gpui_sha256"
cpu_oracle_max_observed_channel_delta = $max_delta
semantic_and_pixel_equivalent = true
EOF
        sequence_visible_count=$((sequence_visible_count + 1))
    fi
    sequence_count=$((sequence_count + 1))
done < "$sequence_rows"
[ "$sequence_count" -eq 6 ] && [ "$sequence_visible_count" -eq 5 ] || { printf 'GPUI lifecycle execution count drifted\n' >&2; exit 1; }
rm "$sequence_rows"
mv "$sequence_qualification_tmp" "$sequence_dir/qualification.toml"
sequence_qualification_sha256=$(shasum -a 256 "$sequence_dir/qualification.toml" | awk '{ print $1 }')

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
sequence_manifest_path = "$sequence_manifest_path"
sequence_manifest_sha256 = "$sequence_manifest_sha256"
atlas_lifecycle_performed = true
atlas_lifecycle_visible_steps = $sequence_visible_count
atlas_lifecycle_qualification_sha256 = "$sequence_qualification_sha256"
gpui_atlas_lifecycle_evidence_sha256 = "$gpui_sequence_sha256"
alpine_atlas_lifecycle_evidence_sha256 = "$alpine_sequence_sha256"
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
