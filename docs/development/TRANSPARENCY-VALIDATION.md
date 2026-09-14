# Water and glass: implementation and validation

This is the initial transparency-stage record. [The next stage](TRANSMITTED-LIGHT-VALIDATION.md) adds indirect light at refracted hits and full-resolution glass edge repair; its current images and measurements supersede those limits below.

This stage extends the source-built development renderer. The preserved Prisma installations are unchanged. The full requested renderer remains unfinished; water appearance and transmitted secondary lighting still need improvement.

## Implemented

`FluidSceneCollector` invokes Minecraft 26.2's actual `FluidRenderer.tesselate`, captures the complete vertex output, resolves still/flow/overlay sprites from `FluidStateModelSet`, and converts section-local coordinates to the ray scene's origin. It preserves sloping fluid corner heights and waterlogged blocks. Reversed duplicate raster faces are removed because Metal triangle intersections are already two-sided. Biome tint comes from the fluid model's tint source; baked cardinal lighting is not copied into material albedo.

The scene now includes translucent baked quads. Glass is classified as a dielectric, including its clear texture pixels, rather than alpha-tested holes. Water uses IOR 1.333 and glass uses IOR 1.5. These are development material defaults, not resource-pack PBR data. Water has an explicit absorption-density default of 0.4 per block; sprite color and tint determine the per-channel absorption coefficients.

The Metal shaders implement exact unpolarized dielectric Fresnel reflectance, Snell refraction, total internal reflection and Beer–Lambert attenuation. Secondary visibility rays pass through transparent interfaces instead of treating them as opaque. Alpha-tested foliage still rejects transparent texels. Primary reflection and refraction share the specular transport output and its control. Refracted rays shade hit geometry from its material, emission and direct sun. This replaces the corresponding portion of the prelit raster image rather than adding a second transmitted copy.

The live primary ray can select a transparent surface in front of the opaque raster depth. The temporal position guide uses the actual interface position; the composition depth guide retains the raster depth for matching. This supports transparent surfaces in front of sky while preserving opaque foreground occlusion.

## Executed native GPU checks

All tests below executed on the Apple M5 Pro through Metal hardware intersection queries with Metal API validation enabled.

- [Transmission proof](rt-core/results/transmission-proof.json): clear parallel glass interfaces transmit approximately 0.9216 of normal-incidence radiance; water gives approximately 0.95966. An oblique ray hits a narrow emitter at the position predicted by Snell refraction, while a straight ray would miss. Total internal reflection, tinted boundary filtering, opaque blockers behind glass, retained alpha cutout rejection and conservative traversal-budget exhaustion pass.
- The same proof checks absorption: red radiance is approximately 0.61790 after one block and 0.41418 after two blocks of the controlled blue medium, matching exponential attenuation with coefficient 0.4.
- [Transparent frame proof](rt-core/results/transparency-frame-proof.json): transmitted red light composes in front of opaque depth and sky; a foreground depth surface retains the original blue image. Raster alpha remains unchanged.
- Existing hardware intersection, visibility, frame composition, texture/reflection/GI and temporal tests pass. Raw results have the `transparency-` prefix under `rt-core/results/`.

## Actual Minecraft geometry

[Still-water probe](runs/fluid-geometry-pool.json) and [flow/glass/waterlogged probe](runs/fluid-geometry-channel.json) record actual vertices, layers, sprites, IOR and ray hits.

| Sample | Observed geometry |
|---|---|
| Still source water | Two top triangles at local Y=0.8878889; downward ray from Y=2 hits at distance 1.1121111 |
| Flow near source | Top slopes from Y=0.8777876 to 0.7212219; uses `water_flow` sprite |
| Flow farther along channel | Top slopes from Y=0.4989996 to 0.3878889 |
| Glass surrounded by opaque blocks | Exposed top is present as translucent geometry, IOR 1.5, transmission 0.98, alpha testing disabled |
| Waterlogged bottom slab | Water surface at Y=0.8878889 and the slab top at Y=0.5 both survive extraction |

These are geometry checks in a contained copied-world fixture, not a complete validation of every fluid state or resource pack.

## Current limits

The corrected glass image still has thin bright edge artifacts against sky; its temporal/depth reconstruction is not accepted as finished. The pool comparison exposes a visible quality limitation: fully traced transmission appears flatter and darker than Minecraft's animated, prelit water. Refraction endpoints currently receive direct sun and emission; indirect illumination of those endpoints, animated wave normals, a complete sky environment and synchronized fluid texture animation are unfinished. The dark pool-wall edges are not an accepted final appearance.

Media use oriented boundaries with a single current medium. Nested or overlapping media, underwater camera transport, volumetric scattering, dispersion and caustic focusing are not validated. Straight shadow rays attenuate through interfaces but do not bend toward the light. Transparent boundary traversal is limited to 32 visibility layers and 16 refracted layers, with conservative termination. Glass uses a thin boundary color-filter approximation when absorption density is zero. Water absorption is a configurable-engineering default in source, not a measured optical property of Minecraft water.

The ray scene is still a local 25-block cube. Animated entities, eight-chunk BLAS/TLAS residency, MetalFX execution, a voxel fallback in the new renderer, persistent quality controls, broad mod compatibility tests and final sustained performance acceptance remain open.

## Earlier water timing and comparison (before angular-shadow correction)

The pre-correction absorption build ran unpaused at an actual 1920×1200 drawable (960×600 logical window), Custom 12/8 chunk distances, temporal reconstruction enabled, one GI bounce and a 60-FPS cap. [Three ten-second profiles](runs/water-transmission-cap60-results.json) measured 59.55–59.67 CPU frame-loop FPS, p95 17.28–17.48 ms and a worst frame of 25.01 ms. Sampled Java heap ranged from roughly 513 to 1,607 MiB; this excludes native renderer allocations and is not total unified-memory use.

[GPU timing](runs/water-gpu-timing.json) averaged 7.25 ms over 4,380 completed renderer command buffers in the surrounding interval. This includes raster and RT commands on that buffer; it is not isolated RT time, complete presentation latency or a maximum-throughput measurement. A fresh 20-minute complete-renderer acceptance run remains required after the missing features and visual quality are addressed.

The same steep-angle pool view with an off-screen red wall present versus removed changes the selected pool region by approximately +0.80 red, −1.05 green and −1.52 blue channel levels. [Raw measurements](runs/water-live-comparison.json). This contribution is subtle at water's low Fresnel reflectance at that angle; the removal also changes scene occlusion and GI, so the comparison alone does not isolate reflected energy.

The original pool image is `screenshots/capture-water-before.png`; the intermediate absorption build is `screenshots/capture-water-final.png`; the latest corrected build is `screenshots/capture-water-corrected.png`. These show the actual appearance, including its remaining shortcomings. Intermediate `capture-water-after.png` predates absorption and is retained as debugging evidence.

## Angular visibility correction and actual glass comparison

The live glass fixture exposed false total internal reflection in **straight shadow rays**. Those rays retain the exterior direction, so applying an internal-to-air exit angle is inconsistent. The corrected visibility approximation uses the exterior-angle Fresnel term at each boundary. Actual refracted transport retains its proper entry/exit IOR calculation and total internal reflection. The added oblique visibility regression measures 0.875114 transmission through the two ideal glass boundaries and agrees with the independent expected value.

The corrected game image is `screenshots/capture-glass-corrected.png`, compared with `screenshots/capture-glass-before.png` at the same camera. [Measured image-space boundary](runs/glass-live-comparison.json): the blue/white transition shifts from X=830 to X=838 over the central sampled strip. The method requires a 40-pixel neutral-color run to reject the narrow bright glass frame. This supports the live refraction behavior; the native narrow-emitter test independently verifies Snell's law.

`capture-glass-after.png` contains the earlier dark-band bug and remains as debugging evidence. It must not be treated as the corrected result. The interactive comparison uses only the corrected water/glass images. Earlier performance files remain historical; corrected profiles have `glass-corrected` and `water-corrected` names.

## Corrected-build performance

The installed build SHA-256 is `9849748d3461503f7a73dda988d819296dee44ef0908d7f120c144032386d498`.

| Scene, three ten-second passes | CPU frame-loop FPS | CPU frame-loop p95 | Mean renderer command-buffer GPU time |
|---|---|---|---|
| Glass | 59.51–59.78 | 17.07–17.56 ms | 7.77 ms |
| Water | 59.58–59.61 | 17.42–17.50 ms | 7.59 ms |

[Raw corrected measurements](runs/transparency-corrected-performance.json). Both tests used 1920×1200, the 60 cap, temporal reconstruction and one diffuse bounce. These are local-scene development measurements; they do not establish the final broad-scene or sustained 60-FPS target.

## Rollback

Close the development game before changing its mod JAR. `runs/renderer-backups/634df0b196baaf5552b532f5bb77e30d2788222cb201e25123960053a053f211.jar` is the prior temporal/GI build. Restore it under the installed name `metallum-0.0.24-rt-dev.1.jar` only in the marked development instance. Alternatively, launch the preserved tuned Prisma instance. The fixture commands and helper actions touch only the copied development world; original saves remain separate.

The corrected-build off-screen-wall comparison is [recorded separately](runs/water-corrected-live-comparison.json). At the same measured pool region its mean channel change is +0.56, -0.74, -1.07 (R, G, B). The visible contribution remains subtle.

[End-of-stage system snapshot](runs/transparency-system-snapshot.json) confirms AC power. Java process RSS was approximately 2.21 GiB; system-wide swap use was 2,131 MiB. This is a single snapshot, not total GPU allocation, peak memory, or swap growth attributable to this renderer.
