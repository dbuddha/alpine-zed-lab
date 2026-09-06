# Rejected renderer capture evidence

Task: [lab #23](https://github.com/dbuddha/alpine-zed-lab/issues/23), a prerequisite for new claim-bearing paired qualification under [Alpine #472](https://github.com/dbuddha/alpine-gpui/issues/472).

Failed captures are not successful samples and must not be rerun unchanged to erase an unfavorable observation. The capture command returns failure while retaining an auditable rejection when possible.

## Publication and ownership

Capture working directories are private (mode `0700`) and contain `.capture-in-progress` until the successful manifest has been atomically published and the marker removed. Run readers reject a `run.toml` while that marker exists, including a marker-removal failure after the manifest was written. Existing successful schemas and legacy sealed captures remain readable.

On failure, the command attempts a separate, uniquely named private `.rejected-paired-*` directory alongside the requested output. Only a fully written, hash-checked `rejection.json` seals this diagnostic receipt. The receipt has schema `alpine-zed-rejected-renderer-capture/v1`, state `rejected`, and no performance claim. Any copied run manifest is renamed `unpublished-run.toml`; it cannot masquerade as a successful run in the rejected package. A `rejection.pending.json` is incomplete, not a receipt.

Original working evidence is never automatically deleted, even after a rejected receipt succeeds. This preserves the only full copy of truncated data and avoids claiming process-tree quiescence or deleting evidence from late writers. It stays marked incomplete. An operator may retain or clean capture-owned working data through the normal artifact lifecycle after reviewing it; the capture does not delete unrelated paths or overwrite another capture. A subsequent attempt needs a new output path.

## Explicit bounds and omissions

- Each retained payload file is at most 64 KiB; aggregate payload is at most 8 MiB.
- The JSON manifest is at most 8 MiB, giving a 16 MiB logical file-content ceiling per sealed rejected package. Directory metadata and original working directories are not included in that ceiling.
- Inventory is bounded by the existing maximum pair count: twelve invocation CSV/log files per pair, plus eight possible root files. Unexpected directories, names, symbolic links, hard-linked files, special files, and replacement during copying are rejected.
- The failing invocation is prioritized, then CSV samples, then remaining logs. Every inventoried file records original size, retained size, retained hash when present, truncation, and omissions. A full source hash is recorded only when all source bytes were retained. Missing bytes or hashes are never represented as complete evidence.
- Available source, workload, environment, equivalence, sampler identity, command, phase, and exit information accompany the failure. Sampler hashes in the rejection context are observed before admission. Unknown status is `null`, not a fabricated exit code.
- Invocation logs begin before process execution. Timeout and spawn failures preserve available partial streams and explicitly identify unavailable terminal status. The ordinary production timeout remains 900 seconds.
- A copying, hashing, metadata-budget, inventory, or publication failure leaves the original intact and reports `rejected_retention_failed`. It does not create a sealed rejection or success receipt.

This bounds the diagnostic copy, not arbitrary sampler output or total historical disk use. It does not qualify child-process-tree drain, physical timing, GPU residency, or comparative claims. Successful sampling still requires the existing exact-equivalence, endpoint, randomization, four-window, twenty-run, and downstream qualification gates.

## Regression evidence

The existing Python suite exercises private/unique retention, hashes, prefix and total budgets, missing full hashes, symlink/hardlink/special-path refusal, manifest and creation failures, real subprocess timeout streams, missing executables, output collisions, and unsealed-manifest rejection.

The full paired fixture exercises the production capture path after prior successful invocations for exit 17, malformed CSV, real subprocess timeout, aggregate publication failure, manifest-marker removal failure, rejected-directory creation failure, and archive hash mismatch. Its successful twenty-run/four-window fixture and existing negative semantic, order, shader, collision, and window controls remain required. These are test fixtures, not physical benchmark evidence.
