# HDR highlight range and display mapping

This stage preserves scene-linear lighting through reconstruction and adds a display transform for the experimental traced-surface mode. It does not change the balanced preset's hybrid lighting mode.

## Implementation

Reflection, indirect and local-light buffers now use RGBA32Float in the current frame, temporal history and full-resolution edge pass. Normals and motion retain their existing formats. MetalFX input/output color also use RGBA32Float. At 1920×1200, these format changes add a calculated 92.29 MiB of texture storage, plus 35.16 MiB when MetalFX is allocated. These are allocation calculations, not measured process memory.

`RtFrameParameters` extends from 144 to 160 bytes with exposure EV, the tone-map toggle and two zero-reserved fields. The native, Metal and Java layouts change together; temporal parameters become 272 bytes. Native validation rejects nonfinite exposure, values outside -8..8, invalid toggles and nonzero reserved fields.

The display transform is peak-channel compression: multiply nonnegative radiance by `2^exposureEv`, then divide all three channels by `1 + max(R,G,B)`. This preserves RGB ratios in linear space and rolls highlights toward the display maximum. It is an artistic display curve, not a light-transport correction or HDR-display output mode. Extremely bright peaks can still round to white in an 8-bit target.

Apply the transform after temporal reconstruction, only to the traced surface contribution, before blending radius coverage with the original raster image. With MetalFX enabled, the pre-denoise color stays scene-linear; its alpha carries raw coverage. Final presentation reads that coverage and a separate raster snapshot, maps reconstructed surface radiance, and restores raster alpha. Sky and unsupported geometry keep their raster color. Exposure/tone-map changes do not invalidate scene-linear history.

Apple documents that the scaler's texture formats must match its descriptor, and that `preExposure` describes a premultiplication already applied to its input. This implementation leaves preExposure at one and auto exposure disabled; user exposure is applied once after denoising. Sources: [MetalFX denoised scaler descriptor](https://developer.apple.com/documentation/metalfx/mtlfxtemporaldenoisedscalerdescriptor), [preExposure](https://developer.apple.com/documentation/metalfx/mtlfxtemporaldenoisedscalerbase/preexposure). The installed Xcode SDK header and the actual M5 GPU are the implementation evidence.

## Controls

- `/metalrt set physicalLighting true` selects experimental traced-surface composition.
- `/metalrt set toneMapping true` enables highlight rolloff and exposure; default true.
- `/metalrt set exposureEv -1` halves display exposure; default zero, range -8..8, fractional values allowed.
- `/metalrt set toneMapping false` bypasses both mapping and display exposure.
- `/metalrt preset balanced` restores hybrid lighting, neutral exposure, three samples and one diffuse bounce.

All controls persist through the existing atomic settings mechanism. Hybrid rendering ignores these display controls. Forty settings checks and fourteen real Brigadier command checks pass, including signed fractional exposure, persistence and invalid values.

## Native evidence

`rt-core/HdrFrameProof.mm` renders actual ray-traced frames and reads back the resulting color target. `rt-core/results/hdr-frame-validated.json` passes with Apple's Metal API and shader validation enabled:

- Emissive linear red 100.000015 maps to 0.990099; -1 EV maps to 0.980392, matching independent scalar references.
- Linear RGB ratios, raster alpha, sky, partial coverage and hybrid display bypass pass.
- Exposure changes preserve both custom and MetalFX temporal history.
- MetalFX executes fourteen HDR frames before the captured statistics. A constant central region measures 100.247 against input 100; mapped output is 0.990175. This is approximate reconstruction, not exact energy preservation.
- An actual smooth-metal sun reflection reaches 7,750,547.5 linear radiance without half-float overflow; at -8 EV it maps to a finite 0.999967.
- Invalid native display inputs are rejected before encoding.

The first 64×64 fixture let the denoiser's spatial neighborhood span the coverage transition: its measured central red was 70.21. A 256×256 fixture separates the constant interior from that transition and measures within 1% of the input. This exposes sensitivity at small regions and boundaries; it does not establish broad MetalFX detail/edge acceptance. The hybrid comparison uses identical frame/reset conditions to distinguish the display toggle from normal denoiser variation.

All fourteen existing GPU regression programs pass against the new ABI and buffers; see `rt-core/results/hdr-regression-suite.json` and the individual `hdr-regression-*` outputs.

## Live acceptance

The installed renderer SHA-256 is `bd5cf581efd588ec866008fe366678dd22654aa2259a12ad29fc376334f7d57c`. The game runs at actual framebuffer 1920×1200, logical window 960×600, render distance 12, simulation 8, radius 8, three samples, one diffuse bounce, full sun shadows, all lighting effects, physicalLighting true and MetalFX false. The copied Creative world is unpaused, on AC power, at fixed time 2000. Camera: player [195.5,159,196.5], yaw -90°, pitch 41.913044°.

Twelve frames per mode (`screenshots/series-hdr-matched-before/after-00..11.png`) use cap60 in both modes and change only tone mapping. Earlier captures made at different caps remain historical evidence and are not the displayed pair. In the previously defined [880,450,1010,740] highlight rectangle, fully white pixels decrease from 98.618% to zero, and no channel clips in the mapped patch. Mean RGB changes from [252.105,252.114,252.123] to [231.978,232.529,233.542]. The selected sky patch stays exactly [181,208,255]. Block divisions become visible through the highlight; primary textures remain softened and the gold pillar remains too dark. The curve also darkens midtones slightly, as expected. These are unaltered game screenshots; `runs/hdr-live-images.json` contains region measurements.

[Open the comparison viewer](BEFORE-AFTER.html).


Three uncapped baseline passes measure 119.83–119.90 CPU frame-loop FPS, p95 9.256–9.267 ms. Three accepted mapped passes measure 119.82–119.88 FPS, p95 9.247–9.269 ms. The first mapped pass overlapped screenshot capture and is excluded, replaced with a clean pass; the exclusion and selected archives are explicit in `runs/hdr-after-uncapped-accepted.json`. These results show no measurable slowdown at the observed ~120-FPS pacing limit; they do not quantify the display pass's standalone GPU cost.

At the final 60 FPS cap, three mapped physical-lighting passes measure 59.628, 59.722 and 59.611 FPS, with p95 17.421, 17.145 and 17.414 ms. All satisfy the short stationary p95 target. They measure CPU frame-loop timing, not presented frames; no generated frames are used. The earlier twenty-minute session belongs to an older build and does not establish this build's sustained or moving-scene acceptance.

A single post-profile memory snapshot reports RSS 7.38 GiB, system swap used 1627.12 MiB and the memory-pressure query's free-memory percentage 65%. It is not a growth measurement or a complete residency accounting; raw files are `runs/hdr-memory-*`.

The actual -1 EV command persists successfully and darkens the highlight patch to mean RGB [219.005,219.505,220.423], while the sky stays unchanged. Its twelve frames are `series-hdr-exposure-minus-one-*`.

MetalFX also executes successfully in the actual 1920×1200 game. `runs/statistics-hdr-metalfx-1789411700668.txt` records 1,854 completed frames and 1,854 history resets. Source inspection explains this: posed-entity changes invalidate global history while MetalFX is selected (`dynamicTemporal` is restricted to the custom filter). The images show boundary artifacts beside the pillar, including 2.16% fully white pixels in the highlight rectangle. This verifies format/encoding compatibility, **not** MetalFX temporal or visual acceptance. `series-hdr-metalfx-*` remains diagnostic evidence; MetalFX stays disabled in the balanced preset. Proper dynamic motion/validity handling and reflected-image guides remain development work.

The balanced preset and original platform camera are restored. No blocks, world time or companion mods changed in this stage. Original-instance verification reports no changed files. `runs/hdr-build-verification.json` pins the installed JAR, packaged assets, source hashes, tests and final status receipt.

## Rollback

Close the development instance. Back up its current `minecraft/config/metallum-raytracing.properties`, then remove only `toneMapping` and `exposureEv` before returning to the prior direct-specular build (the old parser rejects unknown options). Run `python3 tools/install_development_renderer.py --rollback-sha 7ad34e78fd42b2d1beffb5e28eaa770507fd00e42fba230ddcc196eeb7bd7576`. The installer preserves renderer JARs by hash and restricts writes to the marked development instance. The original Prisma instance is separate.
