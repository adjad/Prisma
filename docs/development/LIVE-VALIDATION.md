# Live hardware visibility prototype

**Historical first live milestone.** The subsequent [material stage](MATERIAL-VALIDATION.md) adds cutout texture alpha, solid-material reflections and one-bounce GI. Its results and remaining limits supersede the corresponding unimplemented items below.

This stage connects the Metal ray-tracing core to displayed Minecraft frames in the separate **26.2 Metal RT Development** instance. It is an experimental hybrid of the existing raster image and new ray-derived visibility. It is not the completed physically based lighting system.

## Executed behavior

- A main-thread cursor collects at most 512 block positions per rendered frame in a local 25×25×25-block volume. It preserves actual solid block-model triangles; it does not use the camera frustum.
- A single build worker receives immutable geometry arrays and builds a replacement native scene. Device ownership is retained across the job. The render thread accepts completed scenes only if their dimension generation and edit revision still match.
- Nearby block/section changes invalidate stale scenes. The tested pillar removal changed the scene from 1,732 to 1,668 triangles and removed the pillar's shadow. Lighting can temporarily fall back while a replacement snapshot is collected. Whole local scenes are still rebuilt; incremental chunk BLAS/TLAS updates remain pending.
- A compute pass is encoded into the renderer's existing command buffer after world rendering. It reconstructs camera-relative positions from reverse-Z depth and matches them against the ray scene. Failed matches receive no added attenuation.
- The exact world projection is captured after camera effects. Minecraft 26.2 passes **view rotation**, not projection, to `LevelRenderer.render`. Metallum's offscreen image is also vertically inverted before presentation. Both conventions are now accounted for.
- Four hemisphere rays estimate AO and four disk samples estimate sun visibility per half-resolution pixel. The sun direction follows the game's sky render state in the tested Overworld scene. A depth-weighted 3×3 spatial filter precedes composition.
- The native pass joins the renderer's Metal fence chain and returns without a GPU wait. It multiplies the raster color by visibility factors and preserves alpha. Hand/HUD rendering occurs later.

## Evidence

| Check | Result | Artifact |
|---|---|---|
| Native frame pass | 126 pixels changed in the controlled 64×64 test; zero-strength color and alpha preserved | [Frame proof](rt-core/results/frame-proof-oriented.json) |
| Actual game image | Directional pillar/stair shadows and additional contact AO are visible | [Effects on](screenshots/capture-live-aligned-on.png), [zero strengths](screenshots/capture-live-aligned-off.png) |
| Quantitative A/B | Shadow-floor mean RGB changed by approximately 90–93 levels; selected HUD and hand regions were pixel-identical | [Region comparison](runs/live-aligned-comparison.json) |
| Block edit | Removed blue pillar no longer casts a shadow; other fixture geometry remains | [Removal](screenshots/capture-live-pillar-removed.png) |
| Ray-query regression | Known triangle queries remain correct after live shader additions | [Result](rt-core/results/live-final-ray-regression.json) |

The earlier `capture-live-on/off` comparison produced zero difference and was rejected. Captures named `capture-live-corrected-*` show the intermediate orientation error and are not accepted results. The accepted pair is **`capture-live-aligned-on/off`**. Clouds move between captures; the image checks use fixed geometry, hand and HUD regions.

## Initial live performance samples

Three ten-second built-in client profiles at actual 1920×1200 and the 60 cap measured 59.62–59.74 renderer FPS, with CPU frame-loop p95 17.19–17.41 ms. Heap samples ranged approximately 494–1,229 MiB. [Per-pass results](runs/live-smoke-results.json). These are CPU renderer-loop statistics, not measured display scanout or GPU-only timings. The other Prisma test JVM remained running; the fixture is small and the live RT volume is local. No full RT performance acceptance is claimed.

## Limits and next requirements

- AO is visibly noisy at four samples. No temporal history, motion vectors or MetalFX denoising is implemented yet.
- Composition currently attenuates Minecraft's existing baked/raster lighting. This can double-count occlusion and is not a physically separated direct/indirect lighting model.
- The live scene includes only the `SOLID` block-model layer. Cutout foliage, glass, fluids, entities and block-entity meshes require dedicated material/geometry support. The earlier model snapshot retains their classifications, but that does not establish rendered transparency support.
- The volume is 25 blocks across, with a two-block boundary fade; it is not the planned eight-chunk RT radius. Streaming, per-section acceleration structures, update budgeting and cache residency still need development and full validation.
- Local area lights, general material reflections, GI, temporal reconstruction and a new-renderer voxel fallback are unfinished. The preserved Prisma instance remains available with its existing voxel lighting.
- The initial short live frame-time samples use a simple fixture; the tuned Prisma game was also running. They are development observations, not full acceptance at 1920×1200/60 FPS or a substitute for the final 20-minute RT run.

## Controls

The development instance starts with `-Dmetallum.rt.mode=hybrid`. `proof` runs only the initialization intersection test; `off` retains raster rendering. Independent Java properties `metallum.rt.ao` and `metallum.rt.shadows` accept strengths from 0 to 1, defaulting to 0.65. User-facing persistent settings and unsupported-feature reporting still need work.

The guarded development helper accepts `live-on`, `live-off`, `ao-only` and `shadow-only`; `live-off` sets both strengths to zero while retaining the pass for a controlled visual comparison. It does not disable GPU workload. Fixture commands and screenshots operate only on the development copy.
