#!/bin/sh
set -eu

fail() {
    printf 'physical sampler verification error: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 3 ] || fail 'expected ARCHIVE CHECKSUM OUTPUT_DIRECTORY'
archive=$1
checksum=$2
output=$3
[ -f "$archive" ] && [ ! -L "$archive" ] || fail 'archive is missing or symbolic'
[ -f "$checksum" ] && [ ! -L "$checksum" ] || fail 'checksum is missing or symbolic'
[ ! -e "$output" ] && [ ! -L "$output" ] || fail 'output already exists'
[ "$(wc -c < "$archive" | tr -d ' ')" -le 536870912 ] || fail 'archive exceeds 512 MiB'
expected_archive=$(awk 'NF == 2 { print $1; name = $2; sub(/^\*/, "", name); if (name != "physical-samplers.tar") exit 1; count++ } END { if (count != 1) exit 1 }' "$checksum") || fail 'checksum sidecar is malformed'
case "$expected_archive" in *[!0-9a-f]*|'') fail 'archive checksum is invalid' ;; esac
[ "${#expected_archive}" -eq 64 ] || fail 'archive checksum length drifted'
actual_archive=$(shasum -a 256 "$archive" | awk '{ print $1 }')
[ "$actual_archive" = "$expected_archive" ] || fail 'archive checksum mismatch'

entries=$(tar -tf "$archive") || fail 'archive cannot be listed'
entry_count=$(printf '%s\n' "$entries" | awk 'NF { count++ } END { print count + 0 }')
[ "$entry_count" -gt 0 ] && [ "$entry_count" -le 64 ] || fail 'archive entry count is outside the bound'
printf '%s\n' "$entries" | awk '
    /^\// || /\\/ || /\/\// || /(^|\/)\.\.(\/|$)/ || $0 !~ /^physical-samplers\// { exit 1 }
' || fail 'archive contains an unsafe path'
tar -tvf "$archive" | awk '$1 !~ /^[-d]/ { exit 1 }' || fail 'archive contains a link or unsupported entry type'

temporary="${output}.tmp.$$"
[ ! -e "$temporary" ] && [ ! -L "$temporary" ] || fail 'temporary output collision'
mkdir -p "$temporary"
cleanup() {
    rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM
tar -xf "$archive" -C "$temporary"
bundle="$temporary/physical-samplers"
[ -d "$bundle" ] && [ ! -L "$bundle" ] || fail 'archive root is invalid'
[ -z "$(find "$bundle" -type l -print -quit)" ] || fail 'extracted bundle contains a symbolic link'
manifest="$bundle/manifest.toml"
[ -f "$manifest" ] && [ ! -L "$manifest" ] || fail 'bundle manifest is missing'

toml_value() {
    key=$1
    sed -nE "s/^${key} = \"([^\"]*)\"$/\\1/p" "$manifest"
}

toml_raw() {
    key=$1
    sed -nE "s/^${key} = ([^[:space:]]+)$/\\1/p" "$manifest"
}

expected_keys=$(cat <<'EOF' | sort
alpine_metallib_path
alpine_metallib_sha256
alpine_pin_path
alpine_pin_sha256
alpine_revision
alpine_rustc_path
alpine_rustc_sha256
alpine_sampler_path
alpine_sampler_sha256
architecture
build_profile
candidate
ci_pass_required
gpui_metallib_path
gpui_metallib_sha256
gpui_sampler_path
gpui_sampler_sha256
lab_revision
macos_path
macos_sha256
memory_performed
oracle_cpu_path
oracle_cpu_sha256
oracle_equivalence_path
oracle_equivalence_sha256
oracle_fixture_path
oracle_fixture_sha256
oracle_gpui_path
oracle_gpui_sha256
oracle_set_path
oracle_set_sha256
patch_one_path
patch_one_sha256
patch_series_file_sha256
patch_series_path
patch_series_sha256
patch_two_path
patch_two_sha256
performance_claim
performance_qualified
schema
sdk_path
sdk_sha256
shader_mode
timing_performed
trace_id
trace_canonical_path
trace_manifest_sha256
trace_path
trace_schema
trace_sha256
workflow_run_id
workflow_sha
workload_hash
xcode_path
xcode_sha256
zed_pin_path
zed_pin_sha256
zed_revision
zed_rustc_path
zed_rustc_sha256
EOF
)
actual_keys=$(awk -F '[[:space:]]*=[[:space:]]*' 'NF == 2 { print $1 } NF != 2 { print "<invalid>" }' "$manifest" | sort)
[ "$actual_keys" = "$expected_keys" ] || fail 'bundle manifest fields drifted'
[ "$(toml_value schema)" = alpine-zed-physical-sampler-bundle/v1 ] || fail 'bundle schema drifted'
[ "$(toml_raw candidate)" = true ] || fail 'bundle must remain a candidate'
[ "$(toml_raw ci_pass_required)" = true ] || fail 'bundle must require aggregate ci-pass'
[ "$(toml_raw timing_performed)" = false ] || fail 'bundle must not contain timing evidence'
[ "$(toml_raw memory_performed)" = false ] || fail 'bundle must not contain memory evidence'
[ "$(toml_raw performance_qualified)" = false ] || fail 'bundle must not claim qualification'
[ "$(toml_value performance_claim)" = none ] || fail 'bundle must disclose no performance claim'
[ "$(toml_value build_profile)" = release ] || fail 'bundle must use the release profile'
[ "$(toml_value shader_mode)" = offline-metallib ] || fail 'bundle must use offline metallib shaders'
[ "$(toml_value architecture)" = arm64 ] || fail 'bundle architecture drifted'
[ "$(toml_value trace_id)" = realistic-code-viewport ] || fail 'bundle trace identity drifted'
[ "$(toml_value trace_schema)" = alpine-scene-trace/v2 ] || fail 'bundle trace schema drifted'
case "$(toml_value trace_canonical_path)" in assurance/qualification/v2/*.toml) ;; *) fail 'bundle canonical trace path drifted' ;; esac

lab_revision=$(toml_value lab_revision)
workflow_sha=$(toml_value workflow_sha)
workflow_run_id=$(toml_value workflow_run_id)
[ "$workflow_sha" = "$lab_revision" ] || fail 'workflow and lab revisions differ'
for identity in "$lab_revision" "$workflow_sha" "$(toml_value alpine_revision)" "$(toml_value zed_revision)"; do
    case "$identity" in *[!0-9a-f]*|'') fail 'revision identity is invalid' ;; esac
    [ "${#identity}" -eq 40 ] || fail 'revision identity length drifted'
done
case "$workflow_run_id" in ''|*[!0-9]*) fail 'workflow run identity is invalid' ;; esac

for prefix in \
    alpine_sampler gpui_sampler alpine_metallib gpui_metallib \
    oracle_set oracle_fixture oracle_equivalence oracle_cpu oracle_gpui trace alpine_pin zed_pin \
    patch_one patch_two alpine_rustc zed_rustc xcode sdk macos
do
    path=$(toml_value "${prefix}_path")
    expected=$(toml_value "${prefix}_sha256")
    case "$path" in ''|/*|*..*|*//*|*\\*) fail "unsafe bundle path for $prefix" ;; esac
    case "$expected" in *[!0-9a-f]*|'') fail "invalid bundle hash for $prefix" ;; esac
    [ "${#expected}" -eq 64 ] || fail "bundle hash length drifted for $prefix"
    file="$bundle/$path"
    [ -f "$file" ] && [ ! -L "$file" ] || fail "bundle file is missing for $prefix"
    actual=$(shasum -a 256 "$file" | awk '{ print $1 }')
    [ "$actual" = "$expected" ] || fail "bundle hash mismatch for $prefix"
done
patch_series_path=$(toml_value patch_series_path)
patch_series_file_sha256=$(toml_value patch_series_file_sha256)
case "$patch_series_path" in ''|/*|*..*|*//*|*\\*) fail 'unsafe bundle path for patch_series' ;; esac
case "$patch_series_file_sha256" in *[!0-9a-f]*|'') fail 'invalid bundle hash for patch_series' ;; esac
[ "${#patch_series_file_sha256}" -eq 64 ] || fail 'bundle hash length drifted for patch_series'
patch_series_file="$bundle/$patch_series_path"
[ -f "$patch_series_file" ] && [ ! -L "$patch_series_file" ] || fail 'bundle file is missing for patch_series'
patch_series_actual=$(shasum -a 256 "$patch_series_file" | awk '{ print $1 }')
[ "$patch_series_actual" = "$patch_series_file_sha256" ] || fail 'bundle hash mismatch for patch_series'
[ -x "$bundle/$(toml_value alpine_sampler_path)" ] || fail 'Alpine sampler is not executable'
[ -x "$bundle/$(toml_value gpui_sampler_path)" ] || fail 'GPUI sampler is not executable'
oracle_manifest="$bundle/$(toml_value oracle_set_path)"
oracle_fixture="$bundle/$(toml_value oracle_fixture_path)"
[ "$(sed -nE 's/^state = "([^"]+)"$/\1/p' "$oracle_manifest")" = gpui-oracle-equivalent ] || fail 'bundled oracle state drifted'
[ "$(sed -nE 's/^lab_revision = "([0-9a-f]+)"$/\1/p' "$oracle_manifest")" = "$lab_revision" ] || fail 'bundled oracle revision drifted'
[ "$(sed -nE 's/^shader_mode = "([^"]+)"$/\1/p' "$oracle_manifest")" = offline-metallib ] || fail 'bundled oracle shader mode drifted'
[ "$(sed -nE 's/^performance_qualified = ([a-z]+)$/\1/p' "$oracle_manifest")" = false ] || fail 'bundled oracle qualification drifted'
[ "$(sed -nE 's/^schema = "([^"]+)"$/\1/p' "$oracle_fixture")" = alpine-renderer-equivalence/v2 ] || fail 'bundled oracle fixture schema drifted'
[ "$(sed -nE 's/^state = "([^"]+)"$/\1/p' "$oracle_fixture")" = gpui-oracle-equivalent ] || fail 'bundled oracle fixture state drifted'
[ "$(sed -nE 's/^lab_revision = "([0-9a-f]+)"$/\1/p' "$oracle_fixture")" = "$lab_revision" ] || fail 'bundled oracle fixture revision drifted'
[ "$(sed -nE 's/^alpine_revision = "([0-9a-f]+)"$/\1/p' "$oracle_fixture")" = "$(toml_value alpine_revision)" ] || fail 'bundled oracle fixture Alpine revision drifted'
[ "$(sed -nE 's/^zed_revision = "([0-9a-f]+)"$/\1/p' "$oracle_fixture")" = "$(toml_value zed_revision)" ] || fail 'bundled oracle fixture Zed revision drifted'
[ "$(sed -nE 's/^trace_manifest_sha256 = "([0-9a-f]+)"$/\1/p' "$oracle_fixture")" = "$(toml_value trace_manifest_sha256)" ] || fail 'bundled oracle fixture trace manifest drifted'
[ "$(sed -nE 's/^trace_schema = "([^"]+)"$/\1/p' "$oracle_fixture")" = "$(toml_value trace_schema)" ] || fail 'bundled oracle fixture trace schema drifted'
[ "$(sed -nE 's/^trace_id = "([^"]+)"$/\1/p' "$oracle_fixture")" = "$(toml_value trace_id)" ] || fail 'bundled oracle fixture trace identity drifted'
[ "$(sed -nE 's/^trace_path = "([^"]+)"$/\1/p' "$oracle_fixture")" = "$(toml_value trace_canonical_path)" ] || fail 'bundled oracle fixture trace path drifted'
[ "$(sed -nE 's/^scene_trace_sha256 = "([0-9a-f]+)"$/\1/p' "$oracle_fixture")" = "$(toml_value trace_sha256)" ] || fail 'bundled oracle fixture trace hash drifted'
[ "$(sed -nE 's/^workload_hash = "([0-9a-f]+)"$/\1/p' "$oracle_fixture")" = "$(toml_value workload_hash)" ] || fail 'bundled oracle fixture workload drifted'
[ "$(sed -nE 's/^cpu_oracle_sha256 = "([0-9a-f]+)"$/\1/p' "$oracle_fixture")" = "$(toml_value oracle_cpu_sha256)" ] || fail 'bundled oracle fixture CPU hash drifted'
[ "$(sed -nE 's/^gpui_metal_sha256 = "([0-9a-f]+)"$/\1/p' "$oracle_fixture")" = "$(toml_value oracle_gpui_sha256)" ] || fail 'bundled oracle fixture GPUI hash drifted'
[ "$(sed -nE 's/^shader_mode = "([^"]+)"$/\1/p' "$oracle_fixture")" = offline-metallib ] || fail 'bundled oracle fixture shader mode drifted'
[ "$(sed -nE 's/^direct_metal_performed = ([a-z]+)$/\1/p' "$oracle_fixture")" = false ] || fail 'bundled oracle fixture unexpectedly performed Direct Metal'
[ "$(sed -nE 's/^cpu_oracle_equivalence_within_tolerance = ([a-z]+)$/\1/p' "$oracle_fixture")" = true ] || fail 'bundled oracle fixture CPU equivalence drifted'
[ "$(sed -nE 's/^exact_metal_equivalence = ([a-z]+)$/\1/p' "$oracle_fixture")" = false ] || fail 'bundled oracle fixture unexpectedly claims full Metal equivalence'
[ "$(sed -nE 's/^renderer_timing_performed = ([a-z]+)$/\1/p' "$oracle_fixture")" = false ] || fail 'bundled oracle fixture unexpectedly contains timing'
[ "$(sed -nE 's/^performance_qualified = ([a-z]+)$/\1/p' "$oracle_fixture")" = false ] || fail 'bundled oracle fixture unexpectedly claims qualification'

host_source=physical
if [ "${ALPINE_LAB_TESTING:-0}" = 1 ]; then
    [ "${ALPINE_BUNDLE_TEST_PLATFORM:-}" = darwin-arm64 ] || fail 'test platform must be explicit darwin-arm64'
    [ "${ALPINE_BUNDLE_TEST_CI_PASS:-}" = success ] || fail 'test aggregate result must be success'
    host_source=test-fixture
else
    [ "$(uname -s)" = Darwin ] || fail 'physical verification requires macOS'
    [ "$(uname -m)" = arm64 ] || fail 'physical verification requires arm64'
    run=$(gh run view "$workflow_run_id" --repo dbuddha/alpine-zed-lab --json headSha,jobs) || fail 'cannot read producing workflow run'
    [ "$(printf '%s' "$run" | jq -r .headSha)" = "$workflow_sha" ] || fail 'producing workflow revision drifted'
    ci_pass=$(printf '%s' "$run" | jq -r '[.jobs[] | select(.name == "ci-pass" and .status == "completed" and .conclusion == "success")] | length')
    [ "$ci_pass" -eq 1 ] || fail 'producing workflow lacks one terminal-green ci-pass'
fi

mv "$bundle" "$output"
rmdir "$temporary"
trap - EXIT HUP INT TERM
printf 'schema=alpine-zed-physical-sampler-verification/v1 host_source=%s lab_revision=%s workflow_run_id=%s timing_performed=false performance_qualified=false performance_claim=none output=%s\n' \
    "$host_source" "$lab_revision" "$workflow_run_id" "$output"
