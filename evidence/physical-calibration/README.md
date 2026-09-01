# Physical renderer calibration

These records preserve physical Apple Silicon protocol executions. They do not
establish a performance claim unless the run manifest explicitly sets
`performance_qualified = true` and names a non-`none` claim.

| Run | Hardware | Workload | Pairs | Qualification | Claim | Tracking |
| --- | --- | --- | ---: | --- | --- | --- |
| [`physical-m4-f6aa2c2-1788238552`](physical-m4-f6aa2c2-1788238552/run.toml) | Apple M4, Mac16,1, 24 GB | `realistic-code-viewport` | 2 per lane | `false` | `none` | [Alpine #496](https://github.com/dbuddha/alpine-gpui/issues/496) |

The run directory retains the environment window, both renderer A/A lanes, the
Alpine-to-GPUI lane, the untimed adaptation record, and their SHA-256 bindings.
The capture was admitted only after Alpine, GPUI, and the independent CPU oracle
produced identical BGRA8 output for the pinned realistic code viewport.
