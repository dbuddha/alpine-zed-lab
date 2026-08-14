## Summary

What changes in the GPL comparison lab?

## Alpine authority

- Capability:
- Requirement:
- Closing task:
- AEP claims:
- Research:
- Accepted decision:

## Pin, source, and license evidence

Record the exact Zed tag, commit, upstream remote, license declaration,
license fingerprint, influence mode, and patch-series changes.

## Acceptance evidence

Map each task criterion to exact commands, checks, artifacts, or qualified
hardware. Separate local supporting evidence from hosted authoritative evidence.

## Correctness and comparison scope

State which of renderer-only, full-Zed-path, or product-journey behavior is in
scope. Identify semantic, visual, accessibility, lifecycle, and resource gates.

## Performance and memory

Record calibrated distributions on qualified hardware, or state why the change
cannot support a performance claim. Never report an unmatched or incomplete run
as an Alpine improvement.

## Risk and distribution

Describe source leakage, license, provenance, unsupported behavior, workload
identity, adaptation, artifact, and distribution risks. State remaining risk.

## Test plan

List exact local and hosted commands and results.

## Checklist

- [ ] Zed source and generated artifacts remain ignored and outside Alpine.
- [ ] Every patch is minimal, reviewed, hashed, and assigned to one variant.
- [ ] Unsupported operations and mismatched identities fail closed.
- [ ] Comparison stages and adaptation cost remain explicit.
- [ ] `scripts/check.sh` and required hosted checks pass.
- [ ] No combined artifact is distributed without legal review.
