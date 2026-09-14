# Direct specular lighting

Implemented and installed in the copied development instance. Fourteen native GPU regressions, 32 settings checks and 12 client-command checks pass. The expanded specular proof also passes GPU shader validation.

The traced surface-lighting mode now samples the sun and rectangular local emitters for opaque primary materials. It evaluates the same isotropic GGX distribution, separable Smith masking and Schlick Fresnel approximation used by the existing reflection sampler. Reflection strength controls the added radiance. The hybrid composition is unchanged.

`directSpecular` defaults to true and applies only when `physicalLighting` is enabled. `/metalrt set directSpecular false` disables the new sampling for comparison without turning off ordinary reflected scene radiance. The choice persists through the existing settings store.

## Sampling and energy

Light-area density is converted to solid-angle density at the receiver. Local light samples and reflection samples use power-heuristic multiple importance sampling, so reaching a registered emitter through both methods does not duplicate its emission. Only the direct emission term receives this weight; light reflected from the hit surface remains present. The implementation follows the strategy explained in [PBRT's path-tracing chapter](https://pbr-book.org/4ed/Light_Transport_I_Surface_Reflection/A_Better_Path_Tracer). It assumes the non-overlapping rectangular emitter faces produced by the current scene collector; coincident source geometry needs separate handling.

A small hardware query at the sampled rectangle point reads the actual emissive texel and alpha cutoff. This makes both strategies evaluate the same emitter radiance even when the light-selection table uses average texture color. Analytical lights without emissive geometry keep their supplied radiance and receive no competing BSDF weight. Back-face emission is excluded for registered one-sided lights.

The specular BRDF uses [GGX microfacet theory](https://www.pbr-book.org/4ed/Reflection_Models/Roughness_Using_Microfacet_Theory), matching the existing sampler's full-normal-distribution PDF rather than substituting a visible-normal PDF. The sun is sampled uniformly over a cone and normalized to the configured irradiance. Its finite angular radius broadens the highlight. Since the procedural sky contains no sun disk, the new sun sample has no competing environment-sampling term.

A local sample crossing refractive geometry is left to the existing reflection/transmission strategy. Mixing a straight light connection with a bent path would use incompatible probabilities and can double-count energy. Alpha-tested holes still permit direct visibility. This preserves refracted lighting but does not add a dedicated refractive light-sampling algorithm.

## Native evidence

`rt-core/DirectSpecularProof.mm` compares GPU transport with independent double-precision CPU area quadrature. The expanded run enables both Metal API and GPU shader validation.

| Roughness | GPU outgoing radiance | CPU reference |
|---|---:|---:|
| 0.20 | 5.265074 | 5.262006 |
| 0.60 | 1.608493 | 1.609024 |
| 0.95 | 0.306544 | 0.306512 |

The test also verifies analytical emitters, BSDF-only emission, textured red/blue emission despite a deliberately incorrect average light color, non-emitting alpha holes, complete blocker occlusion, and preservation of refracted-path energy. A directional sun highlight measures 0.614255 against 0.614024 analytically. Increasing the sun radius to 0.2 radians reduces the central peak to 0.580814 above the sky contribution, as expected for the test geometry.

Raw evidence: `rt-core/results/direct-specular-expanded.json` and `.stderr`. These values are transport radiance, not displayed Minecraft brightness or performance. The original no-glass test remains in `direct-specular-initial.json`.

## Remaining scope

The new sampling covers opaque primary materials. Direct sampling on glass/water, secondary specular chains, full Fresnel diffuse-energy sharing, coincident lights, nonrectangular emitters, atmosphere/weather and broad temporal quality remain. It is not expected to fix all dark metal surfaces: a metal reflecting another unlit metal still needs additional specular transport. Runtime cost and live highlight quality must be measured before claiming visual or performance acceptance.

## Live evidence

At fixed world time 2000, the ray-scene sun angle is 5.4439096 radians. The final camera faces yaw 270°, pitch 41.913044°, with player position [195.5,159,196.5] after settling onto the platform. The first attempted heading was reversed; its off-axis captures remain as `series-specular-sun-*`. They do not establish the sun-highlight result. The correctly aligned evidence is `series-specular-aligned-before/after-00..11.png`.

With physical surface lighting, all effects, full shadow strength and ordinary reflections held constant, switching only `directSpecular` creates the sun highlight on the iron floor. In rectangle [880,450,1010,740], mean RGB rises by [185.130,170.010,150.340] on the 0–255 scale. The sky patch changes by zero. The highlight shoulder increases without clipping, but 98.6% of the central patch clips in all channels: HDR tone mapping is still required. Existing dark metal-to-metal reflections and softened primary texture detail remain. Raw measurements are in `runs/direct-specular-live-images.json`; screenshots were not recolored, brightened or otherwise altered.

Initial off-axis performance passes at 1920×1200, three samples, one bounce, all effects, custom dynamic temporal reconstruction, MetalFX off and a 60 FPS cap measured 59.64–59.75 FPS with direct sampling off and 59.46–59.76 FPS with it on. Sampled p95 ranges are 17.08–17.40 ms off and 17.06–17.64 ms on. These are CPU frame-loop profiles, not presented-frame measurements or a precise incremental GPU cost. The native cumulative counter reset when a new scene was published during the baseline; subtracting those snapshots would be invalid. The snapshots are retained as evidence rather than used for a misleading GPU delta.

The sun-aligned performance passes are recorded separately in `runs/direct-specular-aligned-results.json`. Broader motion and sustained acceptance remain open.

The sun-aligned passes measured 59.734, 59.670 and 59.688 CPU frame-loop FPS, with p95 17.162, 17.270 and 17.358 ms. These short stationary results meet the requested p95 threshold. They do not establish sustained, streaming or motion acceptance.

The original platform camera and balanced hybrid preset were restored after testing. No blocks, time settings or mods were changed in this stage. The new renderer remains installed; `physicalLighting=false` makes the added direct-specular branch inactive during ordinary balanced gameplay. Original-instance preservation passes with no changed original files.

Rollback: close the development game, preserve its current settings file, remove only the new `directSpecular` key if returning to the immediately preceding physical-lighting build, then use `python3 tools/install_development_renderer.py --rollback-sha 7501f9ec03c890042e127210a81224d7da8674984cbf18147a7b7353a689b860`. Older controls-only builds also require removing `physicalLighting`; their strict parser rejects keys they do not implement. The new control's disk/restart behavior is covered by the settings proof; a separate live restart for this added boolean was not repeated.

Next quality work should preserve HDR highlight range before tone mapping, retain primary material texture detail, and extend specular transport beyond opaque primary surfaces. The half-float intermediate radiance textures also need a range audit for very smooth surfaces and extreme light intensities; the current Minecraft iron/gold material uses roughness 0.2.
