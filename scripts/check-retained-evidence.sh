#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

found=0
for package in evidence/physical-calibration/physical-renderer-protocol-ready-*; do
    [ -d "$package" ] || continue
    found=1
    [ -f "$package/SHA256SUMS" ]
    [ -f "$package/qualification.toml" ]
    [ -f "$package/statistics.toml" ]
    (cd "$package" && shasum -a 256 -c SHA256SUMS >/dev/null)

    grep -Fq 'state = "protocol-ready"' "$package/qualification.toml"
    grep -Fq 'run_count = 20' "$package/qualification.toml"
    grep -Fq 'window_count = 4' "$package/qualification.toml"
    grep -Fq 'pair_count = 40' "$package/qualification.toml"
    grep -Fq 'performance_qualified = false' "$package/qualification.toml"
    grep -Fq 'performance_claim = "none"' "$package/qualification.toml"

    grep -Fq 'calibration_complete = true' "$package/statistics.toml"
    grep -Fq 'statistics_qualified = false' "$package/statistics.toml"
    grep -Fq 'residency_qualified = false' "$package/statistics.toml"
    grep -Fq 'performance_qualified = false' "$package/statistics.toml"
    grep -Fq 'performance_claim = "none"' "$package/statistics.toml"

    qualification_sha=$(shasum -a 256 "$package/qualification.toml" | awk '{ print $1 }')
    recorded_sha=$(sed -nE 's/^source_qualification_sha256 = "([0-9a-f]{64})"$/\1/p' "$package/statistics.toml")
    [ "$qualification_sha" = "$recorded_sha" ]

    actual_runs=$(find "$package/runs" -mindepth 2 -maxdepth 2 -name run.toml -type f | wc -l | tr -d ' ')
    [ "$actual_runs" = 20 ]
    expected_run_hashes=$(sed -nE 's/^run_manifest_sha256 = "([0-9a-f]{64})"$/\1/p' "$package/qualification.toml" | sort)
    actual_run_hashes=$(find "$package/runs" -mindepth 2 -maxdepth 2 -name run.toml -type f -exec shasum -a 256 {} \; | awk '{ print $1 }' | sort)
    [ "$expected_run_hashes" = "$actual_run_hashes" ]
done

[ "$found" = 1 ]
printf 'retained physical calibration evidence passed\n'
