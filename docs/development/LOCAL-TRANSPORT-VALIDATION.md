# Local-light reflections, diffuse bounces and transmission

This stage extends local illumination to reflected/refracted surface hits and diffuse bounce points. The installed development renderer is `ccdeb8e53ffbdedb942fd4acfd2699e66805f7fbb3e02c7561339600880ac18c`. Native tests and matching live captures are recorded below; final visual and sustained-performance acceptance remain open.

## Path behavior

Opaque secondary hits now evaluate emission, sun illumination and sampled local irradiance through the surface's diffuse BRDF. Reflected and refracted views therefore include surfaces lit by local lamps, even with GI disabled. Diffuse bounce vertices also sample local lights, retaining the finite one-to-four-bounce control. Dielectric endpoint resolution now carries its updated ray, surface and throughput into subsequent diffuse segments.

A straight diffuse segment that immediately reaches a sampled emitter assigns that emission to explicit light sampling, preventing duplicate energy. Mirror/reflection paths retain visible emission. Refracted segments retain emission because their paths differ from the straight visibility approximation. This is path partitioning, not a full multiple-importance sampler; averaged rectangular emitters, nested media, caustics and direct specular light sampling remain limitations. Primary diffuse local rays are skipped for fully metallic materials, whose diffuse BRDF is zero.

## Native tests

`rt-core/results/local-transport-capture.json` and `local-transport-shader.json` pass API/shader validation. The API-validated capture is `rt-core/results/local-transport-20260914.gputrace`.

- A mirror reflects a non-emissive red wall lit solely by a local lamp. Reflected red radiance is 0.15260 versus an independent irradiance-query-over-pi reference of 0.15391 (within 1%). A blocker between lamp and wall reduces that reflected contribution to zero while the wall remains on the reflection path.
- Red and blue non-emissive walls each produce 0.10588 in their respective indirect color channel; removing the lamp clears the indirect contribution.
- An emitter represented as geometry and an explicit lamp produces zero duplicate immediate diffuse emission, including the two-bounce setting. Its mirror image remains present. Without explicit light sampling, the test's BSDF estimator measures about 0.92993 from that same emitting geometry.
- Glass transmits a locally lit red surface with GI disabled (0.03776 red radiance); removing the lamp clears the contribution.

The affected frame, reflection, material, transmission, dynamic-scene, chunk, temporal, MetalFX and local-light tests pass in `rt-core/results/local-path-regression-suite.json`.

## Live validation

The copied development world used a temporary 5×5 concrete ceiling at y=162, a glowstone at (191,160,196), and the same downward-facing camera. The ceiling stays outside the primary view. Fixtures and their inverse are recorded in `fixtures/local-transport-*.mcfunction`.

With an iron receiver, reflection-only captures retain identical geometry and camera while local-light sampling is switched off/on. In `capture-local-reflection-before.png` versus `capture-local-reflection-after.png`, the fixed reflected-ceiling patch [700,760,1150,960] gains mean RGB [2.546,0.112,0.005] on an eight-bit scale. Changing the ceiling alone to blue produces a blue reflected patch in `capture-local-reflection-blue.png`. The lamp's own emission reflection is present even in the baseline. The screenshots retain noticeable stochastic noise; measurements are from individual frames, not a temporal confidence test. See `runs/local-reflection-image-measurement.json`.

Changing only the receiver to white concrete isolates diffuse transport. With local lighting enabled in every capture and AO/sun shadows/reflections disabled, GI-on versus GI-off for the red ceiling gains mean RGB [0.573,0.112,0.053] over receiver rectangle [720,325,1200,530]. The blue-ceiling pair does not show a clean blue-dominant change in these single noisy frames. This is a weak live result, not convincing visual acceptance for lamp-driven color bleeding. The controlled native test establishes the transport behavior; the bright baked Minecraft base and reconstruction still need work. See `runs/local-gi-image-measurement.json` and the unmodified `capture-local-gi-*.png` captures.

All captures are 1920×1200. Collection readiness reports 289 loaded columns, 2,775,690 triangles, zero queued/deferred sections, and 382,083,880 bytes of static shading data. No mods were disabled for this stage. Original-instance preservation is recorded in `runs/original-preserved-local-transport.json`.

## Short performance check and restoration

After collection settled, three ten-second all-effects runs at 1920×1200, three samples, dynamic temporal filtering, one diffuse bounce, MetalFX off and a 60 FPS cap measured 59.710, 59.746 and 59.546 CPU frame-loop FPS. Their p95 values were 17.175, 17.162 and 17.514 ms; p99 was 17.852–18.076 ms and the largest interval was 18.432 ms. Raw archives and summaries are in `runs/local-transport-all-effects-results.json`. This meets the short stationary p95 target but does not measure presentation intervals or establish a sustained result. The renderer's preceding 30-command GPU statistics averaged 7.302 ms; those command timings are not full-frame GPU measurements.

The temporary ceiling and lamp were removed, the receiver restored to iron, and the player returned to the previous platform camera through the inverse fixture. All effects remain enabled with the session settings above. Build/installed hashes and packaged native/shader matches are recorded in `runs/local-transport-build-verification.json`; `instance-manifest.json` records the development state. No original-instance files changed against the baseline manifest.

The full requested objective remains active; this stage does not establish final water quality, full-scene physical composition or sustained performance acceptance.
