# Studio scene trace candidates

`scripts/studio_scene_trace.py` converts raw Studio frame observations into
**candidate** `alpine-scene-trace/v2` inputs. It is non-shipping lab tooling for
[Alpine #577](https://github.com/dbuddha/alpine-gpui/issues/577), not workload,
renderer, product, latency, memory, or milestone qualification.

## Inputs must be explicit

The raw input is the proposed validation-only
`alpine-studio-scene-capture/v1` geometry JSON and its already-materialized A8
sidecar. The converter never reads a font, changes an atlas, reconstructs glyphs
from screenshots, strips paint operations, or substitutes a synthetic scene for
the captured one. Input geometry and A8 digests must be supplied and match.

Logical geometry is rounded to IEEE-754 f32 before nine-significant-digit TOML
serialization, matching the renderer protocol's numeric domain. Painter order,
clip references, glyph sampling rectangles, colors and atlas bytes remain
explicit. The source process/frame identity and rendered-line count are retained
as **unverified provenance**, not promoted by trusting a JSON label.

The caller must supply actual physical dimensions, scale and an opaque clear
color. Neither native backing scale nor the renderer's clear color lives in
`Scene`. Do not infer either from the first background quad or decorated window
bounds. Supplying values checks mathematical consistency, not their native
authenticity. Font-file identity, source/executable provenance, window identity,
input history and representativeness remain external admission obligations.

Example after an independently retained capture and native-parameter observation:

```sh
python3 scripts/studio_scene_trace.py "$capture" "$new_output_directory" \
  --capture-sha256 "$capture_sha256" --atlas-sha256 "$atlas_sha256" \
  --id studio-normal-code --scale-factor "$observed_scale" \
  --pixel-width "$observed_width" --pixel-height "$observed_height" \
  --clear-color "$observed_red" "$observed_green" "$observed_blue" 1
```

Omit `--atlas-sha256` only for an input with no atlas. This command does not
launch Studio, access the network, copy credentials, or perform measurements.

## Identity and publication

The workload hash follows the accepted v2 adapter exactly: SHA-256 of the UTF-8
trace with the entire LF-delimited `workload_hash = ` line omitted. There must
be exactly one such line. Do not replace its value with zeros, rehash a parsed
dictionary, reorder fields, or normalize existing trace bytes. Resource content
hashes cover the A8 bytes, not its file name or declared dimensions.

The rule is source-pinned in
[`v2::canonical_workload_hash`](https://github.com/dbuddha/alpine-zed-lab/blob/6ceb536afc21b49834c5fd9a72a5952e3e5693cb/patches/alpine-metal/0001-add-gpui-scene-trace-adapter.patch#L3092).
This is protocol translation, not copied Zed application functionality or a
new algorithm/performance claim. The renderer protocol and upstream pins do
not change.

The destination must not exist. Files are streamed, flushed, synchronized and
published without overwrite; failures retain partial output. Final-component
symlinks, nonregular/oversized inputs, changed input identity, wrong hashes,
unknown fields, duplicate JSON keys, non-finite numbers, malformed counts,
unsupported primitives, missing clips and out-of-range glyph samples are
rejected. Parent directories must be trusted experiment-owned paths; this is
not a general filesystem sandbox or a crash-durable directory-metadata claim.

Bounds are 32 MiB of raw JSON, 16 MiB of A8, 65,536 operations, 4,096 clips,
64 cumulative source row patches and 96 MiB of streamed trace output. Conversion
has no renderer timing interpretation and must remain outside every measured
endpoint. A8 is streamed in bounded text chunks when v2 requires inline pixels.

Success produces `scene.toml` and `candidate.json`. The latter permanently
records `state = candidate-only`, unresolved omissions, and false native-origin,
backing-scale, clear-color, equivalence, physical and performance flags.
There is no accepted `run.toml`. Do not edit those flags to admit a workload;
retain separate source/provenance and equivalence receipts through the existing
qualification system. A failed invocation never removes prior evidence.

## Gates and remaining work

The existing lab unittest discovery exercises hash compatibility, f32 handling,
painter order, resource bounds, tampering, filesystem ownership, partial
publication and explicit render parameters. Its input is an explicitly
**synthetic three-operation control**, not a captured or representative Studio
viewport. Native decoder and CPU/Alpine/pinned-GPUI output controls remain
separate acceptance evidence.

The parent task still needs normal and dense code, selection/caret, small-scroll
and resize cases with observed size rationale and complete source/binary/font/
window identities. Preserve the original 64-by-32 seven-glyph miniature trace,
its bytes/hash and unfavorable full submit-readback result. No timing starts
until the candidate's full semantics, provenance and required outputs pass.
The downstream residency and four-window/twenty-paired-run obligations are not
waived by conversion, candidate creation or this tooling task's eventual closure.
