# Local lights in the frame pipeline

This stage connects the finite emitter estimator to actual rendering and derives emitters from Minecraft baked block faces. The development instance now uses candidate `3429f65d45f9e99b340944e52941a953dd5ee9b8c1ebdb164c4e07236903188f`; the prior tested renderer is retained for rollback. Matched live images and source/blocker update checks pass; performance results are recorded below.

## Frame behavior

Local diffuse lighting has its own half-resolution radiance target, sixth temporal history target and full-resolution edge target. It uses the same depth, position/primitive, normal and motion rejection as the other effects, with its own dynamic-history rectification. The final composition adds local lighting independently of the GI/reflection controls. The additional targets cost approximately 30.8 MiB at 1920×1200, excluding resource alignment (three half-size RGBA16Float targets and one full-size target).

Each frame retains the immutable light buffer through GPU completion. Real light changes invalidate history. The API/shader tests queue RGB lamps and then removal, destroy the scene before submitting any frame, and verify all outputs. Direct color remains present with GI and reflections disabled; removing the light restores the baseline with zero alpha errors. See `rt-core/results/area-light-frame-capture.json`, `area-light-frame-shader-final.json`, and the API-validated capture `area-light-frames-20260914.gputrace`.

## Minecraft emitters

Immutable section payloads cache rectangular emitters extracted from paired baked triangles. Translating a chunk reuses the cached shape and offsets its center. Emitted color uses the linear sprite average, including alpha coverage, material tint and the renderer's existing emission multiplier. This is a calibration approximation: alpha coverage and texture radiance are averaged over each rectangle, rather than sampled at the light endpoint. Nonrectangular/degenerate faces are counted as unsupported. Selection keeps at most 8,192 emitters, ordered by camera distance at scene publication; available/selected/unsupported counts are exposed for diagnostics. Moving cameras without a scene publication do not reorder a capped selection yet. The tested scene has 6,524 available/selected rectangular emitters, so none of those supported emitters are omitted. It also reports 1,769 unsupported emissive faces, which remain a coverage limitation.

The local-light toggle is the session property `metallum.rt.localLights`. Primary Lambertian local light is kept separate from diffuse GI. When a first diffuse path directly reaches a sampled rectangular emitter, that immediate emission is assigned to explicit light sampling; reflections and later bounces retain their emissive contributions. Texture-average emitters, dielectric approximations, local-lit secondary surfaces and full physical replacement of Minecraft's baked block lighting still need refinement. Direct specular response to local emitters is not implemented here.

The Java extraction test checks baked geometry, orientation, rebase sharing, linear sprite color and unsupported shapes (`runs/area-light-emitter-proof.json`). Frame/material/transmission/dynamic/chunk/temporal/MetalFX regressions pass (`rt-core/results/local-frame-regression-suite.json`).

## Importance sampling correction

The first live build used uniform selection over 1,024 of the scene's 6,524 rectangular emitters. It produced obvious isolated bright samples in `screenshots/capture-local-lamp-uniform.png`. That result was rejected as a usable lighting preset.

The corrected native sampler retains up to 8,192 emitters and builds a camera-neighborhood importance distribution from light area, luminance and inverse squared distance. A 10% uniform mixture gives every retained light nonzero probability. A binary search selects the light; the estimator divides by the actual rounded CDF interval probability. Camera cells are four blocks wide; changing the sampling distribution does not change emitted energy or invalidate lighting history. The 64-byte public light ABI is unchanged; the GPU representation is 80 bytes including its distribution. The immutable input buffer adds another 64 bytes per light. The game avoids repacking unchanged light lists every frame.

In `rt-core/results/light-sampling-proof.json`, 128 retained emitters give CPU-reference irradiance 1.240785, uniform mean 1.235894 and importance mean 1.240965. The per-estimate variance ratio is 0.000067 in that controlled test. This is not a full-game temporal-noise reduction claim. API/shader ownership and area-shadow regressions also pass after the sampler change.

## Live validation

The temporary fixture uses a 5×5 white-concrete receiver on the existing test platform, one glowstone block and one white-concrete blocker. Commands only alter the copied development world; restore commands are in `fixtures/local-light-restore.mcfunction`. The lighting-only comparison disables AO, sun shadows, reflections and GI in both images, then changes only the local-light toggle.

- `screenshots/capture-local-lamp-off-final.png`: same-camera reference with local lights off.
- `screenshots/capture-local-lamp-importance.png`: local light on, with all 6,524 supported emitters retained; obvious uniform-sampling speckles are gone, though some stochastic grain remains.
- `screenshots/capture-local-lamp-unblocked.png`: blocker removed, local light on.

Engine-native queries use fixed world receivers `(198.1,159.001,198.5)` and `(196.5,159.001,198.5)`, normals up, 4,096 samples and the actual published chunk geometry/light list:

| Scene state | Shadow receiver RGB irradiance | Control receiver RGB irradiance |
|---|---|---|
| Blocker present | (0, 0, 0) | (0.09591, 0.06155, 0.03161) |
| Blocker removed | (0.08084, 0.05188, 0.02665) | (0.09591, 0.06155, 0.03161) |
| Glowstone removed | (0, 0, 0) | (0, 0, 0) |

The source removal reduces the selected emitter count from 6,524 to 6,518. The control point's unchanged value after blocker removal helps isolate actual geometry visibility from a global lighting change. Raw readbacks are `runs/local-light-probe-blocked-*.txt`, `local-light-probe-unblocked-*.txt`, and `local-light-probe-lamp-removed-*.txt`.

Three ten-second all-effects profiles at 1920×1200, three samples, radius eight, dynamic temporal filtering and a 60 FPS cap measured 59.32–59.66 CPU frame-loop FPS, p95 17.32–17.70 ms and worst observed interval 22.10 ms. Scene readiness had 289 loaded columns with zero queued/deferred sections. Raw archives and summaries are in `runs/local-light-all-effects-results.json`. These are CPU frame-loop measurements, not presented-frame intervals; no generated frames are counted. This is a near-60 stationary result, not sustained acceptance. The temporary fixture was restored after testing. Final sustained, streaming and presentation acceptance remains open. Local-lit secondary surfaces, direct specular response, nonrectangular sources, and physical separation from baked block lighting remain incomplete; this is an implemented local diffuse/shadow stage, not the entire requested lighting system.

At approximately 6 minutes 33 seconds process uptime after the final restart, RSS was 6,335,360 KiB (about 6.04 GiB), and system-wide swap used was 1,675.12 MiB. This is a snapshot, not a same-process sustained-memory assessment. `runs/original-preserved-local-lights.json` reports no tracked original-instance file changes and all 14 mods in the tuned Prisma instance. For rollback after closing the development game, use `python3 tools/install_development_renderer.py --rollback-sha ca8f2caf1d35e00302f2c405faaa6eeacace45f9b8a647eb95bcbe463887ea59` from the workspace.
