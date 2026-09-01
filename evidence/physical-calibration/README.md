# Physical renderer calibration

These records preserve physical Apple Silicon protocol executions. They do not
establish a performance claim unless the run manifest explicitly sets
`performance_qualified = true` and names a non-`none` claim.

| Run | Hardware | Workload | Pairs | Qualification | Claim | Tracking |
| --- | --- | --- | ---: | --- | --- | --- |
| [`physical-m4-f6aa2c2-1788238552`](physical-m4-f6aa2c2-1788238552/run.toml) | Apple M4, Mac16,1, 24 GB | `realistic-code-viewport` | 2 per lane | `false` | `none` | [Alpine #496](https://github.com/dbuddha/alpine-gpui/issues/496) |
| [`physical-renderer-protocol-ready-20260901t165407z`](physical-renderer-protocol-ready-20260901t165407z/README.md) | Apple M4, Mac16,1, 24 GB | `realistic-code-viewport` | 40 per lane across 20 runs and 4 windows | calibration only | `none` | [Alpine #470](https://github.com/dbuddha/alpine-gpui/issues/470) |

The run directory retains the environment window, both renderer A/A lanes, the
Alpine-to-GPUI lane, the untimed adaptation record, and their SHA-256 bindings.
The capture was admitted only after Alpine, GPUI, and the independent CPU oracle
produced identical BGRA8 output for the pinned realistic code viewport.

The protocol-ready package retains a negative result for Alpine rather than
promoting a favorable headline. In this exact renderer-submit-readback corpus,
the paired median for pinned GPUI was 120,275 parts per million lower than
Alpine, with a paired bootstrap interval from 163,797 to 79,904 parts per
million lower. The package does not qualify that observation as a performance
claim because renderer residency, broader workload coverage, and final E4
review remain open.
