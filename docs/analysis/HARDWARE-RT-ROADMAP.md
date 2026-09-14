# Hardware ray tracing development specification

This specification was originally delivered as a roadmap. The user subsequently authorized implementation, now tracked in the [development workspace](../development/README.md). Completed prototypes do not imply completed gameplay effects. Target: Minecraft 26.2, Fabric, Sodium, arm64 macOS, M5 Pro with 24 GB unified memory, 1920×1200 output at 60 rendered FPS. Retain a voxel fallback for unsupported or failed RT initialization.

## Foundation and build gate

The supplied Prisma checkout cannot build a mod: it lacks implementation sources, Gradle files and the wrapper referenced by its workflow. Do not patch the release JAR as the product implementation. Start an isolated source checkout of Metallum at the revision recorded in `evidence/upstream/metallum-revision.json`. Its published metadata targets Minecraft 26.2, loader 0.19.3, Java 25 and Sodium 0.9.1; verify mixins against installed Sodium 0.9.2 before updating that dependency. Preserve MIT attribution and review provenance of reused files. Prisma's README and embedded licensing statements differ; do not assume unreleased Prisma sources are obtainable.

Use Java 25 arm64 and an Xcode SDK supporting the selected Metal APIs. Use a per-command `DEVELOPER_DIR`, not a global `xcode-select` change. Pin the Gradle wrapper, Loom/plugin resolution and dependencies for reproducibility. A clean build, title screen, copied-world load and chunk traversal on the exact dependency set are the first acceptance gate. If buildable Prisma source becomes available, compare it to this baseline and port the same interfaces rather than binding the architecture to decompiled class layouts.

## Milestone 1 — prove actual hardware API use

Extend the native bridge with capability queries, acceleration-structure descriptors/build commands, intersection-function bindings, compute-pipeline dispatch and resource synchronization. Expose device name, RT support, Metal GPU families, recommended working set and initialization failure reason to diagnostics. A successful capability query alone must never set the status to “hardware RT active.”

Build a small static scene containing two triangles with known positions. Query rays that hit triangle interiors, miss, cross a shared edge, and stop before the geometry. Compare hit distance and primitive identity to CPU reference intersections within numerical tolerance. Verify occlusion queries with a finite maximum ray distance. Capture the Metal command stream and show the acceleration-structure build, bound scene structure and the intersector-using shader. Test a deliberately unsupported/disabled capability path and return to voxel rendering without a crash.

Accept this milestone only when correct intersections and the executed Metal workload are captured on the M5 Pro. Do not infer dedicated-unit usage from elapsed time or the GPU's name alone.

## Milestone 2 — maintain the Minecraft ray scene

Use actual visible block-model triangles as the initial geometry representation, rather than full cubes for every shape. Partition by chunk section; build a primitive acceleration structure for each section and an instance structure for the active ray scene. Keep resident nearby geometry outside the main camera frustum. Ray-scene selection must not inherit EntityCulling's primary-view visibility decisions.

Use immutable geometry snapshots and versioned updates. Rebuild changed topology; refit transforms when geometry topology is unchanged and the API supports it. Queue uploads/builds on a bounded budget, and publish a new scene epoch only when geometry, material indices and acceleration structures agree. Retire old resources after GPU completion. Chunk unload, teleport and dimension change invalidate stale scene references. A trace uses one complete epoch throughout a pass.

For the first playable stage, retain an eight-chunk RT radius and cap reflection distance separately at 64 blocks. Fade to the documented sky/voxel fallback near the available-scene boundary. Track moving entities with separate mesh/transform updates; include player geometry where appropriate instead of a cylinder. Transparent/cutout surfaces need alpha-aware hit acceptance; glass and water require explicit reflection/transmission policy. Do not treat all non-opaque cells as empty.

## Proposed interfaces

These contracts define responsibilities for the new source project, not existing Prisma APIs:

- `RtCapabilities`: API support, GPU families, unified-memory flag, memory guidance, selected mode, and fallback reason.
- `SceneUpdate`: dimension identifier, scene epoch, changed/removed chunk sections, geometry versions, material-table version, and dynamic-instance transforms.
- `RtScene`: owns committed geometry/material resources and acceleration structures; accepts updates and returns an immutable frame handle plus readiness state.
- `MaterialRecord`: atlas UV/texture reference, base color, emissive radiance, roughness, metallic/specular response, opacity/cutout threshold, transmission and index of refraction. Start with a versioned block-property mapping; accept resource-pack material overrides later without assuming an existing PBR format.
- `RtFrameInputs`: inverse camera matrices, jitter, frame/dimension/scene identifiers, depth, world normals, diffuse/specular albedo, roughness, motion vectors, lighting and exposure.
- `RtSettings`: independent effect enablement, resolution scale, trace distance, sample budget, diffuse bounce limit, denoising mode and RT scene radius. Persist only supported controls; show a clear fallback reason when a feature cannot initialize.
- `RtFrameOutputs`: separate direct visibility, AO, diffuse indirect and specular radiance buffers, confidence/history validity, and per-pass timing/resource counters.

Keep native resource ownership within the rendering subsystem. Game threads submit snapshots; they must not mutate buffers being traced. Resource reloads atomically replace the atlas and its matching material table and reset temporal history.

## Milestone 3 — effects in increasing cost order

**Shadows and AO:** trace visibility to samples on finite-size local lights and a finite angular sun disk. This produces contact hardening as blocker/receiver geometry changes. Start with one light sample per shaded pixel per frame and accumulate over time. AO traces one short hemisphere ray per sample at half width and height, then reconstructs; it remains an optional visibility effect, not a GI replacement. Avoid applying AO again to already-occluded indirect illumination.

**Reflections:** sample a microfacet specular direction from normal and roughness; shade the first visible hit with the same material/light definitions as the main view. Begin with one reflection bounce at half width and height. Support water, assigned metals, wet-surface mappings and glass reflections, with transparent hit handling. Include off-screen blocks and animated entities. Transmission/refraction depth is a separate quality/cost control, not an unlimited recursion path.

**GI:** initially estimate one diffuse bounce with emissive-light sampling and visibility. Include surface albedo in transported light so a colored wall bleeds color onto a neutral receiver. Use physically interpretable emission and sky input; avoid disguising an ambient brightness term as GI. After one-bounce validation, add a two-bounce quality tier and terminate paths by an explicit depth/sample budget. Full unrestricted path tracing is outside the first playable target.

## Milestone 4 — reconstruction and frame budget

Begin with native-resolution rasterization and half-width/half-height RT effect buffers. Provide real camera/object motion vectors, world normals, depth, material albedos and roughness before enabling temporal reconstruction. Use MetalFX's denoised upscaler when the available runtime supports the required inputs; retain an explicit spatial/temporal fallback. Reset or reject history after camera cuts, teleports, dimension changes, geometry/material version changes and disocclusion. Keep HUD/text outside stochastic effect reconstruction.

Initial engineering budget: main raster/CPU submission 7 ms; scene updates 1.5 ms; shadows/AO 1.5 ms; reflections 2 ms; GI 2 ms; reconstruction/composition 1.5 ms; remainder for presentation headroom. These are allocations for profiling, not predictions. The complete critical path must fit 16.67 ms for 60 FPS; overlapping GPU work must not be double-counted. Track both render and presentation intervals.

If over budget, reduce GI samples/resolution first, then reflection samples/resolution, then ray-scene distance. Preserve local contact visibility as long as practical. Do not use generated frames to satisfy the 60-rendered-FPS target. Stay within measured memory pressure and the device working-set guidance, considering both Java and native memory. Prefer bounded caches and incremental builds to allocating the maximum possible scene.

## Acceptance and rollout

Require three timed passes per setting after warm-up, fixed camera/time/weather and a copied benchmark world. Validate off-screen reflection continuity, thin shapes, transparent materials, entity motion, contact-hardening shadows, AO corners, GI color bleeding, world edits, chunk loading, dimension changes and camera cuts. Compare against the existing voxel renderer at the same output and scene. Capture screenshots plus per-effect GPU timings, p95/p99 presented frame intervals, heap/GC activity, native allocations, pressure and swap changes.

Enable each effect only after its visual and timing gate passes. Run a 20-minute sustained session with no crash, invalid memory access, stale geometry or persistent history smear. Keep a launchable fallback profile and the original mods/worlds intact. Ship the first build as experimental; publish its tested configuration and actual exclusions instead of promising all M-series Macs or every mod combination.

## Applied Minecraft skills

Reviewed and installed `minecraft-modding`, `minecraft-testing`, and `minecraft-commands-scripting` from `Jahrome907/minecraft-agent-skills`, commit `dd57c5a97741cdc0eb5bb3a8f876581a4f09eeb0`. These are guidance/reference files, not a live-control MCP server or rendering mod.

Apply their 26.x boundaries: Java 25, unobfuscated official names, current Fabric non-remapping Loom configuration, and dedicated Fabric server/client Game Test source sets. Keep Java diagnostics separate from gameplay mods. When the source prototype exists, add Fabric client Game Tests for rendered-scene behavior; a server Game Test or static layout validator cannot prove ray-traced image correctness. Do not paste legacy Yarn/Java 21 or NeoForge test registration snippets into this Fabric 26.2 project. Command fixtures must use the 26.2 clock/gamerule names verified against the running game.
