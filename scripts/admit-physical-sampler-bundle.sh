#!/bin/sh
set -eu

fail() {
    printf 'physical sampler admission error: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 3 ] || fail 'expected ARCHIVE CHECKSUM OUTPUT_DIRECTORY'
archive=$1
checksum=$2
output=$3
case "$output" in artifacts/*) ;; *) fail 'output must be beneath artifacts' ;; esac
[ ! -e "$output" ] && [ ! -L "$output" ] || fail 'output already exists'

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"
work=$(mktemp -d "$repo_root/.lab/physical-admission.XXXXXX")
verified="$work/verified"
staging="$work/admission"
cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

scripts/verify-physical-sampler-bundle.sh \
    "$archive" "$checksum" "$verified" > "$work/bundle-verification.log"
manifest="$verified/manifest.toml"

toml_value() {
    key=$1
    sed -nE "s/^${key} = \"([^\"]*)\"$/\\1/p" "$manifest"
}

hash_file() {
    shasum -a 256 "$1" | awk '{ print $1 }'
}

adapter_value() {
    key=$1
    file=$2
    sed -nE "s/.*(^|[[:space:]])${key}=([^[:space:]]+).*/\\2/p" "$file"
}

trace="$verified/$(toml_value trace_path)"
cpu="$verified/$(toml_value oracle_cpu_path)"
alpine_sampler="$verified/$(toml_value alpine_sampler_path)"
gpui_sampler="$verified/$(toml_value gpui_sampler_path)"
for file in "$trace" "$cpu" "$alpine_sampler" "$gpui_sampler"; do
    [ -f "$file" ] && [ ! -L "$file" ] || fail "verified input is missing or symbolic: $file"
done

fixture="$staging/realistic-code-viewport"
mkdir -p "$fixture"
"$alpine_sampler" render-scene-native "$trace" "$fixture/alpine-metal.bgra" \
    > "$fixture/alpine-metal.log"
"$gpui_sampler" "$trace" "$fixture/gpui-metal.bgra" \
    > "$fixture/gpui-metal.log"
cmp "$cpu" "$fixture/alpine-metal.bgra" || fail 'physical Alpine readback differs from the CPU oracle'
cmp "$cpu" "$fixture/gpui-metal.bgra" || fail 'physical GPUI readback differs from the CPU oracle'
cp "$cpu" "$fixture/cpu-oracle.bgra"
printf 'semantic_equivalence=exact cpu_sha256=%s alpine_sha256=%s gpui_sha256=%s performance_claim=none\n' \
    "$(hash_file "$fixture/cpu-oracle.bgra")" \
    "$(hash_file "$fixture/alpine-metal.bgra")" \
    "$(hash_file "$fixture/gpui-metal.bgra")" \
    > "$fixture/equivalence.log"

adaptation_clips=$(adapter_value adaptation_clips "$fixture/gpui-metal.log")
adaptation_operations=$(adapter_value adaptation_operations "$fixture/gpui-metal.log")
adaptation_quads=$(adapter_value adaptation_quads "$fixture/gpui-metal.log")
adaptation_glyphs=$(adapter_value adaptation_glyphs "$fixture/gpui-metal.log")
adaptation_resources=$(adapter_value adaptation_resources "$fixture/gpui-metal.log")
adaptation_resource_bytes=$(adapter_value adaptation_resource_bytes "$fixture/gpui-metal.log")
adaptation_atlas_allocations=$(adapter_value adaptation_atlas_allocations "$fixture/gpui-metal.log")
for value in "$adaptation_clips" "$adaptation_operations" "$adaptation_quads" \
    "$adaptation_glyphs" "$adaptation_resources" "$adaptation_resource_bytes" \
    "$adaptation_atlas_allocations"
do
    case "$value" in ''|*[!0-9]*) fail 'physical GPUI adaptation evidence is malformed' ;; esac
done

lab_revision=$(toml_value lab_revision)
alpine_revision=$(toml_value alpine_revision)
zed_revision=$(toml_value zed_revision)
trace_manifest_sha256=$(toml_value trace_manifest_sha256)
trace_schema=$(toml_value trace_schema)
trace_id=$(toml_value trace_id)
trace_canonical_path=$(toml_value trace_canonical_path)
trace_sha256=$(toml_value trace_sha256)
workload_hash=$(toml_value workload_hash)
patch_series_sha256=$(toml_value patch_series_sha256)
generated_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
host_source=physical
[ "${ALPINE_LAB_TESTING:-0}" = 1 ] && host_source=test-fixture

cat > "$fixture/qualification.toml" <<EOF
schema = "alpine-renderer-equivalence/v2"
state = "equivalent"
comparison_level = "renderer-only"
lab_revision = "$lab_revision"
zed_revision = "$zed_revision"
alpine_revision = "$alpine_revision"
trace_manifest_sha256 = "$trace_manifest_sha256"
trace_schema = "$trace_schema"
trace_id = "$trace_id"
trace_path = "$trace_canonical_path"
scene_trace_sha256 = "$trace_sha256"
workload_hash = "$workload_hash"
cpu_oracle_sha256 = "$(hash_file "$fixture/cpu-oracle.bgra")"
alpine_metal_sha256 = "$(hash_file "$fixture/alpine-metal.bgra")"
gpui_metal_sha256 = "$(hash_file "$fixture/gpui-metal.bgra")"
cpu_oracle_channel_tolerance = 0
cpu_oracle_max_observed_channel_delta = 0
cpu_oracle_equivalence_within_tolerance = true
exact_pixel_equivalence = true
exact_metal_equivalence = true
direct_metal_performed = true
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
shader_mode = "offline-metallib"
host_source = "$host_source"
generated_at_utc = "$generated_at_utc"
timing_performed = false
memory_performed = false
performance_qualified = false
performance_claim = "none"
EOF

cat > "$staging/qualification-set.toml" <<EOF
schema = "alpine-renderer-equivalence-set/v2"
state = "equivalent"
comparison_level = "renderer-only"
lab_revision = "$lab_revision"
zed_revision = "$zed_revision"
alpine_revision = "$alpine_revision"
trace_manifest_path = "pins/alpine-traces.tsv"
trace_manifest_sha256 = "$trace_manifest_sha256"
fixture_count = 1
direct_metal_performed = true
cpu_oracle_channel_tolerance = 0
cpu_oracle_equivalence_within_tolerance_all = true
exact_metal_equivalence_all = true
patch_series_sha256 = "$patch_series_sha256"
shader_mode = "offline-metallib"
host_source = "$host_source"
bundle_manifest_sha256 = "$(hash_file "$manifest")"
source_oracle_set_sha256 = "$(toml_value oracle_set_sha256)"
source_oracle_fixture_sha256 = "$(toml_value oracle_fixture_sha256)"
physical_verification_sha256 = "$(hash_file "$work/bundle-verification.log")"
generated_at_utc = "$generated_at_utc"
adaptation_timing_performed = false
renderer_timing_performed = false
memory_performed = false
performance_qualified = false
performance_claim = "none"
EOF
cp "$work/bundle-verification.log" "$staging/bundle-verification.log"

mkdir -p "$(dirname "$output")"
mv "$staging" "$output"
trap - EXIT HUP INT TERM
rm -rf "$work"
printf 'admitted exact physical Alpine, GPUI, and CPU equivalence for lab=%s; timing_performed=false performance_qualified=false performance_claim=none output=%s\n' \
    "$lab_revision" "$output"
