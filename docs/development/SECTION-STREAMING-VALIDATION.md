# Full-height section collection and eight-chunk residency

The live collector now requests a square radius of eight chunks around the camera's chunk: 17 × 17 = 289 columns. It examines the full dimension height, including Minecraft 26.2's inclusive highest section index. World/model access remains on the main thread; the worker receives immutable section meshes and builds/reuses native acceleration structures.

## Scheduling and ownership

A distance-prioritized queue captures complete 16³ sections. Empty sections are skipped using `LevelChunkSection.hasOnlyAir()`. Block edits dirty the owning and dependent neighboring sections; chunk identity polling handles loading, replacement and unloading without forcing loads or consuming Sodium's tracking sets. Focus movement evicts out-of-radius payloads and reorders queued work. Resource/world resets discard the collector and its native cache.

Collection targets two milliseconds per frame and checks the deadline between groups of sixteen blocks. Individual model extraction and final array packing can overrun that target; it is not a hard real-time guarantee. Up to eight column identities are examined per frame within a portion of that time allowance. Scene publications are batched at least thirty frames apart, with one native build in flight. Immutable translated views share payload arrays during camera rebasing. Native cache reuse preserves unchanged section BLAS; top-level instances and packed shading buffers are republished.

The initial limit of two million triangles deferred 1,118 sections in the actual world. The revised default is four million triangles and 768 MiB of CPU mesh payload. These are safety ceilings, not measured renderer memory. The first complete scan held 2,775,190 triangles, 2,490 sections with geometry, 3,115 known nonair sections and 382,018,904 payload bytes. All 289 columns were loaded, with zero queued or deferred sections. Additional geometry, native AS data, scratch buffers, Java objects and renderer allocations are separate.

The shader's section-coverage flag (bit 11) fades at horizontal scene boundaries and allows geometry through the full dimension height. A native regression translates the test geometry above the old cubic coverage bound and verifies actual lighting, disabled-strength behavior, alpha and history handling. Secondary transport range now follows the horizontal scene width (272 blocks at radius eight). Missing/unloaded geometry is still incomplete information; this does not provide unbounded-world lighting.

Entities are considered throughout the resident bounds and prioritized by camera distance, with the existing explicit entity limit and supported-model restrictions. Animated entity attribute packing still duplicates static attributes and global temporal resets remain the default. Both are performance/quality limitations at this larger scene size.

## Evidence

- `rt-core/results/section-horizontal-coverage.json`: full-height confidence regression passed.
- `rt-core/results/section-frame-regression.json`: existing composition/history regression passed.
- `rt-core/results/section-chunk-regression.json`: reuse, edits, eviction, empty scenes and native 128-block ray passed.
- `runs/chunks-streaming-initial-*.txt`: first budget's incomplete coverage; retained as evidence of the limit.
- `runs/chunks-full-budget-*.txt`: complete initial scan with zero deferred work.
- `runs/section-probe-before-fixture-*.txt`: three rays miss and all three test block positions are air before placing fixtures.

## Live distance and lifecycle checks

After placing gold and copper blocks at `(329,161,201)` and `(73,161,201)`, rays from `(201.5,161.5,201.5)` hit each at distance 127.5. A vertical ray from `(329.5,164.5,201.5)` hit the diamond block at `(329,315,201)` at distance 150.5, confirming geometry from section Y=19. See `runs/section-probe-distant-present-*`.

Moving the player 160 blocks east changed the scene origin from `(64,-64,64)` to `(224,-64,64)`. The positive-X and top-section rays continued to hit; the negative-X ray missed after its column left the radius and unloaded. The new scene held 2,900,466 triangles with all 289 columns present, an empty queue and zero deferred sections. Native cumulative removals increased by 1,530. The player fell to the terrain after teleporting, so movement profiles include that vertical motion and streaming; they are not a pure horizontal-flight test. After returning, all three exact-distance hits reappeared (`runs/section-probe-after-return-*`). Removing the temporary blocks restored all three positions to air and all three rays to misses (`runs/section-probe-after-removal-*`). The player is back at the original fixture.

## Publication deduplication and sample controls

Completed sections compare immutable vertex, material and texture payloads before advancing the publication revision. Identical recaptures keep the previous payload and do not independently trigger native publication. Natural block/material changes still do. `runs/section-payload-proof.json` verifies defensive ownership, shared translations and detection of geometry/material/texture/identity changes; live `unchangedSections` counters show this path executing. The first long invalidation interval also contains unrelated world updates. A later isolated recapture at 15:14:30–15:14:33 UTC changed queued sections from one to zero and unchanged sections from 1,084 to 1,085 while preserving revision 5,367. See `section-probe-dirty-identical-1789398870919.txt` and the timestamped `chunks-identical-recapture-complete-*` result. This proves the requested identical recapture did not advance the publication revision.

`metallum.rt.samples` selects 1–4 samples per half-resolution pixel; edge repair uses twice that count. Zero (the default) retains automatic selection: four with custom reconstruction, one with the reduced-budget MetalFX path. Bits 12–14 encode this override; values above four are rejected by the native API. Native one/two-sample frame tests verify lighting, zero-strength behavior, alpha and history. The current experiment selects two samples with `metallum.rt.dynamicTemporal=true`; MetalFX is off. The renderer defaults remain unchanged until broader quality acceptance.

## Performance and limits

All measurements below are Minecraft CPU frame-loop profiler results at 1920×1200 with a 60 cap. They are not presented-frame measurements. No generated frames count toward them.

| Configuration and scene | Average frame-loop FPS, three passes | p95 frame-loop time | Evidence |
|---|---|---|---|
| Full radius, initial platform, four samples | 59.82–59.97 | 16.67–16.75 ms | `runs/section-radius8-cap60-results.json` |
| 160-block move and subsequent terrain view, four samples | 44.15–47.08 | 21.82–50.74 ms | `runs/section-radius8-camera-move-results.json` |
| Same terrain, MetalFX reduced ray budget | 51.26–55.64 | 17.90–24.99 ms | `runs/section-terrain-metalfx-results.json` |
| Same terrain, final deduplication build, custom temporal, two samples, dynamic filter on | 59.70–59.84 | 16.67–17.06 ms | `runs/section-terrain-two-samples-results.json` |

The parked terrain readback before optimization reported 46 FPS and about 21.9 ms whole-command GPU time. The combined optimized configuration meets the short CPU p95 target in this view, but its maximum individual frame was 37.67 ms. It changes sample count, temporal handling and publication behavior together; the measured gain is not attributed solely to one of those changes. First MetalFX profiling includes mode transition/warm-up, and its later passes still miss the FPS target. Historical runs remain intact.

A process snapshot after camera movement measured 4,777,760 KiB RSS (about 4.56 GiB), system swap usage 2,099.12 MiB, and AC power. Swap matched the earlier full-scene readback; this short interval is not a sustained memory-growth test. The final replacement-process sample at the returned fixture measured 6,378,176 KiB RSS (about 6.08 GiB), 68% system free memory by `memory_pressure -Q`, and 1,763.12 MiB swap. These two process samples are from different launches and do not establish a leak or a within-process growth rate. A two-millisecond collection target overran to 8.56 ms during startup in the final build. Native packed buffers and animated-entity duplication remain scaling costs. Full sustained performance, smooth streaming, high-quality dynamic reconstruction and broader world/mod acceptance remain required.


Profiler archive packaging again emitted the existing macOS 27 codename warning and negative-index crash-report-handler messages. Each requested client metric archive was produced, and subsequent live renderer frames continued. No RT-pass failure is present in this run. These messages are recorded individually rather than treated as a mod conflict.

The current instance manifest records the installed JAR and session-only sample/filter settings. To return to the prior cache-only renderer, close the development game and run `python3 tools/install_development_renderer.py --rollback-sha 7a49267d624a42ca16731ff4a7adbaf57afa325b4797eef4df68cdde9cdd0b35` from the workspace. The installer validates the named backup and preserves the current JAR. Original and tuned Prisma instances were rechecked unchanged (`runs/original-preserved-section-streaming.json`).
