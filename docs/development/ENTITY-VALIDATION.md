# Posed entities and independent Metal instances

This stage adds a dynamic model stream to the local hardware-ray scene. It does not complete the renderer’s full entity, scene-coverage or temporal requirements.

## Architecture

All hardware ray queries now traverse an instance acceleration structure. The existing block mesh is a static bottom-level structure. Posed entities form a separate bottom-level structure; a top-level structure references both. User instance IDs carry triangle offsets so intersections resolve the correct combined vertex/material arrays. Compute encoders explicitly declare the indirectly referenced structures. This follows Metal’s instancing API. [Apple’s instancing guidance](https://developer.apple.com/videos/play/wwdc2021/10149/).

The native `rt_set_dynamic_mesh` stages validated geometry and local texture/material data. The next frame copies the payload and builds the dynamic and top-level structures into the caller’s command buffer, using its existing fence. It never waits for a GPU completion on the render thread. The static block structure stays intact. Identical geometry/material updates are skipped, and a zero-size update removes the dynamic mesh. Invalid input preserves the preceding staged scene. Resources remain retained through frame completion.

The current implementation combines the small local static and dynamic attribute buffers for shader indexing. It rebuilds the dynamic BLAS when the pose changes; per-entity instance transforms/refits, chunk BLAS/TLAS scaling and a larger scene remain future work. The base ray scene is still only 25 blocks across.

## Minecraft model capture

The collector enumerates nearby client entities independently of primary-view frustum/occlusion selection, extracts their render state and intercepts posed model submissions. It executes the actual model’s animation and vertex emission with the game’s pose transforms, captures triangle positions/UVs/tints, and restores saved model-part poses/visibility afterward. Texture identifiers come from explicit Fabric access-widener declarations for render setup texture bindings. Source textures are read from the active resource manager; dynamic textures with retained CPU pixels are supported. Cache entries track the GPU texture identity across replacements.

The stream includes supported opaque/cutout model submissions and model-based layers. Additive and translucent layers, held-item/custom-geometry submissions, block entities, and the first-person camera entity are not fully integrated. Invisible entities are excluded. The candidate limit defaults to 32 (configurable up to 128), with a 100,000-triangle and 16-million-texel native budget. Skipped models and unsupported texture sources are reported through the scoped entity diagnostic.

`metallum.rt.entities=false` disables only the dynamic ray geometry. The guarded `rt-entity-diagnostics.jar` accepts `on`, `off` and `inspect-LABEL`; it checks the exact development directory before acting. The game’s normal raster entities remain visible in both modes.

Changed dynamic geometry currently invalidates lighting history to avoid retaining an obsolete shadow/reflection. This is conservative and can cause visible noise during animation. Per-vertex/entity motion and selective lighting-history rejection remain required before final temporal acceptance. MetalFX remains optional.

## Native evidence

[Dynamic frame proof](rt-core/results/dynamic-frame-proof.json) checks exact known ray distances and static/dynamic primitive offsets before/after moving an emissive red test mesh. The red material contributes indirect light through the combined scene. Removing it exactly restores the baseline pixels; invalid geometry preserves the previous dynamic image; repeating an unchanged mesh does not rebuild it. The static scene epoch remains unchanged. Alpha is preserved. Three changed mesh states and three completed dynamic frames are verified.

The original 4,104-ray CPU/GPU test, frame composition/history transfer, material transport, transparent foreground, and MetalFX tests pass after switching to the instanced structure. Result files use `instancing-` or `entities-` prefixes under `rt-core/results/`.

The new access-widener declarations caused Loom to generate a new local Minecraft compile JAR. Only that JAR and its POM were added to dependency verification metadata after checking the widened API. Existing external dependency checks remain enabled.

## Live evidence

A tagged, stationary cow on invisible support above an iron floor produces 120 posed triangles from `cow_temperate.png`. At player position `(201.5,162,201.5)`, yaw 135°, pitch 60°, the normal-sized cow is completely outside the camera view. It remains in the ray scene with the same 120 triangles. The all-effects before/after comparison shows its sun shadow on the floor.

The reflection-only comparison holds camera, time and all other effects fixed. Moving the cow from `(196.5,162,196.5)` to `(193.5,162,196.5)` moves its faint reflected silhouette. In a fixed floor region, the difference centroid shifts from `(957.85,484.94)` to `(848.23,403.17)` pixels. The original and moved captures have 3,553 and 4,235 pixels with an RGB-channel difference greater than 10; after removing the cow, there are none, and the maximum difference falls to 3. This threshold describes the image comparison; exact intersection correctness is established separately by the native proof. [Reproducible image measurements](runs/entity-reflection-comparison.json), generated by `../tools/measure_entities.py`.

Removing the cow leaves zero dynamic triangles. Dropped items are explicitly reported as unsupported model submissions; their normal raster images remain visible. The enlarged-model diagnostic uses Minecraft's scale attribute at 3× and reports proportionally scaled bounds, still 120 triangles. That enlarged cow has feet partly visible at the top of its screenshot, so it is **not** the fully off-screen proof. Its softer, faint floor reflection is a separate scaling check.

These are controlled local tests, not full entity/mod compatibility acceptance. The installed companion EntityCulling mod did not remove the off-screen cow from this collector. No performance mod was disabled for these tests. All changes affect only the copied development world. [Before/after viewer](BEFORE-AFTER.html).

## Continuous movement and short performance runs

The scoped `rt-entity-motion.jar` moves and rotates only the tagged cow for 60 seconds using server commands, then restores its original position and gravity. Client interpolation caused 6,827 dynamic geometry changes during a 6,835-frame observation interval. No rendering failure was logged. This is a repeatable command-driven transform/pose stress test, not acceptance of every naturally animated model.

During that interval the mean GPU time of whole command buffers containing raster and RT work was 4.93 ms. Capture time in one in-motion sample was 0.135 ms. Every geometry change currently resets lighting history; that cost in image quality remains open. [Interval evidence](runs/entities-motion-interval.json).

Three ten-second profiles were collected per configuration at 1920×1200, all effects enabled, 12/8 chunks, the existing 4 GB heap and all 13 companion mods. Entity-disabled, stationary entity-enabled and continuously moving entity-enabled runs each stayed around 119.8–120.0 CPU frame-loop FPS with the game's cap set to its unlimited value. Their 95th-percentile frame-loop times were approximately 9.22–9.30 ms. The roughly 120-FPS ceiling means these runs do not establish unconstrained GPU throughput or a precise percentage cost for entities. These are CPU frame-loop metrics, not presented frame intervals.

With the gameplay cap restored to 60, three further passes measured 59.42–59.72 frame-loop FPS and 17.30–17.59 ms p95. Those short steady-scene frame times meet the 20 ms threshold, but do not prove final 60-FPS presentation or sustained acceptance. [All profile ranges and raw archive references](runs/entities-performance.json).

The profiler packaging steps logged `Unable to parse version 27.0 to a codename` and `Negative index in crash report handler (18/19)`. Client metric CSVs and all twelve archives were produced, and the renderer continued running. No `RT live pass disabled` message appeared. The report-generation warnings remain unattributed; they are not evidence for disabling a performance mod.

The post-motion memory snapshot was 2,603,280 KiB process RSS and 2,107.12 MiB system swap in use, on AC power. RSS does not measure all native/GPU unified-memory allocations; the single snapshot does not measure swap growth. This stage does not complete the required 20-minute full-scene acceptance.

[Installed-build verification](runs/entities-build-verification.json) confirms the JAR, bundled native library and shader match the tested local build. [Preservation check](runs/original-preserved-entities.json) reports no original changed files and all 14 mods still present in the tuned Prisma instance.

## Reproduce and rollback

Run `../tools/measure_entities.py` to regenerate the screenshot measurements without modifying the PNGs. The fixture commands are under `fixtures/entity-*.mcfunction`; all attach helpers enforce the exact copied development directory. `rt-entity-diagnostics.jar PID off` reversibly disables entity ray geometry while retaining raster entities. `on` restores it. The helper's launcher command uses Java with `--add-modules jdk.attach -jar`.

For renderer rollback, close the development game normally, run `python3 tools/install_development_renderer.py --rollback-sha 7bdad10bca86e6b811f0afbd3e50a4d711e1c8c302b8f077af2cec4989d2536a` from the workspace root. Add `--dry-run` to verify the backed-up source without modifying the running game. The real install enforces the closed-game check and backs up the current renderer. The pre-entity renderer hash is `7bdad10bca86e6b811f0afbd3e50a4d711e1c8c302b8f077af2cec4989d2536a`. The original and tuned Prisma instances remain separate.
