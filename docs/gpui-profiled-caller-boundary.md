# GPUI profiled caller boundary

Task: [lab24](https://github.com/dbuddha/alpine-zed-lab/issues/24).
Parent: [Alpine526](https://github.com/dbuddha/alpine-gpui/issues/526).
Disposition: implementation candidate, not accepted observer calibration.

## Why this change is needed

The ordinary comparator measures `render_scene_to_image_with_clear` through
owned-image return. It stops before `image.into_raw()` and byte comparison.
The original GPUI profile/v1 exposed only an internal renderer `total_ns`,
which stopped inside the renderer before its owned result returned. Those are
different intervals, even when the underlying pixels match.

Alpine added a matching outer caller endpoint in its own profile/v2. GPUI needs
the same distinction before ordinary/profiled observer effects can be evaluated
without conflating instrumentation and unmatched work.

The initiating source and physical evidence is retained in
[Experiment526](https://github.com/dbuddha/alpine-gpui/issues/526#issuecomment-5560238045).
The sixteen diagnostic processes and4096 samples are one physical session,
not four independent hardware qualification windows. Relative ordering changed
across blocks. Host completion wait dominated the miniature offscreen path;
that does not identify the driver, GPU, queue or wake contribution causally.

## Source-boundary map

All paths below refer to the isolated patched Zed adapter, never shipping Alpine.
Zed remains pinned to `e17dc4f9d50db73a458b64dcce50ecd4878b98a3`.

| Boundary | Owner | Timing behavior |
| --- | --- | --- |
| Ordinary caller | `crates/alpine_trace_adapter/src/v2.rs::benchmark_source` | Start immediately before the ordinary renderer call; stop after its owned image returns, before raw conversion/comparison |
| Profiled caller | `v2.rs::observe_profiled_return`, called by `profile_readback` | Start before the profiled renderer call; stop after the owned image and existing internal profile return, before raw conversion/comparison |
| Internal stages | Existing `HeadlessRenderProfile` and GPUI Metal implementation | Preserve all values and boundaries unchanged |
| Semantic admission | `v2.rs::profile_admission` | Ordinary unprofiled readback; every profiled warmup/sample must match its bytes |
| Serialization | `v2.rs::render_profile_samples` | Outside renderer timing; reject empty inventory or a caller interval shorter than a nonzero internal total |

The adapter's ordinary benchmark source has SHA-256
`d02eae559af9654078b657f65762e82622beccc8b6e766ec3f9f9698c1256023`
under the exact added-source extraction used by the regression control. Source
review additionally compares the GPUI platform and Metal source blobs with the
pre-change patch. A source hash alone is not a dynamic correctness proof.

The small private sample wrapper and return-observation helper exist to expose
and test this measurement boundary. They add no GPUI public API, shipping
dependency, frame queue, cache, synchronization or runtime architecture.

## Versioned diagnostic contract

The CLI summary and each CSV row use
`alpine-zed-gpui-renderer-profile/v2`. The old thirteen columns retain their
meaning. `caller_elapsed_ns` and `schema` are appended. Internal `total_ns` is
not renamed or silently substituted. The ordinary `sample_index,elapsed_ns`
schema remains unchanged and probe-free.

The CLI reports `caller_endpoint=owned-image-return` and
`inner_totals=unchanged`. A consumer must not mix v1 internal totals with v2
caller values or accept an old file merely because it contains numeric data.

```sh
alpine_trace_adapter --profile TRACE OUTPUT.csv WARMUPS SAMPLES
python3 scripts/validate_gpui_profile.py OUTPUT.csv SAMPLES
```

The validator checks a bounded regular file, exact schema/fields, contiguous
indexes, exact nonzero sample count, unsigned64-bit values, optional-stage
availability and caller enclosure. It retains unavailable durations as blank
fields. It does not authenticate source, binaries, workload or environment,
and it does not qualify performance. Those obligations remain with the bundle,
experiment and retained-evidence protocols.

GPU execution overlaps host completion wait and is never added to it. Internal
stage medians are not an additive end-to-end median. Observer effects must be
calibrated from matched ordinary/profiled caller endpoints, not subtracted from
the benchmark as an assumed correction.

## Acceptance and historical evidence

- Rust controls exercise the production return-observation helper with a real
  delayed return, preserve its internal profile, propagate failure, reject
  inconsistent serialization, and run the public native profile path.
- Python controls reject missing/stale schemas, malformed numbers, inaccurate
  large-integer enclosure, invalid sample inventory, optional-stage mismatch,
  symlinks, nonregular or oversized files and malformed CSV.
- The existing required renderer-equivalence job runs the profile/v2 consumer
  against real GPUI output, in addition to CPU/Metal semantic admission.
- Repository policy discovers the new Python controls through its existing
  `test_*.py` inventory. No CI job, required status or threshold is weakened.
- Exact-head CI, source/base identity, exact-main CI and independently verified
  final bundle identities are required before fresh accepted physical capture.
- Previous profile/v1 raw records remain historical evidence with their original
  scope. They are not rewritten, upgraded or treated as new calibration.

Task closure proves measurement infrastructure only. Experiment526 remains open
until randomized physical observer calibration and reviewed attribution pass.
The existing full submit-readback endpoint and miniature fixture remain intact;
editor-scale workloads, residency, E4 comparisons and Studio acceptance are
separate obligations. There is no speedup claim in this change.
