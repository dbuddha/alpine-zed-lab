#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

: "$ALPINE_ASSURANCE_BIN"

artifact_root=artifacts/paired-protocol-fixture
if [ "$#" -ge 1 ]; then
    artifact_root=$1
fi
keep=0
if [ "$#" -ge 2 ] && [ "$2" = --keep ]; then
    keep=1
fi
case "$artifact_root" in artifacts/*) ;; *) printf 'test artifact root must be below artifacts/\n' >&2; exit 1 ;; esac
[ ! -e "$artifact_root" ] || { printf 'test artifact root already exists\n' >&2; exit 1; }
mkdir -p "$artifact_root/bin" "$artifact_root/windows" "$artifact_root/equivalence/realistic-code-viewport"
cleanup() {
    if [ "$keep" != 1 ]; then
        rm -rf "$artifact_root"
    fi
}
trap cleanup EXIT HUP INT TERM

lab_revision=$(scripts/read-lab-revision.sh)
alpine_revision=$(sed -nE 's/^commit = "([0-9a-f]{40})"$/\1/p' pins/alpine.toml)
zed_revision=$(sed -nE 's/^commit = "([0-9a-f]{40})"$/\1/p' pins/zed.toml)
trace_manifest_path=$(sed -nE 's/^trace_manifest_path = "([^"]+)"$/\1/p' pins/alpine.toml)
trace_manifest_sha256=$(sed -nE 's/^trace_manifest_sha256 = "([0-9a-f]{64})"$/\1/p' pins/alpine.toml)
patch_series_sha256=$(shasum -a 256 patches/alpine-metal/series | awk '{ print $1 }')
tab=$(printf '\t')
trace_row=$(awk -F "$tab" '$1 == "realistic-code-viewport" { print; exit }' "$trace_manifest_path")
trace_schema=$(printf '%s\n' "$trace_row" | awk -F "$tab" '{ print $2 }')
trace_path=$(printf '%s\n' "$trace_row" | awk -F "$tab" '{ print $3 }')
trace_sha256=$(printf '%s\n' "$trace_row" | awk -F "$tab" '{ print $4 }')
workload_hash=$(printf '%s\n' "$trace_row" | awk -F "$tab" '{ print $5 }')

cat > "$artifact_root/equivalence/qualification-set.toml" <<EOF
schema = "alpine-renderer-equivalence-set/v2"
state = "equivalent"
comparison_level = "renderer-only"
lab_revision = "$lab_revision"
zed_revision = "$zed_revision"
alpine_revision = "$alpine_revision"
trace_manifest_sha256 = "$trace_manifest_sha256"
patch_series_sha256 = "$patch_series_sha256"
shader_mode = "offline-metallib"
direct_metal_performed = true
cpu_oracle_equivalence_within_tolerance_all = true
exact_metal_equivalence_all = true
renderer_timing_performed = false
performance_qualified = false
EOF

cat > "$artifact_root/equivalence/realistic-code-viewport/qualification.toml" <<EOF
schema = "alpine-renderer-equivalence/v2"
state = "equivalent"
comparison_level = "renderer-only"
lab_revision = "$lab_revision"
zed_revision = "$zed_revision"
alpine_revision = "$alpine_revision"
trace_manifest_sha256 = "$trace_manifest_sha256"
trace_schema = "$trace_schema"
trace_id = "realistic-code-viewport"
trace_path = "$trace_path"
scene_trace_sha256 = "$trace_sha256"
workload_hash = "$workload_hash"
shader_mode = "offline-metallib"
direct_metal_performed = true
cpu_oracle_equivalence_within_tolerance = true
exact_metal_equivalence = true
renderer_timing_performed = false
performance_qualified = false
EOF

cat > "$artifact_root/bin/alpine-sampler" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = benchmark-scene-native ] && [ "$5" = 1 ]
trace=$2
output=$3
warmups=$4
id=$(sed -nE 's/^id = "([^"]+)"$/\1/p' "$trace")
value=$(printf '%s' "$output" | cksum | awk '{ print ($1 % 100000) + 1000 }')
printf 'sample_index,elapsed_ns\n0,%s\n' "$value" > "$output"
printf 'recorded admission_iterations=1 warmup_iterations=%s sample_count=1 renderer=direct-metal trace=%s at stage renderer-submit-readback using process-monotonic Instant; performance claim=none; output=%s\n' "$warmups" "$id" "$output"
EOF

cat > "$artifact_root/bin/gpui-sampler" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = --benchmark ] && [ "$5" = 1 ]
trace=$2
output=$3
warmups=$4
schema=$(sed -nE 's/^schema = "([^"]+)"$/\1/p' "$trace")
id=$(sed -nE 's/^id = "([^"]+)"$/\1/p' "$trace")
workload=$(sed -nE 's/^workload_hash = "([^"]+)"$/\1/p' "$trace")
value=$(printf '%s' "$output" | cksum | awk '{ print ($1 % 100000) + 2000 }')
printf 'sample_index,elapsed_ns\n0,%s\n' "$value" > "$output"
printf 'schema=alpine-zed-gpui-renderer-samples/v1 trace_schema=%s id=%s workload_hash=%s revision=1 width=1 height=1 adaptation_clips=1 adaptation_operations=2 adaptation_quads=1 adaptation_glyphs=1 adaptation_resources=1 adaptation_resource_bytes=64 adaptation_atlas_allocations=1 adaptation_timing_performed=false admission_iterations=1 warmup_iterations=%s sample_count=1 measurement_stage=renderer-submit-readback clock=process-monotonic-instant renderer_timing_performed=true performance_qualified=false output=%s\n' "$schema" "$id" "$workload" "$warmups" "$output"
EOF

cat > "$artifact_root/bin/bad-gpui-sampler" <<'EOF'
#!/bin/sh
set -eu
printf 'wrong,header\n0,0\n' > "$3"
printf 'performance_qualified=false\n'
EOF
chmod +x "$artifact_root/bin/"*

window=1
while [ "$window" -le 4 ]; do
    day=$(printf '%02d' "$window")
    start_time=$(printf '2026-08-%sT10:00:00Z' "$day")
    end_time=$(printf '2026-08-%sT11:00:00Z' "$day")
    cat > "$artifact_root/windows/window-$day.toml" <<EOF
schema = "alpine-renderer-window/v1"
id = "window-$day"
lease_id = "fixture-lease-$day"
environment_kind = "test-fixture"
hardware_id = "fixture-hardware-$day"
hardware_model = "fixture-apple-silicon"
gpu = "fixture-gpu"
memory_bytes = 34359738368
os_build = "fixture-macos-build"
xcode_build = "fixture-xcode-build"
rustc = "fixture-rustc"
runner_image = "fixture-runner"
power_state = "fixed-ac"
thermal_policy = "fixture-nominal"
display_state = "headless-fixed"
shader_mode = "offline-metallib"
validation_enabled = false
started_at_utc = "$start_time"
ended_at_utc = "$end_time"
EOF
    window=$((window + 1))
done

runs=
index=1
while [ "$index" -le 20 ]; do
    run=$(printf 'run-%02d' "$index")
    window_index=$(( (index - 1) / 5 + 1 ))
    window_id=$(printf '%02d' "$window_index")
    seed=$(printf '%064x' "$index")
    output="$artifact_root/runs/$run"
    scripts/run-paired-renderer-samples.sh capture \
        --output "$output" \
        --equivalence "$artifact_root/equivalence" \
        --trace-id realistic-code-viewport \
        --window "$artifact_root/windows/window-$window_id.toml" \
        --run-id "$run" \
        --seed "$seed" \
        --warmups 2 \
        --pairs 2 \
        --alpine-sampler "$artifact_root/bin/alpine-sampler" \
        --gpui-sampler "$artifact_root/bin/gpui-sampler" \
        --allow-test-fixture >/dev/null
    runs="$runs --run $output"
    index=$((index + 1))
done

set -- $runs
scripts/run-paired-renderer-samples.sh compose \
    --output "$artifact_root/composed" \
    "$@" \
    --alpine-assurance "$ALPINE_ASSURANCE_BIN" \
    > "$artifact_root/compose.log"
grep -Fq 'aa_controls_validated=true performance_qualified=false performance_claim=none' "$artifact_root/compose.log"
grep -Fq 'schema = "alpine-zed-paired-renderer-samples/v1"' "$artifact_root/composed/qualification.toml"
grep -Fq 'performance_qualified = false' "$artifact_root/composed/qualification.toml"
grep -Fq 'no performance claim' "$artifact_root/composed/alpine-aa-validation.log"
grep -Fq 'no performance claim' "$artifact_root/composed/gpui-aa-validation.log"
scripts/run-paired-renderer-samples.sh analyze \
    --input "$artifact_root/composed" \
    --output "$artifact_root/composed/statistics.toml" \
    --bootstrap-resamples 1000 \
    --allow-test-fixture \
    > "$artifact_root/analyze.log"
grep -Fq 'calibration_complete=true statistics_qualified=false' \
    "$artifact_root/analyze.log"
grep -Fq 'schema = "alpine-zed-renderer-statistics/v1"' \
    "$artifact_root/composed/statistics.toml"
grep -Fq 'window_count = 4' "$artifact_root/composed/statistics.toml"
grep -Fq 'statistics_qualified = false' "$artifact_root/composed/statistics.toml"
grep -Fq 'performance_claim = "none"' "$artifact_root/composed/statistics.toml"

if scripts/run-paired-renderer-samples.sh analyze \
    --input "$artifact_root/composed" \
    --output "$artifact_root/composed/statistics.toml" \
    --bootstrap-resamples 1000 \
    --allow-test-fixture >/dev/null 2>&1; then
    printf 'statistics output collision unexpectedly passed\n' >&2
    exit 1
fi

if scripts/run-paired-renderer-samples.sh capture \
    --output "$artifact_root/runs/run-01" \
    --equivalence "$artifact_root/equivalence" \
    --trace-id realistic-code-viewport \
    --window "$artifact_root/windows/window-01.toml" \
    --run-id run-01 \
    --seed "$(printf '%064x' 1)" \
    --warmups 2 \
    --pairs 2 \
    --alpine-sampler "$artifact_root/bin/alpine-sampler" \
    --gpui-sampler "$artifact_root/bin/gpui-sampler" \
    --allow-test-fixture >/dev/null 2>&1; then
    printf 'capture output collision unexpectedly passed\n' >&2
    exit 1
fi

set -- $runs
if scripts/run-paired-renderer-samples.sh compose \
    --output "$artifact_root/composed" \
    "$@" \
    --alpine-assurance "$ALPINE_ASSURANCE_BIN" >/dev/null 2>&1; then
    printf 'compose output collision unexpectedly passed\n' >&2
    exit 1
fi

incomplete=
index=1
while [ "$index" -le 19 ]; do
    run=$(printf 'run-%02d' "$index")
    incomplete="$incomplete --run $artifact_root/runs/$run"
    index=$((index + 1))
done
set -- $incomplete
if scripts/run-paired-renderer-samples.sh compose \
    --output "$artifact_root/incomplete" \
    "$@" \
    --alpine-assurance "$ALPINE_ASSURANCE_BIN" >/dev/null 2>&1; then
    printf 'incomplete run set unexpectedly passed\n' >&2
    exit 1
fi
test ! -e "$artifact_root/incomplete"

cp -R "$artifact_root/runs/run-20" "$artifact_root/identity-drift"
sed 's/^workload_hash = ".*"/workload_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"/' \
    "$artifact_root/identity-drift/run.toml" > "$artifact_root/identity-drift/run.tmp"
mv "$artifact_root/identity-drift/run.tmp" "$artifact_root/identity-drift/run.toml"
identity_runs=
index=1
while [ "$index" -le 19 ]; do
    run=$(printf 'run-%02d' "$index")
    identity_runs="$identity_runs --run $artifact_root/runs/$run"
    index=$((index + 1))
done
identity_runs="$identity_runs --run $artifact_root/identity-drift"
set -- $identity_runs
if scripts/run-paired-renderer-samples.sh compose \
    --output "$artifact_root/identity-output" \
    "$@" \
    --alpine-assurance "$ALPINE_ASSURANCE_BIN" >/dev/null 2>&1; then
    printf 'identity drift unexpectedly passed\n' >&2
    exit 1
fi
test ! -e "$artifact_root/identity-output"

cp -R "$artifact_root/runs/run-20" "$artifact_root/overlap-drift"
python3 - "$artifact_root/overlap-drift/run.toml" <<'PY'
import importlib.util
import re
import sys
from pathlib import Path

module_path = Path("scripts/paired_renderer_samples.py").resolve()
spec = importlib.util.spec_from_file_location("paired_renderer_samples", module_path)
assert spec is not None and spec.loader is not None
paired = importlib.util.module_from_spec(spec)
spec.loader.exec_module(paired)

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
source = source.replace('id = "window-04"', 'id = "window-overlap"', 1)
source = source.replace(
    'lease_id = "fixture-lease-04"',
    'lease_id = "fixture-lease-overlap"',
    1,
)
source = source.replace(
    'started_at_utc = "2026-08-04T10:00:00Z"',
    'started_at_utc = "2026-08-03T10:30:00Z"',
    1,
)
source = source.replace(
    'ended_at_utc = "2026-08-04T11:00:00Z"',
    'ended_at_utc = "2026-08-03T11:30:00Z"',
    1,
)
path.write_text(source, encoding="utf-8")
record = paired.load_toml(path)
environment_hash = paired.canonical_window_hash(record["window"])
source = path.read_text(encoding="utf-8")
source = re.sub(
    r'^environment_hash = "[0-9a-f]{64}"$',
    f'environment_hash = "{environment_hash}"',
    source,
    count=1,
    flags=re.MULTILINE,
)
path.write_text(source, encoding="utf-8")
PY
overlap_runs=
index=1
while [ "$index" -le 19 ]; do
    run=$(printf 'run-%02d' "$index")
    overlap_runs="$overlap_runs --run $artifact_root/runs/$run"
    index=$((index + 1))
done
overlap_runs="$overlap_runs --run $artifact_root/overlap-drift"
set -- $overlap_runs
if scripts/run-paired-renderer-samples.sh compose \
    --output "$artifact_root/overlap-output" \
    "$@" \
    --alpine-assurance "$ALPINE_ASSURANCE_BIN" \
    >"$artifact_root/overlap.log" 2>&1; then
    printf 'overlapping hardware windows unexpectedly passed\n' >&2
    exit 1
fi
grep -Fq 'hardware windows overlap: window-03 and window-overlap' \
    "$artifact_root/overlap.log"
test ! -e "$artifact_root/overlap-output"

cp -R "$artifact_root/runs/run-20" "$artifact_root/order-drift"
sed 's/candidate-first/base-first/g' "$artifact_root/order-drift/alpine-aa.csv" \
    > "$artifact_root/order-drift/alpine-aa.tmp"
mv "$artifact_root/order-drift/alpine-aa.tmp" "$artifact_root/order-drift/alpine-aa.csv"
new_hash=$(shasum -a 256 "$artifact_root/order-drift/alpine-aa.csv" | awk '{ print $1 }')
sed "s/^alpine_aa_sha256 = \".*\"/alpine_aa_sha256 = \"$new_hash\"/" \
    "$artifact_root/order-drift/run.toml" > "$artifact_root/order-drift/run.tmp"
mv "$artifact_root/order-drift/run.tmp" "$artifact_root/order-drift/run.toml"
order_runs=
index=1
while [ "$index" -le 19 ]; do
    run=$(printf 'run-%02d' "$index")
    order_runs="$order_runs --run $artifact_root/runs/$run"
    index=$((index + 1))
done
order_runs="$order_runs --run $artifact_root/order-drift"
set -- $order_runs
if scripts/run-paired-renderer-samples.sh compose \
    --output "$artifact_root/order-output" \
    "$@" \
    --alpine-assurance "$ALPINE_ASSURANCE_BIN" >/dev/null 2>&1; then
    printf 'one-sided order unexpectedly passed\n' >&2
    exit 1
fi
test ! -e "$artifact_root/order-output"

if scripts/run-paired-renderer-samples.sh capture \
    --output "$artifact_root/malformed" \
    --equivalence "$artifact_root/equivalence" \
    --trace-id realistic-code-viewport \
    --window "$artifact_root/windows/window-01.toml" \
    --run-id malformed-run \
    --seed "$(printf '%064x' 21)" \
    --warmups 2 \
    --pairs 2 \
    --alpine-sampler "$artifact_root/bin/alpine-sampler" \
    --gpui-sampler "$artifact_root/bin/bad-gpui-sampler" \
    --allow-test-fixture >/dev/null 2>&1; then
    printf 'malformed sampler output unexpectedly passed\n' >&2
    exit 1
fi
test ! -e "$artifact_root/malformed"

sed 's/shader_mode = "offline-metallib"/shader_mode = "runtime-source"/' \
    "$artifact_root/windows/window-01.toml" > "$artifact_root/windows/unsupported.toml"
if scripts/run-paired-renderer-samples.sh capture \
    --output "$artifact_root/unsupported" \
    --equivalence "$artifact_root/equivalence" \
    --trace-id realistic-code-viewport \
    --window "$artifact_root/windows/unsupported.toml" \
    --run-id unsupported-run \
    --seed "$(printf '%064x' 22)" \
    --warmups 2 \
    --pairs 2 \
    --alpine-sampler "$artifact_root/bin/alpine-sampler" \
    --gpui-sampler "$artifact_root/bin/gpui-sampler" \
    --allow-test-fixture >/dev/null 2>&1; then
    printf 'unsupported shader mode unexpectedly passed\n' >&2
    exit 1
fi
test ! -e "$artifact_root/unsupported"

cp -R "$artifact_root/equivalence" "$artifact_root/equivalence-drift"
sed 's/exact_metal_equivalence = true/exact_metal_equivalence = false/' \
    "$artifact_root/equivalence-drift/realistic-code-viewport/qualification.toml" \
    > "$artifact_root/equivalence-drift/realistic-code-viewport/qualification.tmp"
mv "$artifact_root/equivalence-drift/realistic-code-viewport/qualification.tmp" \
    "$artifact_root/equivalence-drift/realistic-code-viewport/qualification.toml"
if scripts/run-paired-renderer-samples.sh capture \
    --output "$artifact_root/semantic-drift" \
    --equivalence "$artifact_root/equivalence-drift" \
    --trace-id realistic-code-viewport \
    --window "$artifact_root/windows/window-01.toml" \
    --run-id semantic-drift \
    --seed "$(printf '%064x' 23)" \
    --warmups 2 \
    --pairs 2 \
    --alpine-sampler "$artifact_root/bin/alpine-sampler" \
    --gpui-sampler "$artifact_root/bin/gpui-sampler" \
    --allow-test-fixture >/dev/null 2>&1; then
    printf 'semantic drift unexpectedly passed\n' >&2
    exit 1
fi
test ! -e "$artifact_root/semantic-drift"

printf 'paired renderer protocol controls passed\n'
