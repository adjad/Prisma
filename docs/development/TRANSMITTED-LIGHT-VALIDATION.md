# Indirect transmitted lighting and edge coverage

This stage improves the existing water/glass implementation in the source-built development renderer. It does not complete the full requested renderer.

## Changes

The dielectric traversal now exposes its opaque endpoint, remaining medium and throughput to the diffuse integrator. After refraction through glass or water, the renderer evaluates direct lighting and then samples one to four diffuse segments according to the existing GI quality tier. These paths can cross additional dielectric boundaries. A visible environment contributes radiance on a miss, while geometry occludes it. This addresses the missing indirect light at refracted hits without adding an arbitrary ambient brightness floor.

The feature follows `metallum.rt.gi`; `metallum.rt.transmissionGi=false` disables only the new endpoint indirect term for comparisons. Medium tracking remains a single current medium; nested/overlapping media and full underwater-camera transport are still incomplete.

A separate compute pass finds depth discontinuities and evaluates those pixels at the actual output resolution, using the same material/ray shader as the half-resolution pass. It uses eight samples per effect at classified edges. The main image retains four half-resolution samples and temporal reconstruction. The compositor uses the edge result at those pixels, including a neutral result when an opaque foreground surface prevents the ray effect. This repairs coverage that cannot be recovered from missing half-resolution samples. `metallum.rt.edgeRefine=false` disables the repair for controlled comparisons.

The edge pass allocates one RGBA32F and two RGBA16F full-resolution textures: approximately 70.3 MiB at 1920×1200, excluding resource padding. Edge samples currently lack their own temporal history; dynamic thin-edge noise and broader scene coverage remain validation work.

## Native GPU evidence

- [Transmission GI proof](rt-core/results/transmission-gi-proof.json): an off-screen red emitter contributes approximately 0.1917 red radiance to a white floor viewed through glass. Disabling the endpoint indirect term removes that contribution. Visible environment lighting and an occlusion test pass. The latter leaves a small clear primary aperture to the white floor while a black enclosure blocks its indirect hemisphere, so the test does not merely hide the receiver from the camera.
- [Edge coverage proof](rt-core/results/edge-frame-proof.json): a synthetic one-pixel alternating depth pattern causes the half-resolution pass to miss all 128 sampled transparent pixels. The repair recovers all 128, preserves all 128 foreground pixels and retains raster alpha.
- Existing material/reflection/GI, temporal, frame and dielectric-optics tests pass after the changes. Their new results are prefixed `transmitted-light-` under `rt-core/results/`.

The tests execute actual Metal intersection queries on the M5 Pro. They establish these local behaviors, not final visual quality or complete-scene performance.

## Live comparisons and query optimization

The water captures `capture-water-indirect-off.png` and `capture-water-indirect-on.png` change only the new endpoint indirect-light term. [Measured regions](runs/transmitted-light-live-comparison.json) show mean increases of approximately +7.62/+8.62/+13.87 RGB levels on the pool floor and +39.45/+42.05/+46.69 in the sampled left pool-wall region. The sampled hand region is pixel-identical. These are image-space measurements of this fixed fixture, not calibrated radiometry.

`capture-glass-edges-off.png` and `capture-glass-edges-on.png` change only edge repair. The conspicuous bright missing-coverage gaps disappear. The repaired pixels still have fine sampling grain because they do not share the main temporal history. Clouds move between screenshots; the synthetic edge proof independently establishes exact coverage and foreground preservation.

The first glass stress run with these features measured only 55.83–56.01 FPS. Investigation found redundant primary AO/sun rays: transparent pixels force those raster attenuation factors to unity and use their traced reflected/refracted radiance instead. Skipping those unused queries keeps the same physical light paths and eight edge samples. The optimized build is measured separately below; the earlier `glass-indirect-edges-cap60-results.json` remains as evidence of the regression.

The optimized source uses the same frame-material shading function for half-resolution and edge work. Skipping unused rays changes the subsequent random sequence, but not the number or distribution of reflection/refraction/GI samples. Existing frame and one-pixel edge tests pass again. `capture-glass-light-optimized.png` records the installed optimized result.

## Remaining work and rollback

Animated water normals, synchronized fluid texture frames, wet-material controls, complete environment lighting, nested/underwater media, dynamic entities, larger chunk acceleration structures, MetalFX, playable voxel fallback and final sustained performance/compatibility acceptance remain open. The full objective is not achieved.

Close the development instance before replacing its JAR. The preceding stable transparency build is preserved at `runs/renderer-backups/9849748d3461503f7a73dda988d819296dee44ef0908d7f120c144032386d498.jar`. Restore it only under the existing mod filename in the marked development instance, or launch the separately preserved tuned Prisma instance. [Original preservation check](runs/original-preserved-transmitted-light.json) reports no changes to the original instance and all 14 tuned-instance mods retained.

The installed optimized renderer SHA-256 is `df5a0f916b05249b52ec30cd2fec818c6d0a3b2cd7dadf088d47eecdaa8e1422`. Its packaged shader was compared byte-for-byte with the current shader source.

## Optimized live measurements

Three ten-second profiles per scene, on AC power at actual 1920×1200, 60 FPS cap, one GI bounce, temporal reconstruction, transmitted GI and eight-sample edge repair:

| Scene | CPU frame-loop FPS | CPU frame-loop p95 | Mean renderer command-buffer GPU time |
|---|---|---|---|
| Glass | 59.68–59.76 | 16.88–16.93 ms | 16.71 ms |
| Water | 59.35–59.62 | 17.39–17.65 ms | 7.67 ms |

[Raw timing summary](runs/transmitted-light-optimized-performance.json). The glass stress view is near the 16.67 ms GPU frame budget and leaves little headroom. The worst sampled water frame was 29.39 ms; its cause has not been isolated. CPU frame-loop timing is not presentation timing. These local scenes and short runs do not replace the final broad-scene, mod-interaction and sustained-session acceptance.
