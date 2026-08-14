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
scene_trace_path=$(pin_value scene_trace_path)
scene_trace_sha256=$(pin_value scene_trace_sha256)
workload_hash=$(pin_value workload_hash)
unset PIN_FILE

trace="$repo_root/.lab/alpine/$scene_trace_path"
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

CARGO_TARGET_DIR="$repo_root/.lab/target/alpine" cargo run \
    --manifest-path "$repo_root/.lab/alpine/Cargo.toml" \
    --locked \
    -p alpine-assurance \
    -- render-scene-reference "$trace" "$output_absolute/cpu-oracle.bgra" \
    > "$output_absolute/cpu-oracle.log"
if [ "$mode" = full ]; then
    CARGO_TARGET_DIR="$repo_root/.lab/target/alpine" cargo run \
        --manifest-path "$repo_root/.lab/alpine/Cargo.toml" \
        --locked \
        -p alpine-assurance \
        -- render-scene-native "$trace" "$output_absolute/alpine-metal.bgra" \
        > "$output_absolute/alpine-metal.log"
fi
# Intentional word splitting selects one optional Cargo feature argument pair.
# shellcheck disable=SC2086
CARGO_TARGET_DIR="$repo_root/.lab/target/zed-adapter" cargo "+$zed_toolchain" run \
    --manifest-path "$variant_checkout/Cargo.toml" \
    --locked \
    -p alpine_trace_adapter \
    $feature_arguments \
    -- "$trace" "$output_absolute/gpui-metal.bgra" \
    > "$output_absolute/gpui-metal.log"

pixel_width=$(sed -nE 's/^pixel_width = ([0-9]+)$/\1/p' "$trace")
pixel_height=$(sed -nE 's/^pixel_height = ([0-9]+)$/\1/p' "$trace")
[ -n "$pixel_width" ] && [ -n "$pixel_height" ] || { printf 'trace lacks exact pixel dimensions\n' >&2; exit 1; }
expected_bytes=$((pixel_width * pixel_height * 4))
if [ "$mode" = full ]; then
    scripts/compare-readbacks.sh \
        "$expected_bytes" \
        "$output_absolute/cpu-oracle.bgra" \
        "$output_absolute/alpine-metal.bgra" \
        "$output_absolute/gpui-metal.bgra" \
        > "$output_absolute/equivalence.log"
else
    scripts/compare-readbacks.sh \
        "$expected_bytes" \
        "$output_absolute/cpu-oracle.bgra" \
        "$output_absolute/gpui-metal.bgra" \
        > "$output_absolute/equivalence.log"
fi

cpu_sha256=$(shasum -a 256 "$output_absolute/cpu-oracle.bgra" | awk '{ print $1 }')
gpui_sha256=$(shasum -a 256 "$output_absolute/gpui-metal.bgra" | awk '{ print $1 }')
if [ "$mode" = full ]; then
    state=equivalent
    direct_metal_performed=true
    alpine_sha256=$(shasum -a 256 "$output_absolute/alpine-metal.bgra" | awk '{ print $1 }')
else
    state=gpui-oracle-equivalent
    direct_metal_performed=false
    alpine_sha256=not-run
fi
patch_series_sha256=$(shasum -a 256 patches/alpine-metal/series | awk '{ print $1 }')
os_version=$(sw_vers -productVersion)
hardware_arch=$(uname -m)
alpine_toolchain=$(sed -nE 's/^channel = "([^"]+)"$/\1/p' "$repo_root/.lab/alpine/rust-toolchain.toml")
[ -n "$alpine_toolchain" ] || { printf 'pinned Alpine checkout lacks a Rust toolchain channel\n' >&2; exit 1; }
alpine_rustc=$(rustc "+$alpine_toolchain" --version | tr ' ' '-')
zed_rustc=$(rustc "+$zed_toolchain" --version | tr ' ' '-')
generated_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

scripts/check-pin.sh
scripts/check-alpine-pin.sh

manifest_tmp="$output_absolute/.qualification.toml.tmp"
cat > "$manifest_tmp" <<EOF
schema = "alpine-renderer-equivalence/v1"
state = "$state"
comparison_level = "renderer-only"
zed_revision = "$zed_commit"
alpine_revision = "$alpine_commit"
scene_trace_sha256 = "$scene_trace_sha256"
workload_hash = "$workload_hash"
pixel_width = $pixel_width
pixel_height = $pixel_height
pixel_format = "compact-bgra8-premultiplied"
cpu_oracle_sha256 = "$cpu_sha256"
alpine_metal_sha256 = "$alpine_sha256"
gpui_metal_sha256 = "$gpui_sha256"
exact_pixel_equivalence = true
direct_metal_performed = $direct_metal_performed
patch_series_sha256 = "$patch_series_sha256"
shader_mode = "$shader_mode"
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
performance_qualified = false
EOF
mv "$manifest_tmp" "$output_absolute/qualification.toml"

printf '%s exact equivalence evidence recorded in %s\n' "$mode" "$output_dir/qualification.toml"
