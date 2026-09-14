# Scope status against the requested final state

This file prevents completed prototype milestones from being confused with the full objective.

| Requirement | Current evidence | State |
|---|---|---|
| Original setup audit, cited explanation and Metal architecture roadmap | `../analysis/REPORT.md`, `../analysis/HARDWARE-RT-ROADMAP.md` and source/binary evidence | Delivered for the original Prisma stage |
| Isolated Prisma tuning, rollback and original preservation | `../analysis/`, `runs/original-preserved-materials.json` | Delivered; broader mod stress tests remain |
| Buildable Minecraft 26.2 source foundation | Metallum source pinned and built with cached dependencies; dedicated instance | Implemented |
| Actual hardware ray intersection | CPU/GPU ray comparisons and Apple `.gputrace` captures | Verified |
| Live sun shadows and AO | Matched images, block-removal response and controlled visibility tests | Implemented locally; quality/coverage limited |
| Roughness-aware solid-material reflections | Native texture/roughness tests, visible/off-screen wall game comparisons | Implemented locally |
| One-bounce GI and color bleeding | Red/blue sunlit-wall tests in native code and actual game | Implemented locally |
| Texture alpha for cutouts | Native transparent layer test and live cutout geometry collection | Implemented; full foliage acceptance pending |
| Water/glass/wet surfaces and transmission | Fluid/translucent geometry, Fresnel/refraction/TIR, absorption, indirect endpoint light and edge repair tested in native/live scenes | Partial: water appearance, full glass validation, wet materials and nested/underwater media remain |
| Moving entities/block entities | Independent posed-model BLAS and instanced scene; live off-screen cow reflection, shadow, movement and removal checks pass | Partial: custom/item/block-entity geometry and dynamic temporal acceptance remain |
| Finite-size local lights and quantitative contact hardening | Native penumbra/falloff tests and live direct-light composition pass; all 6,524 supported scene emitters retained, blocker/source changes verified. Secondary local illumination now passes native reflection/GI/transmission tests, with live ceiling reflection comparisons | Partial: opaque primary direct specular now passes MIS/energy tests; nonrectangular sources, secondary/specular chains and broader acceptance remain; lamp-driven GI quality remains weak |
| Multi-bounce GI | One/two-bounce native tests and live color comparison pass; short quality-tier profiles recorded separately | Implemented locally; broader acceptance pending |
| Stable denoising and temporal reconstruction | Custom temporal pass reduces measured static-scene variance by 96–99%; optional dynamic rectification reduces live contact-region variance 68%. New per-channel sampling variance reduces live lamp-reflection variance 73% and reflected-ceiling variance 55% | Implemented locally; distant grazing/edge noise and broader motion/specular acceptance remain |
| Motion vectors, disocclusion rejection and MetalFX | Static-scene motion and rejection tested; MetalFX now executes live with endpoint guides and reduced ray counts; reconstruction quality and upscaling acceptance remain. Targeted rejection now removes the per-frame global resets from posed entities; moving-shadow/reflection tests pass within stated residual bounds. Gold-face speckles, actual entity motion vectors and broad motion acceptance remain | Partly implemented |
| Eight-chunk off-screen scene, chunk BLAS/TLAS and streaming budgets | Full-height radius-eight collection (289 columns), 2.78–2.90 million triangles with no deferred sections; live long rays, top-section hit and radius eviction verified | Implemented; broader streaming stress and budget acceptance remain |
| Source renderer's playable voxel fallback | Raster fallback only; separate preserved Prisma instance has voxel lighting | Incomplete |
| Separate direct/indirect physical lighting | Opt-in surface composition passes analytic GPU references and live material-color tests; baked color removed inside valid coverage. `PHYSICAL-LIGHTING-VALIDATION.md` | Partial: lamp-only GI is dim; secondary specular, atmospheric and texture-detail work remain; HDR display mapping now passes native and matched live tests |
| Persistent user-facing quality/effect controls | `/metalrt` presets/effects, atomic configuration saves and backups; 54 current automated checks plus live command/restart verification in `PERSISTENT-CONTROLS.md` | Implemented; keyboard/chat UI interaction not independently tested |
| Full scene suite, dimensions, rapid camera motion, all mod interactions | Some controlled fixtures and block edits tested | Incomplete |
| Final 1920×1200/60-FPS acceptance and 20-minute session | Twenty-minute stationary session completed: 20 sampled profiles average 59.636 CPU frame-loop FPS, p95 17.355 ms, no swap growth; RSS peaks at 8.91 GiB then ends at 3.76 GiB. Raw record in `SUSTAINED-VALIDATION.md` | Stationary sustained session verified; continuous presentation, streaming/motion and broader final acceptance remain |

The goal remains active. The next development stages should address MetalFX motion/detail quality and upscaling, animated water/material detail, missing entity geometry, physically consistent material composition and scene scaling. Preserve the accepted captures and raw profiles as historical evidence; rerun performance acceptance after major renderer changes.
