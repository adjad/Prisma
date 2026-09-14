# Visual and compatibility validation

Tested in the copied creative world, using Minecraft 26.2, Prisma 0.1.2-A and all 14 original mods. Captures are direct game render-target readbacks at 1920×1200. Commands are sent to the integrated server through a helper that verifies the exact isolated-instance directory; no keyboard/mouse emulation or remote control service is involved.

## Observed results

| Test | Observation | Evidence / limit |
|---|---|---|
| Matched preset views | Nearby reflected structures and water remain visible at radius 8. The shorter 12-chunk render distance can remove distant terrain. | `capture-before-overview`, `capture-after-overview`, `capture-before-lake`, `capture-after-lake`; all PNGs are under `screenshots`. Camera/time/weather match; water, clouds and animals continue animating. |
| Off-screen reflections | With the camera pitched down 65°, the actual towers are entirely outside the image while their water reflections remain visible. | `capture-offscreen-reflections.png`. This establishes off-screen block tracing in this fixture, not unlimited range. |
| Glass / foliage / slabs / stairs | These materials and shapes render in the fixture, with visible water reflections of nearby scene features. | Overview captures. This is not proof of triangle-accurate reflection silhouettes or reflective glass surfaces. The inspected ray representation is voxel based. |
| Moving entity | A pig renders and moves in the primary view; a corresponding pig reflection was not established. | `capture-entity-at-water.png`. Static shader/voxel evidence also does not establish entity tracing. Do not blame EntityCulling or remove it for a feature this renderer lacks. |
| AO | Enabling VXAO darkens the wall/floor region and adds a visible fine dither pattern. | Matched `capture-interior-ao-off/on.png`; sampled region changes by about 3.5–4.9 intensity levels per RGB channel on average. This is a pixel comparison, not a photometric measurement. |
| Sun shadows | No directional cast-shadow change was observed when toggling the control at a fixed daytime value. | `capture-sun-off/on.png`; a static floor region `(200,560)–(800,760)` is pixel-identical. This agrees with the unused uniform in the inspected shader. It does not test every possible hidden path in future versions. |
| Point lighting | The point-light toggle changes the torch’s local illumination from cool existing block lighting to a warm contribution. Disabling it does not eliminate vanilla block light. | `capture-point-light-off/on.png`. The enabled result is not uniformly brighter; the color/lighting treatment changes. |
| Shadow geometry / distances | Changing an emitter’s distance from a blocker changes the illuminated footprint and visible occlusion boundary. | `capture-shadow-blocker-near/far.png`; this qualitative test does not validate a physically calibrated penumbra law. Voxel occupancy, falloff and dither affect the result. |
| GI / color bleeding | The red-wall room remains lit by existing/direct light; no general bounced red illumination onto the neutral surface was established. | Interior captures plus shader audit. Absence in one image alone is not proof; the missing transport integrator is the stronger evidence. |
| Block / light updates | Removing a wall block opens the hole; removing the torch removes its local warm contribution. Restoring both restores the geometry and lighting. | `capture-block-light-removed/restored.png`; settled images were captured after three seconds, so they do not measure exact update latency. The inspected periodic rebuild trigger is 60 frames, approximately one second at the final cap. |
| Particles | A burst of 400 flame and 400 smoke particles renders with both particle optimization mods enabled. | `capture-particles.png`. No broad particle-compatibility claim beyond this smoke test. |
| Streaming / rapid turns | Eight teleports, 80 blocks apart in X and 32 in Z, with 45° camera changes, exercised new terrain. | `capture-stream-0/4/7.png` and a separate streaming profile. This is a stress sequence, not natural mouse-driven traversal. |
| Dimension transition | The Nether roof loads, and the Overworld return restores the lakeside scene with reflections. | `capture-nether.png`, `capture-return-overworld.png`; runtime settings remain 12/8/8 and 60 FPS. This is not a full Nether-biome or End visual suite. |

Numerical image comparison data is in `evidence/image-comparisons.json`. Original captures have not been retouched. The HTML viewer provides matched preset views and the AO, point-light and sun-control A/B images.

## Mod decisions

No reproducible mod conflict was demonstrated in these tests, so all 14 mods remain enabled. In particular, chunk generation, block/light changes and particle bursts ran with C2ME, ScalableLux, AsyncParticles, Particle Core, ImmediatelyFast and EntityCulling present. These group smoke tests do not establish exhaustive pairwise compatibility. Individual disabling was unnecessary because there was no concrete defect to isolate. Missing renderer features and visible AO dithering must not be treated as evidence against unrelated performance mods.

## Sustained session

The selected graphics configuration stays at 12 render chunks, 8 simulation chunks, voxel radius 8, all original lighting controls enabled, a 4 GB heap and a 60 FPS cap. The 20-minute run includes stationary lakeside periods, a short Metal trace, additional blocker-distance checks, streaming and a dimension round trip. Per-frame profiles sample the beginning, midpoint and end; they are not a continuous frame-time log for all 20 minutes. Resource and power samples are collected every ten seconds. The session completed for 1,200.005 seconds without a game crash; six sampled frame profiles remained near the 60 cap. Full completion and resource statistics are recorded in BENCHMARKS.md.
