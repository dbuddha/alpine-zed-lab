#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

for script in scripts/*.sh scripts/lib/*.sh tests/*.sh; do
    sh -n "$script"
done

python3 -m py_compile scripts/paired_renderer_samples.py tests/test_paired_renderer_samples.py
python3 -m unittest discover -s tests -p 'test_*.py'

scripts/check-pin.sh
scripts/check-alpine-pin.sh
scripts/check-license-boundary.sh
scripts/check-adapter-patch.sh
scripts/check-workflows.sh
tests/workflow-gate.sh
tests/physical-sampler-bundle.sh
tests/policy.sh

printf 'Alpine Zed Lab checks passed\n'
