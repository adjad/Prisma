# Direct and indirect surface lighting

The new opt-in `physicalLighting` control replaces Minecraft's baked surface color inside valid ray-scene coverage with material emission, traced direct sunlight, sampled finite local lights, reflections/transmission and diffuse indirect transport. The existing hybrid composition remains the default and is restored by the balanced preset.

This addresses a specific limitation of the previous implementation: additive GI sat over an already ambient-lit image. A primary diffuse ray that missed the scene previously added no sky light because Minecraft's raster image already supplied ambient illumination. The new mode integrates the procedural sky on those misses and computes direct surface lighting explicitly. It does not use an arbitrary GI brightness multiplier.

Use `/metalrt set physicalLighting true` to enable it, `/metalrt set physicalLighting false` to return to hybrid lighting. The property saves through the existing settings store. Traced diffuse transport already includes visibility; the separate AO factor is not multiplied into this mode. The shadow control still blends sampled sun visibility. A value of 1 gives the fully shadowed direct-light calculation; artistic settings below 1 admit unoccluded sunlight.

## Native verification

`rt-core/PhysicalLightingProof.mm` executes the actual complete frame pipeline and reads GPU output. Metal API validation is enabled. The test verifies:

- A gray Lambertian surface under known directional sunlight matches its analytic reference: sRGB 0.452412 measured versus 0.452511 expected.
- Changing baked raster color from 0.05 to 0.95 changes the fully covered surface output by zero.
- An unilluminated surface has zero output despite a bright baked input; primary emissive material still emits with reflection and GI disabled.
- Unmatched depth retains the raster image and alpha is preserved.
- The sky integral agrees with the analytic cosine-weighted reference for a vertical surface.
- A neutral receiver receives only red or only blue indirect light from a lamp-lit colored surface outside the primary camera ray. The measured mean linear value is 0.080313 in the corresponding channel; GI-off returns zero.
- The existing hybrid branch retains its original baked image when effects are disabled.

Raw results: `rt-core/results/physical-lighting-second.json`. The earlier failed run is retained: native parameter validation initially rejected the new flag; the flag mask was extended before the passing rerun. `rt-core/results/physical-regression-suite.json` records 13 passing GPU regressions. `physical-lighting-build.log` records the successful Minecraft build and 31 settings / 12 command checks.

## Current limitations

Live comparisons now confirm the branch executes and isolate its transport behavior; three short stationary profiles also complete. This is the first explicit surface-lighting composition, not a finished physically based replacement renderer. It retains the procedural daylight model, finite ray radius and bounce budget, existing approximate material parameters and transparency limitations. Direct local-light specular sampling, physically consistent Fresnel energy sharing, atmosphere/weather integration, primary texture-detail preservation and broader motion acceptance remain. Sky and unsupported geometry outside valid coverage use the raster fallback. The transition at the ray-scene boundary can therefore reveal differing lighting models.

The prior 20-minute performance record belongs to the previous native renderer and does not establish acceptance for this new mode. Keep MetalFX off during initial comparisons; its guides need separate validation against the changed composition.

## Live scene evidence

The copied platform was captured before/after composition switching at the same camera. The new image is darker on metallic surfaces and loses some primary texture detail. This reveals missing specular transport and reconstruction quality; it is not presented as a finished visual improvement. The comparison also changes sun-shadow strength from 0.65 to 1.0, explicitly recorded in the viewer.

A reversible fixture uses a white-concrete receiver, red/blue ceiling and glowstone. Reflections are disabled for diffuse isolation. Twelve unaltered frames were captured per setting. At fixed day time 2000, GI-on minus GI-off raises receiver RGB by [10.610, 15.572, 25.636] on the 0–255 scale; procedural sky dominates. Changing only red ceiling to blue changes the red-minus-blue receiver difference to [0.855, -0.063, -0.386].

The exact original clock was saved, night 18000 temporarily selected, and the same color test repeated. Red-minus-blue receiver RGB is [1.991, -0.035, -1.297]. A five-block black-concrete shield then blocks the lamp’s direct illumination of the receiver while leaving an upward opening toward the ceiling. The shielded color difference is [1.228, -0.001, -0.419]. The result is visibly very dim: this supports color-dependent indirect transport but does not pass a convincing lamp-driven GI visual-quality gate. No image exposure or colors were altered to disguise the limitation.

Measurements are in `runs/physical-lighting-live-measurements.json`; all series retain their source PNGs in `screenshots/`. Receiver rectangle is [720,325,1200,530]. Individual-frame noise and the limited scene prevent treating these differences as broad quality acceptance. The shield, lamp, ceiling and temporary receiver replacement were removed; the exact clock was restored to 2000. Receipts: `runs/commands-physical-lighting-baffle-restore-complete.txt`, `runs/commands-local-transport-restore-complete.txt`, and `runs/physical-lighting-clock-restore.txt`.

## Performance and final state

Three ten-second profiles at 1920×1200, three samples, one bounce, full-height radius eight, all effects, full shadow visibility, custom dynamic temporal reconstruction and MetalFX off measured 59.622, 59.376 and 59.640 CPU frame-loop FPS. Corresponding p95 values were 17.393, 17.649 and 17.387 ms. Raw profiles and derived results are recorded in `runs/physical-lighting-all-effects-results.json`. These are capped stationary tests, not presented-frame timing, motion/streaming acceptance or a replacement 20-minute session.

After testing, `/metalrt preset balanced` restored the hybrid composition, three samples, one bounce, 0.65 AO/shadows and full reflections/GI, with the experimental property false. The new renderer remains installed in the development copy. Original-instance preservation passes with no changed original files. Build and source hashes are in `runs/physical-lighting-build-verification.json`. The prior controls renderer can be restored with `python3 tools/install_development_renderer.py --rollback-sha 994a6a0702bea85d7f2527af385a884efeed6e10aac06aae2d42c6728862342d` after closing the development game. If rolling back to that build, first remove only the new `physicalLighting` key from the copied instance's properties file: the older strict schema correctly rejects unknown keys. Keep a copy of the current file before doing so.
