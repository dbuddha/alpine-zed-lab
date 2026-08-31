#!/bin/sh
set -eu

root=artifacts/physical-sampler-bundle-tests
rm -rf "$root"
mkdir -p "$root/reference/physical-samplers/bin" \
    "$root/reference/physical-samplers/oracle/realistic-code-viewport" \
    "$root/reference/physical-samplers/provenance" \
    "$root/reference/physical-samplers/source/patches"
trap 'rm -rf "$root"' EXIT HUP INT TERM
bundle="$root/reference/physical-samplers"

hash_file() {
    shasum -a 256 "$1" | awk '{ print $1 }'
}

for file in \
    bin/alpine-assurance bin/alpine-trace-adapter \
    provenance/alpine-offscreen.metallib provenance/gpui-shaders.metallib \
    oracle/realistic-code-viewport/equivalence.log \
    oracle/realistic-code-viewport/cpu-oracle.bgra \
    oracle/realistic-code-viewport/gpui-metal.bgra \
    source/realistic-code-viewport.toml source/alpine.toml source/zed.toml \
    source/series source/patches/0001.patch source/patches/0002.patch \
    provenance/alpine-rustc.txt provenance/zed-rustc.txt provenance/xcode.txt \
    provenance/sdk.txt provenance/macos.txt
do
    printf '%s\n' "$file" > "$bundle/$file"
done
chmod 755 "$bundle/bin/alpine-assurance" "$bundle/bin/alpine-trace-adapter"
lab_revision=1111111111111111111111111111111111111111
cat > "$bundle/oracle/qualification-set.toml" <<EOF
schema = "alpine-renderer-equivalence-set/v2"
state = "gpui-oracle-equivalent"
lab_revision = "$lab_revision"
shader_mode = "offline-metallib"
performance_qualified = false
EOF

manifest_path() {
    prefix=$1
    path=$2
    printf '%s_path = "%s"\n%s_sha256 = "%s"\n' "$prefix" "$path" "$prefix" "$(hash_file "$bundle/$path")"
}

{
    cat <<EOF
schema = "alpine-zed-physical-sampler-bundle/v1"
candidate = true
lab_revision = "$lab_revision"
workflow_sha = "$lab_revision"
workflow_run_id = "12345"
alpine_revision = "2222222222222222222222222222222222222222"
zed_revision = "3333333333333333333333333333333333333333"
patch_series_sha256 = "4444444444444444444444444444444444444444444444444444444444444444"
trace_manifest_sha256 = "5555555555555555555555555555555555555555555555555555555555555555"
trace_id = "realistic-code-viewport"
trace_schema = "alpine-scene-trace/v2"
workload_hash = "6666666666666666666666666666666666666666666666666666666666666666"
architecture = "arm64"
build_profile = "release"
shader_mode = "offline-metallib"
EOF
    manifest_path alpine_sampler bin/alpine-assurance
    manifest_path gpui_sampler bin/alpine-trace-adapter
    manifest_path alpine_metallib provenance/alpine-offscreen.metallib
    manifest_path gpui_metallib provenance/gpui-shaders.metallib
    manifest_path oracle_set oracle/qualification-set.toml
    manifest_path oracle_equivalence oracle/realistic-code-viewport/equivalence.log
    manifest_path oracle_cpu oracle/realistic-code-viewport/cpu-oracle.bgra
    manifest_path oracle_gpui oracle/realistic-code-viewport/gpui-metal.bgra
    manifest_path trace source/realistic-code-viewport.toml
    manifest_path alpine_pin source/alpine.toml
    manifest_path zed_pin source/zed.toml
    printf 'patch_series_path = "source/series"\npatch_series_file_sha256 = "%s"\n' \
        "$(hash_file "$bundle/source/series")"
    manifest_path patch_one source/patches/0001.patch
    manifest_path patch_two source/patches/0002.patch
    manifest_path alpine_rustc provenance/alpine-rustc.txt
    manifest_path zed_rustc provenance/zed-rustc.txt
    manifest_path xcode provenance/xcode.txt
    manifest_path sdk provenance/sdk.txt
    manifest_path macos provenance/macos.txt
    cat <<'EOF'
ci_pass_required = true
timing_performed = false
memory_performed = false
performance_qualified = false
performance_claim = "none"
EOF
} > "$bundle/manifest.toml"

make_archive() {
    source=$1
    archive=$2
    tar -cf "$archive" -C "$source" physical-samplers
    (cd "$(dirname "$archive")" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
}

assert_rejected() {
    name=$1
    archive=$2
    checksum=$3
    if ALPINE_LAB_TESTING=1 \
        ALPINE_BUNDLE_TEST_PLATFORM=darwin-arm64 \
        ALPINE_BUNDLE_TEST_CI_PASS=success \
        scripts/verify-physical-sampler-bundle.sh \
            "$archive" "$checksum" "$root/output-$name" > "$root/$name.log" 2>&1
    then
        printf 'invalid physical sampler bundle unexpectedly passed: %s\n' "$name" >&2
        exit 1
    fi
}

mkdir -p "$root/reference-artifact"
reference_archive="$root/reference-artifact/physical-samplers.tar"
make_archive "$root/reference" "$reference_archive"
ALPINE_LAB_TESTING=1 \
ALPINE_BUNDLE_TEST_PLATFORM=darwin-arm64 \
ALPINE_BUNDLE_TEST_CI_PASS=success \
scripts/verify-physical-sampler-bundle.sh \
    "$reference_archive" "$reference_archive.sha256" "$root/output-valid" >/dev/null

printf '0  physical-samplers.tar\n' > "$root/bad-checksum"
assert_rejected checksum "$reference_archive" "$root/bad-checksum"
if ALPINE_LAB_TESTING=1 ALPINE_BUNDLE_TEST_PLATFORM=linux-x64 \
    ALPINE_BUNDLE_TEST_CI_PASS=success \
    scripts/verify-physical-sampler-bundle.sh \
        "$reference_archive" "$reference_archive.sha256" "$root/output-host" >/dev/null 2>&1
then
    printf 'wrong test host unexpectedly passed\n' >&2
    exit 1
fi

for mutation in runtime-shader qualified wrong-hash wrong-oracle; do
    fixture="$root/$mutation"
    cp -R "$root/reference" "$fixture"
    case "$mutation" in
        runtime-shader)
            sed 's/shader_mode = "offline-metallib"/shader_mode = "runtime-source"/' \
                "$fixture/physical-samplers/manifest.toml" > "$fixture/manifest.tmp"
            mv "$fixture/manifest.tmp" "$fixture/physical-samplers/manifest.toml"
            ;;
        qualified)
            sed 's/performance_qualified = false/performance_qualified = true/' \
                "$fixture/physical-samplers/manifest.toml" > "$fixture/manifest.tmp"
            mv "$fixture/manifest.tmp" "$fixture/physical-samplers/manifest.toml"
            ;;
        wrong-hash) printf 'changed\n' >> "$fixture/physical-samplers/bin/alpine-assurance" ;;
        wrong-oracle)
            sed 's/state = "gpui-oracle-equivalent"/state = "rejected"/' \
                "$fixture/physical-samplers/oracle/qualification-set.toml" > "$fixture/oracle.tmp"
            mv "$fixture/oracle.tmp" "$fixture/physical-samplers/oracle/qualification-set.toml"
            ;;
    esac
    mkdir -p "$root/$mutation-artifact"
    archive="$root/$mutation-artifact/physical-samplers.tar"
    make_archive "$fixture" "$archive"
    assert_rejected "$mutation" "$archive" "$archive.sha256"
done

link_fixture="$root/link"
cp -R "$root/reference" "$link_fixture"
ln -s manifest.toml "$link_fixture/physical-samplers/linked-manifest"
mkdir -p "$root/link-artifact"
link_archive="$root/link-artifact/physical-samplers.tar"
make_archive "$link_fixture" "$link_archive"
assert_rejected link "$link_archive" "$link_archive.sha256"

printf 'physical sampler bundle controls passed\n'
