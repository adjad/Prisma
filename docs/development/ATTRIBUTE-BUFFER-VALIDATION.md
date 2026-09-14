# Separate static and dynamic shading buffers

The renderer previously allocated combined private vertex, material and texel buffers for each changed entity pose, copying the complete static shading payload into them. In the full-radius world that static payload is about 382–398 million bytes. This stage replaces those copies with a 64-byte Metal argument buffer referencing separate immutable static and dynamic allocations.

## Binding and ownership

Metal Tier-2 argument buffers on current macOS permit the C-compatible layout of GPU addresses described in [Apple's argument-buffer documentation](https://developer.apple.com/documentation/metal/improving-cpu-performance-by-using-argument-buffers) and [Go bindless with Metal 3](https://developer.apple.com/videos/play/wwdc2022/10101/). The renderer explicitly checks Tier-2 support at native initialization. This uses the existing Metal command-buffer path; it is not a claim that argument buffers require Metal 4.

The 64-byte layout contains two vertex addresses, two material addresses, two texel addresses, the static triangle/texel counts, and reserved words. The shader retains global primitive identities and uses lightweight views to select a static or dynamic buffer. Dynamic material texel offsets remain adjusted by the static texel count. The same binding is used by visibility, reflection/GI, edge repair and MetalFX guide kernels.

Each encoder declares every indirect buffer with `useResource`. A retained frame object holds the argument table and all six resource references until GPU completion. Posed geometry continues to have its own BLAS, and the combined TLAS still rebuilds when poses change. This stage does not implement per-entity BLAS refitting or motion vectors.

Unchanged entity material and texture payloads now retain their existing allocations. Adjusted materials are reused when both the immutable source material buffer and static texel offset match. Moving vertices allocate a new immutable buffer; earlier frames keep their own pose buffers. Static scene publication still repacks shading buffers after genuine section changes, independently of entity motion.

`rt_attribute_statistics` exposes actual static/dynamic shader-buffer byte totals and diagnostic GPU addresses. The Java-facing statistics expose only byte totals. These totals exclude acceleration structures, scratch allocations, targets, the 64-byte table and general process memory.

## Native evidence

- `rt-core/results/attribute-ownership-final.json` verifies three unsubmitted RGB-emissive entity frames, then destroys their scene before submission. All frames complete with their own expected indirect-light color and unchanged alpha.
- The same test verifies unchanged static resource addresses, independent pose vertices/textures, reuse of unchanged adjusted materials, and only 268 bytes of dynamic attributes per pose in its tiny synthetic scene.
- `rt-core/results/separate-attributes-final-20260914.gputrace` captures this workload with Metal API validation. `attribute-ownership-shader-final.json` independently passes GPU shader validation.
- `attribute-before-dynamic.json` and `attribute-after-dynamic.json` have identical reported indirect energy, movement and restoration results. The full binding regression suite passes ray intersections, AO/shadows, composition/history, materials, transmission, MetalFX, dynamic meshes, transmitted GI, edge repair, chunk scenes and temporal reconstruction (`attribute-regression-suite.json`). Final targeted regressions after material-allocation reuse also pass.

One combined capture/API/shader-validation attempt remained waiting. Independent normal, API and shader runs completed; the redundant combined attempt and its sampler were terminated explicitly. The subsequent API-only captures and separate final shader-validation test completed successfully. The waiting attempt is not counted as a pass.

## Live evidence

All comparisons use 1920×1200, full-height radius eight, one GI bounce, all four effects, dynamic temporal filtering and MetalFX disabled. The platform comparison is uncapped; terrain runs use a 60 FPS cap. Each row contains three 10-second client profiler runs after scene collection settled.

| Configuration | CPU frame-loop FPS | p95 frame-loop time | Maximum observed interval |
|---|---:|---:|---:|
| Earlier merged buffers, platform, two samples | 78.74–80.36 | 13.71–13.98 ms | 25.90 ms |
| Separate buffers, same platform, two samples | 119.76–119.90 | 9.17–9.25 ms | 18.54 ms |
| Separate buffers, terrain, four samples | 52.62–52.95 | 19.21–19.50 ms | 31.58 ms |
| Separate buffers, same terrain, three samples | 59.83–59.90 | 16.72–16.79 ms | 25.12 ms |

Raw archives and summaries are in `runs/attributes-before-uncapped-results.json`, `attributes-after-uncapped-results.json`, `attributes-terrain-four-results.json`, and `attributes-terrain-three-results.json`. The approximately 120 FPS platform result may meet a display/render-loop ceiling; it does not establish maximum GPU throughput. These are CPU frame-loop measurements, not presented-frame times. No generated frames are included.

The platform readback retains roughly 382 MB of static shading attributes and 0.49 MB of dynamic attributes. The terrain retains roughly 398 MB of static attributes and 0.49 MB of dynamic attributes, with about 2.90 million triangles, 289 loaded columns and no queued/deferred sections at the readiness check. Three-sample terrain whole-command-buffer GPU times were around 15–16 ms in the readiness snapshot; this is not isolated RT-pass timing.

Three samples is the selected **session-only experimental preset**, capped at 60. It meets the short stationary terrain target; four samples does not. Actual unedited captures `screenshots/capture-attributes-terrain-four.png` and `capture-attributes-terrain-three.png` show the same camera and geometry with different stochastic sample counts. The image comparison evaluates a quality setting, not a visual effect added by buffer ownership. Moving natural entities and stochastic noise can differ between captures.

At approximately 11 minutes 40 seconds process uptime after these runs, PID 80039 reported RSS 9,506,272 KiB (about 9.07 GiB). System swap used was 1,763.12 MiB, unchanged from the recorded prior-session snapshot; this is system-wide, not attributable to Minecraft alone. AC power was attached. There is no same-process starting RSS measurement for this stage, so this snapshot establishes neither a leak nor stable sustained memory. Heap measurements in the three-sample runs were approximately 895–1465 MiB, distinct from native/unified memory. The final 20-minute memory, streaming and presentation acceptance remains open.

The player was returned to the original test platform. `runs/original-preserved-attributes.json` reports no tracked original-file changes and all 14 mods in the tuned Prisma instance. The development renderer JAR is `ca8f2caf1d35e00302f2c405faaa6eeacace45f9b8a647eb95bcbe463887ea59`. Use the development installer rollback command with the previous section-streaming SHA `4029b88e64dd5ef9924cac491957a88b34d8240285bd000f4cc0d7c92a82d8ca` after closing the development game; original and tuned Prisma instances remain separate.
