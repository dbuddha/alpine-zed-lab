# Alpine comparison lab

This GPL lab compares Alpine with pinned Zed/GPUI sources. It is a non-shipping
experiment, not a maintained Zed fork. The current Alpine capability probe owns
the experiment scope; this file owns the lab's operating rules.

## Work and acceptance

- Inspect source, branch and dirty state. Preserve unfinished work and fetch
  before remote comparisons. A user request or issue supplies scope; no parent
  hierarchy, approval label, claim ID or Projects access is required.
- Keep one focused outcome and at most two active implementation changes.
  Read only the affected source and relevant references. Old research and issue
  templates are historical context, not additional approval requirements.
- Verify relevant behavior once before publication; repeat after changes or
  failures justify it. Review the full diff and obtain independent review for
  substantive changes. Use live required checks for the tested source and base
  before protected merge, and inspect the resulting main run.
- Honor authorization already given. New dependencies, source copying, unsafe
  boundaries, licenses and external publication need approval when not already
  authorized. Never force push, delete branches, hide failures or bypass protection.

## Source isolation and comparisons

- Keep Zed application source, assets and GPL-derived patches outside Alpine's
  proprietary repository. Source copying needs exact provenance and applicable
  notices; conceptual influence is not copied code. Preserve immutable pin,
  license and patch-hash checks. Do not distribute a combined binary.
- Admit semantic equivalence before timing. Do not omit behavior, accessibility,
  retained data or lifecycle work to improve a result. Unsupported inputs fail.
- Separate prepared-atlas renderer replay, shaping, full application interaction,
  adaptation, GPU completion and actual presentation. Missing presentation cannot
  be replaced by submission, a target deadline or callback arrival.
- Retain raw trials, source/binary/workload identities, toolchain and hardware.
  Report unfavorable results and omissions. Physical superiority requires matched
  physical evidence; hosted correctness and structural bundle checks are distinct.
- Keep the existing pin as a named baseline. A new pin is a new comparison,
  not permission to relabel historical evidence as current.

## Commands and context

```sh
scripts/check.sh
scripts/run-renderer-equivalence.sh artifacts/unique-run
```

The second command provisions/builds native comparison variants and needs the
qualified Metal toolchain. It is not an ordinary documentation check. Coverage
and mutation are opt-in workflow inputs or local experiment flags, not routine
PR acceptance. Failures require investigation, not blind retries.

Use a concise PR: Problem and outcome; Change; Verification and remaining risks.
Include exact pin/provenance changes and measurements only when relevant. Issues
are for deferred defects, blockers or multi-PR work. Keep research on demand and
correct existing documentation when behavior makes it wrong. No Wiki, evolution
ledger, mandatory research package or documentation skill is required.

Alpine maintains four optional engineering skills in its own repository. Use
those for editor work, Metal diagnosis, pinned source comparison or measured
algorithms when available; this lab does not install duplicate global skills.
