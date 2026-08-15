---
schema: alpine-zed-lab-agent-policy/v1
scope: repository
---

# Alpine Zed Lab Change Policy

## Purpose

This public GPL-3.0-or-later repository qualifies pinned Zed workloads against
GPUI Metal and Alpine Metal. It is a non-shipping research and comparison lab,
not an Alpine source repository or a maintained Zed distribution.

## Required context

Before changing anything:

1. Identify the repository, branch, upstream, and dirty state.
2. Read this file and the root README completely.
3. Read the linked Alpine Requirement and its parent Capability.
4. Confirm both carry `owner:approved` before implementation.
5. Read the linked Alpine AEP, research record, and accepted decision.
6. Fetch the lab origin and Alpine origin before remote comparisons.

## License and source isolation

- Zed source exists only in ignored `.lab/zed` storage provisioned from the
  immutable upstream pin.
- Never copy Zed source, assets, patches, or build artifacts into Alpine GPUI.
- Keep lab patches minimal, reviewed, hashed, and attributable to a variant.
- Do not distribute a combined binary or artifact without explicit legal review.
- Do not change the repository license, Zed pin, or distribution boundary
  without owner approval recorded on the linked Requirement or decision.
- Treat observations as conceptual, behavioral, differential, or source-level
  influence and record the exact kind in Alpine's research system.

## Correctness and comparison

- Unsupported actions, primitives, or missing evidence fail qualification.
- Never drop work, visual fidelity, accessibility, lifecycle behavior, or
  resource accounting to improve a performance result.
- Compare identical workload and environment hashes before timing.
- Keep renderer-only, full-Zed-path, and product-journey results separate.
- Preserve adaptation time and cost as its own reported stage.
- Record raw trials and revision identities before derived summaries.
- Do not call Alpine faster from an uncalibrated, hosted, or unmatched run.

## Changes and reviews

- Use a focused branch and one linked task per pull request.
- Use `type(scope): summary` Conventional Commits with no agent attribution.
- Ask immediately before every push, PR creation, release, source import,
  dependency change, repository setting, secret, or external mutation.
- Every pull request links its Alpine Capability, Requirement, Task, AEP claims,
  research record, and accepted decision.
- Every pull request states source influence, licenses, exact revisions, tests,
  artifacts, remaining risk, and distribution impact.
- Never force push, rewrite published history, bypass a gate, or hide a failure.

## Repository contents

- `pins/` owns immutable upstream identity and license fingerprints.
- `patches/` owns reviewed variant-specific patch series and checksums.
- `scripts/` owns provisioning, isolation, build, workload, and qualification.
- `.lab/` is ignored disposable upstream source and build state.
- `artifacts/` is ignored raw qualification output.
- GitHub checks own current results. Alpine's evidence registry owns accepted
  cross-repository evidence mappings.

## Verification

Run before committing and again before requesting a push:

```sh
scripts/check.sh
```

Run network pin verification before changing or qualifying a Zed revision:

```sh
scripts/check-pin.sh --network
```

## Definition of done

A change is done only when its approved scope is implemented, pin and license
checks pass, source remains isolated, patch hashes match, success and failure
paths are tested, comparison stages are explicit, artifacts identify exact
revisions and environments, all hosted checks pass, and the PR records remaining
risk. A renderer variant is not complete until a clean checkout builds and its
equivalence gates pass on qualified Apple Silicon hardware.
