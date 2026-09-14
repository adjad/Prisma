# MetalFX history during entity updates

This stage addresses the actual-game finding in `HDR-DISPLAY-VALIDATION.md`: every posed-entity update reset the entire MetalFX history. It does not by itself implement per-entity motion vectors or establish full reconstruction acceptance.

## Candidate implementation

With `dynamicTemporal=true`, native scene updates retain global history for MetalFX as well as the custom filter. The custom temporal pass also runs in MetalFX mode to produce surface-validity, lighting-innovation and sampling-variance information; MetalFX still receives raw current radiance, so its color is not filtered twice.

A separate half-resolution R16Float rejection mask marks invalid/disoccluded surfaces and significant changes in enabled lighting channels. Full-resolution MetalFX guides dilate that mask across a three-by-three half-resolution footprint and reject changed dynamic primary surfaces. This preserves history on unaffected static surfaces while conservatively rejecting animated geometry that has no object motion vectors yet.

An actual off-screen moving-shadow test found that MetalFX's reactive input alone did not fully clear stale output: the old shadow receiver remained at 0.390 rather than the expected 0.8 on the first moved frame, and 0.435 after removal. The revised candidate also bounds the presented MetalFX radiance using the current local sample range and variance during the existing 32-frame dynamic-response interval. Retained ray-sampling variance adds a three-standard-deviation margin so rare bright paths are not simply clipped to zero after a missed sample. Channel standard deviations are summed conservatively when combining reflection, GI and direct illumination.

This final consistency check precedes tone mapping and preserves sky/unsupported-geometry bypass. It does not rewrite the framework's internal history. Tests must therefore check frames after the response interval expires as well as the first moved frame.

## Tests and acceptance

- `MetalFxDynamicProof.mm` updates unrelated off-screen geometry every frame while comparing global resets against targeted rejection on a static noisy receiver.
- `TemporalProof.mm` independently verifies masks for stable surfaces, changing shadows, reflections, GI, local illumination, dynamic primary surfaces and disocclusion, alongside existing noise, reprojection and sparse-radiance tests.
- `MetalFxShadowProof.mm` traces an actual off-screen blocker, moves it to a disjoint location, then removes it. It checks old/new receiver illumination on the first changed frame and every subsequent frame through expiration of the response interval.

The new build is installed under SHA-256 `c03ccbf4d86037a24f41ce70fc82098a2be21c33fe80b56718647a44bd84ecb2`. The previous HDR JAR is preserved for rollback.

All eighteen GPU regression programs pass. The final static-region test reduces variance from 0.001060870 with global resets to 0.000434782 with targeted handling, a 59.0% reduction. Mean brightness changes from 0.843925 to 0.845416. The earlier mask-only candidate reduced variance 85.9% but failed the moving-shadow test; its higher smoothing result is not the accepted implementation.

The actual moving-shadow test passes 102 frames with one global history reset. The initially shadowed receiver measures 0.0101 versus 0.8029 at the lit receiver. On the first moved frame, the old location returns to 0.8005 and the new shadow measures 0.0254. On removal, the two receivers measure 0.8014 and 0.8016. Every subsequent checked frame stays within the preselected 0.05 dark / 0.75 lit bounds, including after the 32-frame response interval expires.

The off-screen emissive-reflection test also passes 102 frames with one global reset. Initial reflection red is 1.6043; moving the emitter produces 1.6965 at the new location and 0.0794 at the old location. After removal, the newly empty location is 0.0599. The preselected tolerance is 0.1, so this is bounded residual energy, **not zero reflection lag**. Proper moving-reflection correspondence remains open.

Seven independent rejection-mask cases pass alongside the prior custom temporal tests. Both actual motion proofs pass Metal API and shader validation. Raw records are `rt-core/results/metalfx-reactive-*-validated.json` and `fx-dynamic-regression-suite.json`.

## Live comparison

The copied world uses the fixed platform camera, time 2000, 1920×1200 output, render 12/simulation 8, radius 8, three samples, one bounce, physical lighting and tone mapping enabled, full sun-shadow strength, all effects, MetalFX enabled and cap60. A temporary cow tagged `rt_fx_dynamic_test` follows the same bounded 60-second trajectory for each variant. No world blocks or time settings are changed. Its dedicated motion helper and prepare/remove fixtures are scoped to the development instance.

Both 60-second motion runs completed: `fx-entity-motion-1789413047433-complete.txt` reports 574 updates over 60.006 seconds, and `fx-entity-motion-1789413233292-complete.txt` reports 576 updates over 60.010 seconds. The timer skips queuing work when a preceding update is still pending.

The before snapshots have one reset per encoded MetalFX frame (for example 4,634/4,634). The targeted snapshot at the matched after capture has 1,121 completed frames and one reset; its later endpoint has 831 completed frames and one reset while the entity snapshot records 839 dynamic updates. Static-scene publications can replace the counter context, so these snapshots are **not** subtracted into a single uninterrupted motion interval or a per-effect GPU cost.

Three ten-second profiles during each motion trial report CPU frame-loop timing:

| Mode | FPS, three passes | p95 frame time, ms | Largest sampled frame |
|---|---|---|---|
| Global resets | 59.535, 59.746, 59.916 | 16.725, 16.736, 16.712 | 79.433 ms |
| Targeted rejection | 59.852, 59.864, 59.388 | 16.746, 16.743, 16.817 | 80.455 ms |

The short p95 target passes, but both modes have hitches. These are CPU profiling samples, not continuous presentation measurements or a new twenty-minute acceptance run. During diagnostic archive generation, the log reports inability to map macOS 27.0 to a codename and “Negative index in crash report handler (18/19).” The archives are produced and the game remains active; the cause of these report-generation errors is not established. They are recorded as a diagnostic limitation rather than assigned to a renderer/mod conflict without evidence.

The stationary-camera twelve-frame comparison has 66.07% less measured temporal variance on the selected floor patch and 89.14% less near the pillar contact. Mean RGB stays within 0.30 channel levels. The gold-face patch instead has 166.07% **more** variance and visible bright speckles. These live measurements include natural entity animation and do not isolate Monte Carlo noise. `runs/fx-dynamic-live-images.json` records every region and source screenshot hash. The viewer displays the actual before/after pair and calls out the remaining speckles.

The temporary cow is removed, and `runs/fx-fixture-server-cleanup.json` verifies zero tagged test entities across all three loaded server dimensions. The initial cleanup diagnostics used an obsolete method name and failed; they are not cleanup evidence. The corrected audit uses the verified Minecraft 26.2 `entityTags()` method on server entities. The balanced preset is restored with physical lighting and MetalFX disabled, three samples, one bounce, neutral display exposure, radius eight and the 60 FPS cap. Original-instance verification reports no changed files.

## Rollback and remaining work

Close the development game and run `python3 tools/install_development_renderer.py --rollback-sha bd5cf581efd588ec866008fe366678dd22654aa2259a12ad29fc376334f7d57c`. No configuration keys were added, so the HDR build accepts the current settings file. `/metalrt preset balanced` restores the normal custom-filter preset with MetalFX disabled.

The rejected-history mask adds a calculated 1.10 MiB at 1920×1200. MetalFX mode now also runs the existing custom validation pass and a final consistency check, so live cost must be measured. Per-entity motion vectors, stronger rough-reflection correspondence, thin-edge detail, water/glass motion and broad performance acceptance remain unfinished.
