# Reusable chunk acceleration structures

This records the earlier backend milestone. The later [section streamer](SECTION-STREAMING-VALIDATION.md) replaces its 25-block collector with full-height, eight-chunk coverage.

This is the backend and ownership stage of expanding the ray scene. The live collector still covers 25 blocks; an eight-chunk collection radius and budgeted streaming remain required.

## Native scene publication

`rt_build_chunks` accepts a complete immutable list of chunk-local meshes, materials, texture texels, stable keys and scene-relative translations. Each chunk receives its own triangle acceleration structure. The top-level instance structure applies translations and carries primitive offsets into the packed shading buffers. All indirectly referenced structures are explicitly declared to Metal compute encoders.

Geometry reuse compares the complete vertex bytes for the same key. Material or translation changes reuse the bottom-level structure; geometry changes rebuild that chunk. The committed scene and cache change only after the replacement command buffer completes successfully. Duplicate keys, non-finite data and invalid material ranges preserve the preceding scene. The API bounds input to 8,192 chunks, eight million triangles and 64 million texels, and checks Metal buffer limits. Those ceilings are guards, not recommended gameplay budgets.

The immutable cache can be retained independently of an old scene through an O(1) snapshot. This lets a worker seed the next scene after a block edit closes the old renderer state. Java synchronizes cache seed/release, and native shared ownership keeps reused buffers/structures alive. A changed instance layout prevents history transfer even if the packed attribute bytes match.

An empty scene contains a masked degenerate placeholder solely to keep Metal resource bindings valid. It cannot intersect rays. Dynamic geometry can still be added to that scene; combined attribute offsets omit the placeholder's unused vertex/material bytes.

Packed vertex/material/texture arrays are still reassembled for publication, and animated geometry still joins packed attributes for shading. This is not yet the final memory/upload strategy for thousands of chunks. Buffer statistics exclude temporary scratch allocations and do not represent process peak memory.

## Minecraft bridge

Baked block and fluid triangles now retain their owning section key. `ChunkMeshSnapshot` separates the existing snapshot into section-local vertices and locally deduplicated texels, adjusting material texture offsets. The worker publishes through the chunk API; a retained cache survives block invalidation and same-world camera movement. World changes release it. Empty block snapshots now publish an empty ray scene instead of leaving old geometry visible.

The current main-thread collector still visits the complete local cube. It must be replaced by prioritized, time-budgeted full-section collection, air-section skipping, edit/unload invalidation and radius eviction before the intended eight-chunk coverage is ready. Partial sections at the current cube boundary can legitimately rebuild as that boundary moves.

## Native evidence

`rt-core/results/chunk-proof.json` verifies three independent chunks; all three structures reused after translation/material changes; one rebuilt and two reused after a geometry edit; retained cache validity after destroying the old context; transform-aware history rejection; invalid updates preserving the committed scene; removal; an empty scene; and a red dynamic reflection over an empty static scene. A ray starting in the near scene hits the chunk translated 128 blocks away at distance approximately 128.016 blocks.

The capture at `rt-core/results/chunk-cache-long-rays-20260914.gputrace` was recorded with Metal API Validation enabled. The original 4,104-ray comparison, material transport, dynamic composition, frame/history and MetalFX regressions pass.

## Live evidence

The copied world confirms five cached section structures and 1,260 triangles before edits. Changing the pillar block from gold to copper kept cumulative builds at five. Removing that block increased builds to six and reduced triangles to 1,256. Restoring gold increased builds to seven and restored 1,260 triangles. Thus each geometry edit rebuilt one section; the material-only edit rebuilt none. Repeated unchanged publications reused all five structures.

Raw counters are in `runs/chunks-stable-before-1789397023690.txt`, `runs/chunks-material-edited-1789397043802.txt`, and the timestamped `chunks-geometry-edited-*` / `chunks-restored-*` files. Actual 1920×1200 screenshots are `capture-chunk-baseline.png`, `capture-chunk-material-edit.png`, `capture-chunk-geometry-edit.png` and `capture-chunk-restored.png` under `screenshots/`. These are material/edit lifecycle comparisons, not a claim that caching itself improves image quality.

No claim of expanded Minecraft collection coverage is made by the native long-ray test. The live scene remains 25 blocks wide.


Three ten-second capped profiles after restoration measured 59.55–59.60 CPU frame-loop FPS, p95 17.40–17.45 ms and maximum 18.20 ms. Raw results are in `runs/chunk-cache-cap60-results.json`. These are Minecraft CPU profiler intervals, not measured presented-frame intervals or isolated ray-tracing GPU cost. They do not establish eight-chunk performance or sustained-session acceptance. The installed JAR matches the build; asset checks and native proof are recorded in `runs/chunk-cache-build-verification.json`. Original-instance manifest comparison found no changed files, and the tuned instance still contains 14 mods (`runs/original-preserved-chunk-cache.json`).
