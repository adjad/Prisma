# Prisma on Apple M5 Pro — renderer audit

Research date: 14 September 2026. Scope: the installed Prisma 0.1.2-A binary, Minecraft 26.2, and a separate Prism Launcher test instance. Benchmark results are recorded separately in BENCHMARKS.md. A configured preset is not proof of a performance target.

## What is working, and what is not implemented

Prisma is a native Metal renderer with software voxel traversal on the GPU. Its installed shaders do not use Metal's hardware ray-intersection API. Metal rendering, ray tracing as an algorithm, and hardware-accelerated ray tracing are three different things. The M5 Pro can execute hardware ray queries, but this Prisma build does not contain the interfaces needed to submit them.

The read-only capability probe returned `supportsRaytracing=true`, `supportsRaytracingFromRender=true`, `metal4Family=true`, and `hasUnifiedMemory=true` on Apple M5 Pro. This is a real device query, not a model-name assumption. It establishes device/API capability, not that Minecraft uses it. The probe reports a recommended Metal working set of 19,069,665,280 bytes (about 17.76 GiB); this is not a reservation or a safe total-game memory budget. See [raw device evidence](evidence/metal-capabilities.json).

The original instance's log identifies Metal as the graphics backend. Prism Launcher chooses game versions, Java, mods, arguments, and instance directories. Prisma's replacement graphics backend selects and drives Metal. Choosing a launcher does not translate an ordinary shader into a hardware ray tracer.

## Ray tracing in practical terms

A ray has an origin, a direction, and an allowed travel distance. A visibility query asks whether scene geometry blocks that ray. A reflection ray travels along a direction determined by the surface normal and material. A shadow ray travels toward a sampled light position. AO samples visibility over nearby directions. GI additionally evaluates light arriving at the hit surface and transfers some of it to another surface.

Prisma uses a 3D voxel grid and DDA traversal: compute the next voxel boundary, advance along the nearest boundary, and inspect the new cell. It can find blocks outside the screen because its scene representation exists independently of the current image. It remains limited to populated grid contents, shape approximations, traversal budgets, and supported materials. Off-screen tracing does not imply unlimited distance or reflection of every entity.

Hardware ray tracing ordinarily builds a hierarchy of bounds over triangles or other supported primitives. Metal's intersector searches those acceleration structures. On supported Apple GPUs, dedicated hardware accelerates this work. It does not eliminate material shading, scene updates, memory traffic, or noise. Path tracing follows stochastic surface interactions to estimate light transport, often with several bounces. A low sample count needs accumulation and denoising; an FPS counter alone cannot establish adequate image quality. [Apple ray tracing documentation](https://developer.apple.com/documentation/metal/accelerating-ray-tracing-using-metal).

## Installed rendering pipeline

1. Fabric mixins replace Minecraft/Sodium graphics-backend selection with `MetalBackend`. Minecraft creates a GLFW Cocoa window without an OpenGL client API. Prisma obtains the Cocoa window/view and attaches a `CAMetalLayer`.
2. Java 25's Foreign Function and Memory API drives Objective-C calls. The inspected bridge creates downcall handles and invokes `objc_msgSend`; it is not an external OpenGL-to-Metal translation layer.
3. Existing game shaders pass through Minecraft's intermediate shader representation and SPIR-V-to-MSL conversion. The `vulkan` package names in that compiler code do not mean Vulkan is the active presentation backend. Metal compiles the MSL and builds native pipelines.
4. Sodium geometry is rendered through Prisma's draw backend. Multiple render targets hold scene information including albedo, normals and lighting data; depth is used to reconstruct positions for lighting. Prisma documents reverse-Z depth and its shaders handle scene/hand depth separately.
5. `VoxelGridManager` builds a camera-relative block volume on a worker and rotates among three shared Metal buffers. Each voxel occupies eight bytes. The grid covers 128 vertical blocks and `(32 × radius)` blocks on each horizontal axis. Block color, flags, light values and identifiers support occupancy and shading; a UV table maps block identities into the actual block texture atlas.
The inspected voxel updater schedules another rebuild on camera chunk/vertical-section changes or after 60 rendered frames, provided its worker is available. At the final 60 FPS cap, the periodic trigger is about once per second. This implies potential delay after stationary block/light edits; the visual tests establish settled updates after three seconds, not exact latency. Event-driven versioned updates are part of the hardware-RT roadmap.

6. The deferred full-screen shader combines voxel AO, point lights, existing block/skylight values, atmospheric colors and ambient terms. Water adds procedural waves and a Fresnel-weighted voxel reflection mixed with sky fallback. The result is presented through the Metal layer.

Inspect [the extracted deferred shader](evidence/prisma-embedded-4.metal), [backend bytecode](evidence/render.MetalBackend.javap.txt), [compiler bytecode](evidence/render.MetalCrossShaderCompiler.javap.txt), and [voxel manager bytecode](evidence/voxel.VoxelGridManager.javap.txt). These are local evidence extracted from the user's installed JAR, not recovered upstream source.

## Feature findings

| Requested effect | Installed implementation | Practical limit |
|---|---|---|
| Reflections on shiny/wet/glass surfaces | The inspected composition invokes voxel reflections inside `if (isWater)`. DDA is limited to 36 cell advances, samples block-atlas color, and falls back to procedural sky. | Water is supported; general reflective glass, metals, wet blocks and dynamic entities are not established. 36 steps is not a fixed 36-block spherical radius. |
| Soft ray-traced shadows | Point lights call `traceDdaShadowRay` with a jittered light position. The player uses a cylinder visibility approximation. | Geometry and softness are approximations. Increasing softness is not proof of a finite-area light model with physically correct blocker-dependent penumbrae. |
| Ambient occlusion | `computeVXAO` uses eight rotated directions and three candidate distances (0.40, 1.05, 2.20 blocks) with jitter/weights. | Contact darkening from occupancy samples, not hardware rays or indirect light transport. Small/thin geometry and temporal stability require visual checks. |
| Global illumination | Base light uses block/skylight values, point lighting, minimum ambient and color adjustments. Reflections shade hits from existing light values. | No multi-bounce diffuse transport or general color-bleeding integrator found. Bright interiors can result from ambient terms rather than GI. |
| Sun shadows | `sunShadowsEnabled` is declared in the deferred uniform structure but not read in that shader; no sun-visibility trace or cascade sampling is present there. | The setting does not establish functioning directional shadows. In-game A/B verification is tracked separately. |

A scan of every class's constant pool found zero matches for acceleration-structure construction, MSL `intersector`, raytracing capability calls, Metal 4 command queue types, and MetalFX integration. This is strong static evidence about this build, not a universal claim about every Prisma version. [Reproducible summary](evidence/audit-summary.json).

## Why Cyberpunk 2077 and Control matter

CD Projekt RED describes bringing up a native Metal backend, validating stationary and moving scenes, and tuning MetalFX dynamic resolution for specific devices. The transferable lesson is to budget the complete frame and validate motion/streaming, not merely enable a ray-tracing checkbox. Its support page lists M3 Pro/18 GB for a 30 FPS medium-RT target and M3 Max/36 GB for 60 FPS, with MetalFX DRS. Those are Cyberpunk targets; they are not Minecraft predictions or a direct M5 Pro benchmark. [CDPR's developer presentation](https://developer.apple.com/videos/play/wwdc2026/356/), [official Mac RT guidance](https://support.cdprojektred.com/en/cyberpunk/mac/sp-technical/issue/2897/ray-tracing-on-mac).

Control is a useful hybrid-rendering example: selectively trace reflection, visibility and lighting effects while retaining rasterization for much of the frame. Its technical authors discuss effect-specific ray budgets, material handling and denoising. That original renderer documentation does not expose every implementation detail of the later Mac port. The official Apple-platform listing establishes the release and device requirements; it should not be used to infer that all Windows rendering paths were ported identically. [Ray Tracing in Control](https://developer.download.nvidia.com/ray-tracing-gems/rtg2-chapter46-preprint.pdf), [official listing](https://apps.apple.com/us/app/control-ultimate-edition/id6502953520?platform=mac).

Metal 4 adds acceleration-structure build choices and intersection-function management; MetalFX can combine denoising with upscaling when the renderer supplies the required auxiliary buffers. These are engineering integrations, not features inherited from Prism Launcher. [Apple Metal 4 session](https://developer.apple.com/videos/play/wwdc2025/211/).

## Limits of this Mac and this build

- The M5 Pro's 20-core GPU and hardware ray tracing are suitable for an experimental hybrid renderer. No measured result here implies unrestricted path tracing at native display resolution. Apple's hardware description confirms the RT engine, but cross-generation promotional percentages are not forecasts for this mod. [Apple M5 Pro specifications](https://www.apple.com/newsroom/2026/03/apple-debuts-m5-pro-and-m5-max-to-supercharge-the-most-demanding-pro-workflows/).
- At 1920×1200, one full-screen ray per pixel is about 2.30 million rays per frame, or 138 million rays per second at 60 FPS, before shadow rays, additional effects or bounces. One quarter of that pixel count greatly reduces tracing work, but requires reconstruction.
- The full frame must fit approximately 16.67 ms. Acceleration-structure updates, CPU chunk work, ray traversal, shading, denoising, UI and presentation all compete for that budget.
- Java heap is only part of process memory. Native voxel buffers, textures, geometry and future acceleration structures share the same 24 GB with the OS and other applications. A larger heap can reduce remaining graphics headroom.
- Current voxel-buffer totals: radius 4 = 48 MiB; radius 8 = 192 MiB; radius 12 = 432 MiB; radius 16 = 768 MiB. The 16→8 change saves a calculated 576 MiB in these buffers alone. The measured whole-process difference may differ.
- Your OS build is 27.0 (26A5425a), while installed Xcode is 26.3 and command-line tools are the active developer directory. API capability was tested directly. Profiling/toolchain compatibility is a separate concern; no OS or global developer-directory changes are part of this work.
- The initial power reading reported AC power but only 13% battery and discharging. Sustained results must retain their power-condition notes. Other resident applications may also affect unified-memory and GPU measurements.

## Source availability and provenance

The downloaded Prisma directory has README/workflow files but no Gradle wrapper, source tree or build configuration. The README says closed source until 1.0, while the installed JAR declares MIT and includes an MIT license with Microsoft attribution. Preserve this discrepancy; do not invent a complete licensing history. Any distributable derivative needs its provenance checked.

Metallum is a source-available MIT baseline. Its inspected Gradle metadata targets Minecraft 26.2, Java 25, Fabric Loader 0.19.3 and Sodium 0.9.1. Your installed Sodium is 0.9.2, so renderer/mixin compatibility needs a build-and-run test before substituting it. The roadmap treats an independent prototype as a separate development project. Public source metadata was saved at pinned commits under `evidence/upstream`.

## Configuration defects discovered during validation

Prisma 0.1.2-A’s manual parser stops a JSON value at its first space. Our initial pretty-printed profile therefore produced radius 6 and disabled booleans despite a valid JSON file requesting otherwise. The profile tool now writes compact JSON, matching Prisma’s own writer. An isolated probe against the installed class reproduces the empty-token behavior in `evidence/config-parser-probe.txt`; no game state is involved in that probe. The affected early benchmarks are excluded. Minecraft 26.2’s Fancy graphics preset also reapplied chunk distances, so the final profile uses Custom and verifies live values after restart.
