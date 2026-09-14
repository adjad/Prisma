# Repeatable benchmark and rollback

## Profiles and isolation

The original `26.2` instance is never the target of configuration writes. Test instance ID: `26.2-Prisma-M5-Pro-Test`, displayed as **26.2 Prisma — M5 Pro Test**. The complete original instance was copied before launch, including five saved worlds. An additional world created in the test instance is independent of the original.

`analysis/baseline/source-manifest.json` records original file hashes. Baseline copies of `instance.cfg`, `mmc-pack.json`, `options.txt` and `prisma.json` provide reviewable settings. Run `python3 tools/prisma_instance.py verify` to check the original against its snapshot.

Close Minecraft before invoking file-based profile changes. The tool refuses to change profiles while any Java executable is running. Every profile change is recorded in `analysis/profile-history.jsonl`.

- `baseline`: original render distance 16, simulation 12, voxel radius 16; normalized output and benchmark focus behavior.
- `candidate`: render 12, simulation 8, voxel radius 8, same lighting, 4 GB heap.
- `no-ao`, `no-point-lights`, `no-sun-shadows`: candidate with precisely the named effect disabled.
- `final`: candidate settings with a 60 FPS cap and the HUD wrapper disabled.

The test profile uses a 960×600-point window on this 2× Retina display to obtain a 1920×1200 framebuffer. This is intentionally windowed: the earlier macOS window/fullscreen state rendered at 3456×1962 despite a saved 1920×1200 mode. Verify the actual framebuffer after moving the window to another display. A fullscreen mode string alone is insufficient. The original display configuration is preserved in the original instance.

For measurement, VSync is disabled, maxFps is 260 (Minecraft's unlimited cutoff), pause-on-lost-focus is false, and inactivity mode is `minimized` rather than `afk`. Do not minimize the game: iconification can still throttle rendering. Inspect the runtime throttle reason and pause flag with every run. The final instance keeps background simulation enabled so testing does not pause unexpectedly; users can restore pause-on-lost-focus in Options after benchmarking.

## Record a run

Warm up the loaded world and shaders for at least 60 seconds. Use the same saved world, coordinates, yaw/pitch, time and weather for A/B comparisons. Separate generation/streaming tests from stationary loaded scenes. Do not move the camera during a stationary sample. Record power and memory conditions before and after each group.

The local `PrismaDiagnostics` agent queries the actual game state and triggers the same built-in metrics recorder exposed by F3+L. It uses Java's diagnostic attach API, does not transform bytecode, and rejects every instance directory except the isolated test directory. Its source and build products are local under `tools/diagnostics` and `analysis`. It is not installed as a gameplay mod. The agent remains loaded only for that JVM session.

Use the exact Java runtime bundled with the instance:

```sh
JAVA='<user-home>/Library/Application Support/PrismLauncher/java/java-runtime-epsilon/bin/java'
"$JAVA" --add-modules jdk.attach -jar analysis/prisma-diagnostics.jar PID inspect
"$JAVA" --add-modules jdk.attach -jar analysis/prisma-diagnostics.jar PID metrics-LABEL
```

Read the generated inspection file before interpreting metrics. The game writes its profiling archive under the test world's Minecraft `debug/profiling` directory. Keep an untouched copy of each archive. Never substitute sampled last-frame durations for a real per-frame distribution.

For presentation and GPU data, record a short Metal System Trace with Xcode's `xctrace`. Export the `ca-client-presented-handler` and Metal GPU tables, filtering to the game PID and layer. Profiling overhead, AFK state, window resizing and compilation intervals must be recorded. The first diagnostic trace in this task is explicitly invalid for A/B performance conclusions because resolution and throttle state were not controlled.

Apple HUD logs are useful for a time series, but this OS redacts some entries. Do not fabricate unredacted frame timings or infer a percentile from an FPS average. Do not disable system log privacy to obtain metrics.

## Visual suite

Use a copied creative world or a dedicated test area:

1. Water next to a distinct colored structure. Turn the camera until the structure leaves the primary view while its reflection remains visible. Compare near and far reflection limits.
2. Glass, leaves, a slab and stairs around a torch; compare holes, transparency and thin silhouettes. Add a moving entity.
3. One light, one blocker and a receiver. Move the blocker/receiver through several distances; check contact hardening and light leaks.
4. A wall/floor corner and close adjacent blocks for AO. Disable VXAO and compare identical framing.
5. Red and neutral walls in an interior. Test indirect color bleeding; distinguish actual transport from tinted direct or ambient light. Current Prisma has no general GI implementation.
6. Sun-shadow setting on/off with fixed time, weather, camera and static geometry; isolate that toggle from moving water, clouds and particles.
7. Place/remove blocks and lights, cross chunk boundaries, teleport, change dimensions, and perform fast camera turns. Report temporal updates separately from static quality.

For each configuration, collect three timed samples after warm-up. Then run the selected profile for 20 minutes. Record crashes/errors, average FPS, frame-time percentiles from a genuine per-frame source, available GPU timings, RSS/physical footprint, heap/GC evidence, memory pressure and swap deltas. A successful launch or screenshot is not a completed visual suite.

## Acceptance

Target 60 rendered FPS and p95 presented frame interval ≤20 ms in defined steady scenes. Report p99 and streaming hitches separately. Frame generation is not used. A 60 FPS cap can create minor pacing variation; investigate failures rather than rounding them into a pass. If a metric cannot be collected, mark it unavailable. If the hardware target is not reached, preserve a playable preset and report the limitation.

## Rollback

Launch the untouched **26.2** instance to return to the original installation. To reset the test instance's measured lighting settings, close the game and run `python3 tools/prisma_instance.py baseline`. This baseline deliberately retains corrected benchmark window/focus settings; the byte-for-byte originals remain under `analysis/baseline` and in the original instance.

No original mod was removed. Disable instrumentation by using the `final` profile (empty test-instance wrapper command) and restarting Minecraft. Restarting also unloads the local diagnostic agent. Do not copy the test world's changed saves back over original saves as part of rollback.

## Critical Prisma 0.1.2-A persistence requirement

Write compact JSON with no spaces after colons (`json.dumps(..., separators=(",", ":"))`). This release’s manual parser treats initial whitespace as the end of a value. Pretty JSON silently disables boolean features and leaves numeric defaults. Always verify live values after restart. The profile tool now writes compatible compact JSON.

Minecraft 26.2 also applies `graphicsPreset` at startup. The tuned profile sets `graphicsPreset:"custom"`, so the Fancy preset cannot restore 16/12 distances over the requested 12/8. Runtime verification is required after restart.
