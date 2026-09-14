# Metal RT development — active work

> This report preserves the local validation record. Paths and rollback commands
> that mention the original test workspace or Prism Launcher instances are
> historical evidence; the publishable source now lives at the repository root.

The user extended the original analysis/preset task to implementation. This directory contains a source-built Minecraft renderer, a native Metal ray-tracing core, and executed correctness tests. **Live hardware-derived shadows and AO now affect displayed frames in the development instance**, with substantial quality and coverage limits. This is not yet a complete replacement for Prisma's lighting. The tuned Prisma instance remains available separately. See [live visibility validation](LIVE-VALIDATION.md) and [material reflections/GI with matched images](MATERIAL-VALIDATION.md).

## What executes today

- MetalFX can now retain global history during posed-entity updates, with targeted rejection and output consistency checks. Native and live motion tests pass within their stated bounds; live floor/contact variation improves while dark-gold speckles worsen. MetalFX stays experimental and disabled in the balanced preset. [Dynamic MetalFX evidence](METALFX-DYNAMIC-VALIDATION.md).

- Full-float lighting buffers and post-reconstruction tone mapping preserve highlight range. In the matched iron-floor patch, clipped-white pixels drop from 98.62% to zero; sky pixels stay identical. [HDR display evidence and controls](HDR-DISPLAY-VALIDATION.md).

- Direct specular sampling now adds sun and area-light highlights to opaque materials in physical surface-lighting mode. CPU/GPU energy checks and actual sun-highlight comparisons pass. [Specular evidence](DIRECT-SPECULAR-VALIDATION.md).
- An opt-in surface-lighting composition removes baked ambient light inside ray-scene coverage. Analytic GPU tests and live color comparisons pass; dim lamp-driven GI and dark metals remain quality limitations. [Surface-lighting evidence](PHYSICAL-LIGHTING-VALIDATION.md).
- Persistent client commands are installed and restart-tested: `/metalrt preset balanced`, `/metalrt set reflections 0.5`, and `/metalrt status`. [Controls, evidence and rollback](PERSISTENT-CONTROLS.md).
- A twenty-minute stationary session now completes at 1920×1200 with twenty sampled profiles averaging 59.636 CPU frame-loop FPS and p95 17.355 ms. Swap does not grow; resident memory falls after an initial peak. Presentation, motion and streaming acceptance remain open. [Sustained-session evidence](SUSTAINED-VALIDATION.md).

- Custom reconstruction now tracks RGB ray-sampling variance. Controlled rare-event MSE drops 92.7% relative to the previous filter, with mean energy within 0.4%; matching live series show 73% less variance around a lamp reflection and 55% less in the reflected ceiling. Distant grazing-surface noise remains. [Sparse-sample reconstruction validation](SPARSE-TEMPORAL-VALIDATION.md).

- Local lamps now illuminate reflected/refracted surfaces and diffuse bounce vertices. Native tests verify visibility, color transport and duplicate-emission prevention. Live off-screen ceiling reflections respond to red/blue material changes; the white-receiver GI change is much weaker in the bright baked scene and is not a visual-quality acceptance result. [Local transport validation](LOCAL-TRANSPORT-VALIDATION.md).

- Local diffuse lighting and geometric shadows now execute in displayed Minecraft frames, with a separate temporal/direct-light channel and cached baked-face emitters. Importance sampling retains all 6,524 supported emitters in the tested scene. Live blocker/source updates pass; three all-effects profiles measure 59.3–59.7 CPU frame-loop FPS. Nonrectangular emitters and full physical composition remain incomplete. [Live local-light validation](LOCAL-LIGHT-FRAME-VALIDATION.md).

- Static and posed-entity shading buffers now remain separate. The matched full-radius platform improves from 78.7–80.4 to 119.8–119.9 uncapped CPU frame-loop FPS; native ownership and shader validation pass. Terrain quality-tier validation is recorded in [attribute-buffer validation](ATTRIBUTE-BUFFER-VALIDATION.md).

- Full-height section collection now spans an eight-chunk horizontal radius: 289 columns. Live scenes hold 2.78–2.90 million triangles without deferred sections; long rays and radius eviction pass. Selectable ray counts and deduplication support a short 59.7–59.8-FPS terrain result with two samples and dynamic temporal filtering. Sustained/streaming acceptance remains open. [Section streaming validation](SECTION-STREAMING-VALIDATION.md).

- Section geometry now has reusable Metal acceleration structures. Live material edits reuse geometry; block removal and restoration each rebuild only one affected section. Native tests include a 128-block ray, eviction and empty scenes. This historical stage used a 25-block collector; the subsequent section streamer expands coverage to an eight-chunk radius. [Chunk-cache validation](CHUNK-CACHE-VALIDATION.md).

- An optional dynamic temporal filter now preserves and rectifies lighting history during posed-entity updates. Native moving-signal tests pass; live contact-region variance falls 68% in the fixed-pillar fixture. Broader ghosting/material acceptance remains open, so it is off by default. [Dynamic temporal validation](DYNAMIC-TEMPORAL-VALIDATION.md).

- Posed opaque/cutout entity models now enter an independent dynamic Metal acceleration structure. A live cow remains in off-screen reflections and shadows; its reflection moves with it and disappears after removal. Native known-ray movement/material tests pass. Custom/item/block-entity geometry and stable temporal handling of continuous animation remain unfinished. [Entity validation](ENTITY-VALIDATION.md).

- Optional MetalFX temporal denoising now executes in the live renderer, with linear lighting, full-resolution material/depth/motion guides, reflected/refracted endpoint guides, and a lower ray-budget mode. Native noise/reset tests pass and live comparisons are recorded separately. [MetalFX implementation and validation](METALFX-VALIDATION.md).

- Indirect light now reaches refracted endpoints, and a full-resolution depth-edge pass repairs glass coverage missed by half-resolution samples. Native tests and matched game images verify both. [Latest light/edge validation](TRANSMITTED-LIGHT-VALIDATION.md).

- Water and glass now enter the hardware ray scene. Refraction, Fresnel reflection, transparent visibility and water absorption execute in the native/live path. Still/flowing/waterlogged geometry checks pass, but animated water appearance and broader material validation remain unfinished. [Water/glass validation](TRANSPARENCY-VALIDATION.md).

- Custom temporal reconstruction now reduces visible lighting noise, produces static-scene camera motion vectors, rejects invalid history, and preserves valid history across identical scene rebuilds. A separate two-bounce diffuse GI tier is available. [Temporal and quality-tier validation](TEMPORAL-VALIDATION.md).

- Material-aware hardware reflections and one-bounce GI now affect live frames. Matched game images verify an off-screen red wall reflected in an iron floor, removal of that reflection after a block edit, and red/blue color bleeding onto a white floor. Native tests also verify texture UVs, alpha rejection, roughness response and invalid material updates. [Full validation](MATERIAL-VALIDATION.md).

- Metallum source pinned to `fe3cc3b365dba03c2a7011d01086ef648ed42c9f`, built for Minecraft 26.2, Java 25, Fabric Loader 0.19.5 and Sodium 0.9.2. Loom is pinned to 1.16.3; Gradle 9.4.1 has an official distribution checksum. Resolved dependency hashes are recorded in the repository's `gradle/verification-metadata.xml`; these record the resolved bytes, not an independent security audit.
- `rt-core` builds a native library that creates Metal triangle acceleration structures, binds them to compute kernels and issues `metal::raytracing::intersector` queries. Geometry publication is atomic after a successful synchronous build. Invalid input preserves the previous scene.
- The Java 25 FFM bridge loads that library from the development JAR and executes a known-triangle test using the Minecraft renderer's Metal device. [The in-game result](runs/game-rt-proof.json) reports `intersectionProofPassed: true` and separately `effectsActive: false`.
- The block-model extractor reads actual baked quads, offsets, UVs and material classifications. It does not use camera-frustum visibility. A 25-block-wide snapshot produced 14,070 triangles from 6,803 blocks. The slab test measured height 0.5 and ray distance 1.5; the stair model retained 20 triangles. [Scene evidence](runs/scene-proof/scene-proof.json).
- Hardware visibility kernels implement cosine-weighted short-ray AO and shadows sampled over a finite angular sun disk. The original diagnostic buffers were followed by a live depth-reconstruction and composition pass, verified with matched game screenshots.
- The same visibility kernels executed on the Minecraft snapshot: 64,000 primary rays, 59,885 surface hits, and 32 samples per effect. [AO buffer](runs/scene-proof/ambient-visibility.png), [sun buffer](runs/scene-proof/sun-visibility.png). The sun direction is fixed for this diagnostic; foliage/glass are still treated as opaque, and this is not a full-material visual acceptance test.

## Executed tests

| Test | Result | Evidence |
|---|---|---|
| Two-triangle CPU/GPU comparison | 4,104 rays, zero mismatches; maximum distance error 8.24×10⁻⁷ | [JSON](rt-core/results/triangle-proof.json), [Apple GPU capture](rt-core/results/triangle-proof.gputrace) |
| Finite ray range, misses, back faces, shared edge | Passed; either valid triangle is accepted at the shared edge | `rt-core/Proof.mm` |
| Invalid update and invalid ray | Old committed scene remains usable; zero direction rejected | Same proof |
| Disabled setting | Reports fallback required and no active RT | [JSON](rt-core/results/disabled.json) |
| Java/native integration | Known hit distances and primitive identities passed within Minecraft | [Game status](runs/game-rt-proof.json) |
| Source renderer with Sodium | Copied world loaded at 1920×1200, Custom, 12/8 chunks and nominal 60 cap | [Live readback](runs/inspect-foundation-1789379680958.txt), [Screenshot](screenshots/capture-foundation.png) |
| Sun visibility and AO | Lit=1, blocked=0; near AO visibility 0.671875, far=1; all values finite/in range | [JSON](rt-core/results/visibility-proof.json), [AO](rt-core/results/ambient-occlusion.png), [Shadows](rt-core/results/sun-shadows.png) |
| Intersection regression after visibility additions | 4,104 rays still pass | [JSON](rt-core/results/triangle-proof-after-visibility.json) |

The controlled 256×256 visibility scene used 64 samples per effect and recorded about 1.21 ms GPU time. This is a tiny synthetic workload, not a prediction of complete Minecraft frame time. The explicit geometry/visibility probes remain diagnostic, synchronous work and may stall a frame. The newer live pass encodes into the existing frame command buffer without a CPU wait, while replacement scene construction runs on a worker. No full-scene RT performance target has been accepted.

## Build and reproduce

The native build uses `/Applications/Xcode.app` through a per-command `DEVELOPER_DIR`. It does not change the system's selected Xcode. Run from this directory:

```sh
sh rt-core/build.sh
cd rt-core
./build/rt-proof
./build/rt-proof --disable-rt
MTL_CAPTURE_ENABLED=1 ./build/rt-proof --capture results/new-triangle-proof.gputrace
MTL_DEBUG_LAYER=1 ./build/visibility-proof
```

Use a new capture pathname for each run. `trace.metal` must be in the current directory for the standalone executables. The development JAR packages the shader as a resource.

```sh
./gradlew --no-daemon build
```

The repository contains `src`, `rt-core`, and `diagnostics` at its root. Current build output is `build/libs/metallum-0.0.24-rt-dev.1.jar`; the installed validation build's SHA-256 is in [the manifest](instance-manifest.json). Upstream MIT attribution remains in the root `LICENSE`. Native source is under [MIT](../../rt-core/LICENSE).

## Isolated game installation

`26.2 Metal RT Development` uses copies of the closed original saves. It retains the 13 companion mods and replaces Prisma only within this development instance; the Prisma JAR is preserved under `disabled-mods`. The original `26.2` and tuned `26.2 Prisma — M5 Pro Test` installations retain all 14 original mods. Upstream telemetry invocation is disabled in this local source build.

`-Dmetallum.rt.mode=proof` runs the small intersection check on renderer initialization. The development instance now uses `hybrid` to additionally enable the experimental live visibility pass. Default `off`, an unknown mode, an unsupported device, or initialization failure leaves Metallum's raster renderer active. **Metallum does not yet contain Prisma's voxel lighting fallback.** For that lighting, launch the preserved Prisma instance. The native library is bundled only for arm64 macOS.

The explicit attach helpers under `diagnostics` are restricted to the exact development game directory. They do not transform bytecode or synthesize UI input. `scene-probe` calls `RtSceneProbe.capture` on the loaded client's main thread; its artifacts go to the development world's `rt-development` directory. The helpers disappear on game exit and are not installed in `mods`.

## Remaining implementation gates

See [requirement-by-requirement status](PHASE-STATUS.md); the complete user goal is not yet achieved.

1. **Scene lifecycle:** extend the live background-built local scenes to versioned chunk-section geometry, BLAS/TLAS updates, bounded asynchronous upload/build budgets and an eight-chunk resident scene. Main-thread collection is now prioritized by section and spread over frames; native packed shading buffers are still rebuilt for publication. Block-edit invalidation is visually verified, but dimension/resource-reload and long-session behavior still require broader tests.
2. **Materials and geometry:** texture sampling, biome tint and alpha-tested cutouts now work in the local scene. Improve glass/water transmission lighting, nested and underwater media, animated entity meshes, synchronized texture animation and PBR material overrides. The current 32-layer alpha rejection cap and nearest sampling need further validation.
3. **Frame integration:** depth, camera matrices, geometry normals and Overworld sun direction are connected to the live visibility kernels. Replace attenuation over the baked raster image with separated direct/indirect lighting to avoid double-counting occlusion. Add finite-size local lights and verify contact hardening quantitatively.
4. **Reflections:** local solid-block hardware reflections now have roughness, Fresnel, actual texels and off-screen hit shading. Finish water/glass visual quality and wet materials, dynamic entities, physically separated base lighting, environment radiance and larger scene coverage.
5. **GI:** one- and two-bounce diffuse transport are implemented; improve light sampling, reflected indirect radiance and separation from baked lighting, and validate the tiers across real scenes.
6. **Reconstruction:** static-camera motion vectors, temporal history rejection and noise reduction are implemented and locally tested. Complete dynamic-object/specular handling and execute supported MetalFX denoising/upscaling with correct guides.
7. **Fallback and validation:** a playable voxel fallback in the new source renderer, per-effect controls, repeated scene comparisons, 1920×1200/60-FPS measurements, mod-isolation tests as warranted, and a fresh 20-minute RT gameplay run. Previous Prisma measurements do not validate this new renderer's RT performance.

See the full [hardware RT specification](../analysis/HARDWARE-RT-ROADMAP.md). The goal remains active until these requested effects and their validation are delivered.
