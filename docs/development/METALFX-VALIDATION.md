# MetalFX denoising integration

The source-built Minecraft 26.2 development renderer now executes MetalFX temporal denoising on the M5 Pro. This is an optional experimental mode. The original Prisma installation remains separate and preserved. Full renderer acceptance is still incomplete.

## Rendering path

A reusable `MTLFXTemporalDenoisedScaler` encodes work into the renderer’s existing Metal command buffer and fence. This uses the Metal command-buffer compatibility API, not a conversion of the renderer to `MTL4CommandBuffer`. The native test logs identify MetalFX’s fused-MXU path. No frame interpolation is enabled.

The first mode uses full-resolution 1920×1200 inputs and output (1×). It bypasses the previous custom temporal resolve to avoid filtering twice. The main RT pass supplies one sample per half-resolution pixel; classified depth edges receive two samples at full resolution. `metallum.rt.metalfxFullSamples=true` restores the earlier four/eight sample counts for controlled comparisons. The regular custom-temporal path retains four/eight samples.

Lighting is combined in linear RGBA16F before denoising and before the hand/HUD. Noise-free guides contain signed world-space normals, diffuse and Fresnel-aware specular albedo, linear roughness, reverse-Z interface depth, and previous-minus-current pixel motion. The actual game view/projection matrices are forwarded separately to MetalFX. Sky and unrepresented geometry are masked and explicitly preserve the unfiltered image. Reflection/transmission motion remains an approximation based on the static primary surface, with history rejection during movement; dynamic entities still need a geometry and motion stream.

For smooth reflection/transmission, deterministic rays also gather material properties at the reflected and refracted endpoints. Fresnel blends the guide properties for glass. This follows Apple’s primary-surface replacement guidance and avoids representing a transparent pane as a featureless black diffuse albedo. These auxiliary rays change denoiser guidance, not the sampled lighting integrator. [Apple’s 2026 integration guidance](https://developer.apple.com/videos/play/wwdc2026/359/).

Inputs use the texture usage requirements returned by MetalFX. The scaler and resources survive identical immutable scene rebuilds. History resets on scene changes, resize, frame gaps, camera discontinuity and effect/control changes. Unsupported devices retain the custom filter. Allocation/encoding failures use the renderer’s existing reported raster fallback.

Apple documents the denoiser’s linear lighting and material/motion inputs and its placement before post-processing. This implementation currently uses zero projection jitter at 1×; reduced-resolution jittered upscaling remains a separate integration step. [MetalFX guidance](https://developer.apple.com/videos/play/wwdc2025/211/), [API](https://developer.apple.com/documentation/metalfx/mtlfxtemporaldenoisedscaler).

## Native evidence

`rt-core/MetalFxProof.mm` executes 48 frames per mode, measures the final 24, then tests a history reset. Both modes use the same four half-resolution samples; the baseline has temporal filtering disabled. [Result](rt-core/results/metalfx-proof.json): 92.596% lower temporal variance, mean brightness 0.8421 versus 0.8444, 49 completed MetalFX frames, two history resets, zero alpha or unsupported-geometry bypass errors. A non-finite camera matrix is rejected while preserving the preceding valid matrices. This is a 128×128 static visibility fixture, not a gameplay performance claim.

Existing frame, transparent-foreground and one-pixel edge coverage tests also pass with the integration. The new reflected/refracted guide path requires the live comparisons below in addition to the native static test.

## Live validation and quality tradeoffs

The first full-sample, primary-surface-only guide mode ran the water fixture around 59.83–59.99 CPU frame-loop FPS, p95 16.68–16.92 ms, but softened texture detail. An initial glass snapshot reported 41 FPS and 24.17 ms renderer command-buffer GPU time. Those historical results motivated endpoint guides and the lower ray budget.

Three ten-second passes per configuration after warm-up, AC power, actual 1920×1200, 60 cap, one diffuse bounce, all other lighting effects enabled:

| Configuration | CPU frame-loop FPS | CPU p95 | Mean renderer command-buffer GPU time |
|---|---:|---:|---:|
| Glass, previous custom filter | 59.83–59.95 | 16.76–16.81 ms | Earlier same-stage snapshot ~16.47 ms; no matched interval mean |
| Glass, MetalFX 1/2 samples + endpoint guides | 59.89–59.95 | 16.67–16.79 ms | 14.28 ms |
| Water, MetalFX 1/2 samples + endpoint guides | 59.62–59.89 | 16.82–17.44 ms | 11.91 ms |
| Water, MetalFX 4/8 samples + endpoint guides | 59.85–59.95 | 16.71–16.92 ms | 14.99 ms |

[Timing summary and raw archives](runs/metalfx-performance.json). GPU interval means come from completed-command counters around unchanged scene intervals; they include the renderer command buffer, not just RT/MetalFX. CPU frame-loop measurements are not presentation intervals. These short local tests do not establish the requested broad-scene or sustained-session acceptance. No generated frames are counted.

Twelve screenshots per mode, at requested 200 ms spacing, provide an honest quality comparison against the *existing custom temporal filter*, which is different from the native unfiltered baseline. [Live measurements](runs/metalfx-live-noise.json), [water ray-budget comparison](runs/metalfx-water-sample-comparison.json):

- Reduced-ray MetalFX lowered variance in the sampled blue glass-wall region by 34.2%, but increased it by 9.2% on the white wall and 155% at the sampled boundary. Mean RGB differences stayed below one channel level in these regions.
- On water, reduced-ray variance was 0.384 on the floor and 23.125 on the sampled wall, versus 0.070 and 0.697 with the custom filter. Raising the MetalFX budget to four/eight samples reduced those values to 0.091 and 1.612. The custom filter is still steadier there; the new denoiser is not accepted as a blanket quality improvement.
- The sampled hand region is pixel-identical in both scenes. Endpoint guides restore water detail that the initial primary-only integration blurred away. Residual grain and fine-edge quality remain visible.

The [comparison viewer](BEFORE-AFTER.html) contains unmodified before/after screenshots and links to the earlier regression. A small water-camera translation and yaw change was captured at eight requested delays from 20 to 1600 ms. MetalFX continued executing, preserved the scene history (reset counter stayed at one during the move), and the late view showed the expected changed geometry without an obvious retained old silhouette. This is a limited motion check, not proof for arbitrary motion, moving entities, disocclusion or teleports.

The observed Java-process RSS snapshot was approximately 2.38 GiB. System swap was 2123.12 MiB at that point; this is not measured swap growth and is not attributed to Minecraft. Native guide/intermediate texture allocation is approximately 52 bytes/output pixel (114.26 MiB at 1920×1200), excluding resource padding and MetalFX’s internal allocations. Existing RT/history/edge textures remain allocated as well.

The native [Apple GPU capture](rt-core/results/metalfx-frame-20260914.gputrace) records a frame containing ray lighting, guide generation, MetalFX and final composition. [Capture-run proof](rt-core/results/metalfx-capture-proof.json). The final native object also stays retained through command completion when scene edits destroy its owning context.

## Controls and rollback

Development property `metallum.rt.metalfx=true` selects MetalFX. It defaults to false until visual and motion acceptance improves. `metallum.rt.metalfxSurfaceGuides=false` disables endpoint guide replacement for diagnosis. The scoped `rt-temporal-diagnostics.jar` provides `metalfx-on/off`, `fxguides-on/off`, and `fxsamples-full/low`. It verifies the exact development game directory before acting.

Close the development game before restoring a JAR. The pre-MetalFX working build is `runs/renderer-backups/df5a0f916b05249b52ec30cd2fec818c6d0a3b2cd7dadf088d47eecdaa8e1422.jar`; restore only to the existing renderer filename in the marked development instance. Alternatively use `metalfx-off` to return to the custom filter without changing the JAR. The tuned Prisma instance remains available separately.

Remaining objective includes water animation/wet materials, moving entities, area lights, chunk BLAS/TLAS scaling, voxel fallback, physical lighting separation, quality UI, broad mod/scene tests and final 20-minute performance acceptance. See [full status](PHASE-STATUS.md).

Installed final renderer SHA-256: `7bdad10bca86e6b811f0afbd3e50a4d711e1c8c302b8f077af2cec4989d2536a`. [Build/source checks](runs/metalfx-build-verification.json), [original preservation](runs/original-preserved-metalfx.json). The final build adds object-lifetime and pipeline-state guards without changing the measured lighting/guide shader.
