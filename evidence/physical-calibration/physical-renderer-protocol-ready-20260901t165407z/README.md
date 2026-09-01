# Protocol-ready M4 renderer calibration

This package retains the exact no-claim physical corpus produced for Alpine
issue #470. It contains 20 runs and 40 paired samples per lane across four
non-overlapping physical Apple M4 windows.

## Identity

- Lab revision: `f6aa2c2ebab3774e3871c7771e0eb73955a5645a`
- Alpine revision: `2fdf5aa283e7d773203a76b394ed2e62428c16e4`
- Zed revision: `e17dc4f9d50db73a458b64dcce50ecd4878b98a3`
- Workload: `realistic-code-viewport`
- Stage: `renderer-submit-readback`
- Hardware: Apple M4, Mac16,1, 24 GB
- Semantics: exact Alpine and GPUI Metal BGRA8 equivalence after CPU-oracle admission

## Contents

- `qualification.toml` binds all identities, run manifests, raw distributions,
  adaptation evidence, and no-claim boundaries.
- `statistics.toml` contains deterministic nearest-rank percentiles and paired
  10,000-resample bootstrap median intervals for aggregate and per-window data.
- `runs/` contains every hash-bound run manifest; redundant per-run lane,
  adaptation, window, invocation, and executable copies are omitted because the
  composed package retains those bytes and identities.
- `raw/` contains the composed A/A and cross-renderer distributions.
- `SHA256SUMS` binds every retained file.

The A/A manifests preserve their original capture-time `artifacts/` path. The
relocated raw bytes are retained under `raw/` with the same recorded hashes.

## Adversarial result

The cross lane defines Alpine Direct Metal as the base and pinned Zed GPUI Metal
as the candidate. The observed paired median relative delta is `-120275 ppm`,
with a paired 95 percent bootstrap interval of `[-163797, -79904] ppm`.
Negative is lower and therefore favors GPUI for this one stage and workload.

This is evidence that Alpine is not yet faster on the pinned realistic viewport.
It is not a performance qualification or product claim. Residency, broader
workload coverage, independent review, and final E4 acceptance remain open.
