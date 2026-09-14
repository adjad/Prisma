# Benchmark results and execution status

## Configuration-parser finding — earlier captures excluded

Live inspection found that Prisma 0.1.2-A uses a whitespace-sensitive hand-written JSON parser: `findJsonEnd` stops immediately at a space after a colon. The profile tool originally wrote pretty-printed JSON. Numbers silently fell back to constructor defaults (voxel radius 6), and booleans became false. The intended 16/8 radius and enabled lighting were therefore not active in the early captures. This was an error in our configuration workflow, corrected by writing compact JSON exactly as Prisma does.

All captures before the 02:08 restart, including the earlier three “baseline” ZIPs, three candidate ZIPs and both Metal traces, are excluded from preset performance conclusions. They remain diagnostic evidence only. Their high frame-loop counts must not be presented as enabled-lighting performance. Future measurements verify live radius and lighting flags as well as actual dimensions, pause/throttle state and frame cap.

Actual 1920×1200 resolution was independently verified even in the excluded runs. The initial almost-4K state was 3456×1962; the working Retina window is 960×600 logical points. No original-instance files were changed by this correction.

## Instrumentation limits

Minecraft 26.2 emits macOS 27 codename/crash-report-handler warnings during profiling archive packaging, but successfully creates the ZIP after a short delay. These are not observed game crashes. CPU-side profiler frame-loop times are distinct from displayed intervals. Metal System Trace callback timestamps track roughly renderer throughput rather than verified display scanout; inconsistent requested-time values and backdated signposts in this OS/toolchain combination prevent using them as proof of displayed FPS. GPU interval attribution is reported separately where usable.

Corrected results follow below after measurement.
## Corrected measurements

The original and tuned settings were tested at the same actual 1920×1200 framebuffer, with the camera/time/weather fixed and all 14 mods present. Each accepted group contains three approximately ten-second passes. The renderer/JVM was already warm; camera changes received 12–15 seconds of settling time. Each pass records matching start/end positions, pause/throttle state, dimensions, radius and effect flags. These checks establish the endpoints, not every intermediate camera sample.

Original settings: 16 render chunks, 12 simulation chunks, voxel radius 16. Tuned settings: 12/8/8. A useful intermediate group changes only radius to 8 while retaining 16/12 distances. Lighting remains enabled in every group. The tuned preset uses Custom graphics settings to preserve its distances on reload.

| Scene | Original renderer FPS, three passes | Tuned renderer FPS, three passes | Tuned CPU frame p95 range |
|---|---|---|---|
| Test platform / water | 120.10, 120.09, 120.08 | 585.30, 547.80, 516.25 | 2.11–2.39 ms |
| Natural lakeside | 120.05, 120.08, 119.95 | 407.30, 407.22, 406.12 | 2.45–2.46 ms |

The radius-only platform group measured 473.65, 467.90 and 477.00 renderer FPS. These are the built-in client recorder’s completed renderer-loop rates, not physical display refresh rates. Both benchmark groups request unlimited FPS (`maxFps=260`, VSync option false), but the original group has a striking ~120 ceiling. Presentation scheduling, GPU clocks and process history were not fully isolated; do not market the ratio as a guaranteed 4–5× GPU speedup. The final capped samples and GPU trace are the stronger evidence for the 60 FPS target.

Full per-pass p95/p99 values and archive names: [results table](results-table.md), [machine-readable CSV](runs/verified-results.csv), [state manifests and metrics](runs/verified-results.json).

## Final 60 FPS preset

The first three capped lakeside passes measured 59.78, 59.57 and 59.79 renderer FPS; CPU frame p95 was 17.03, 17.49 and 17.01 ms. At the ten-minute midpoint, the sample measured 59.61 FPS, p95 17.47 ms and p99 17.96 ms. The live Minecraft FPS counter reported 59 or 60. A nominal 60 cap incurs small scheduler/pacing overhead; this supports approximately 60 FPS rather than a strict claim of at least 60.000 in every interval.

A ten-second Metal System Trace at the capped lakeside view attributed 610 complete frame groups to the game after excluding boundary groups. The union of top-level active GPU intervals within each frame averaged **6.73 ms**, with **p95 9.65 ms** and **p99 10.94 ms**. Unioning avoids double-counting overlap between GPU channels; it is not full CPU-to-display latency. The GPU frame-span p95, including gaps between attributed work, was 18.80 ms. Raw trace and exporter summaries are retained under `runs/final-60-*`.

Presentation callbacks averaged 59.52/s with interval p95 **19.34 ms** and p99 **33.17 ms**. Callback arrival is a timing cross-check, not a calibrated scanout timestamp. The CPU p95 and callback p95 both fall below the requested 20 ms threshold in this measured scene, while p99 exposes occasional longer intervals. No frame generation is used. Exact display-scanout acceptance and a continuous 20-minute frame-time percentile are not claimed.

## Streaming sample

Eight teleports through new terrain with rapid camera changes were performed, followed by a Nether/Overworld round trip. A separate ten-second profile covering part of the streaming sequence measured 59.83 renderer FPS, CPU p95 16.75 ms, p99 17.78 ms and maximum 22.27 ms. That profile does not cover every frame of every transition. The scene visibly recovered after the round trip; the final state retained 12/8/8 and a 60 cap. See [visual validation](VALIDATION.md).

## Memory and sustained-session status

The run started at 02:18:56 local time on AC power, battery 36% and charging. Resource samples occur every ten seconds; brief frame profiles sample the beginning, midpoint and end. A short Metal trace, blocker-distance changes, new terrain and one dimension round trip are included in the session, with long stationary lakeside periods. Rendering configuration remains unchanged throughout.

The Java heap stays at 4 GB. Native voxel-buffer allocation falls from a calculated 768 MiB at radius 16 to 192 MiB at radius 8, saving 576 MiB. This is a formula-derived allocation difference, not a measured whole-process reduction. Heap, native resources and other applications all share unified memory. System swap is reported as a machine-wide value, not as Minecraft-only paging.

**Completed:** 1,200.005 seconds, with 121 resource observations. The process remained running, all power readings were AC, and battery charge increased from 36% to 60%. No game crash occurred. Known profiler-packaging warnings remain in the log; they did not prevent the six archives from being created.

Across six capped profiles distributed through the session, renderer FPS ranged **59.57–59.97**, and CPU frame p95 ranged **16.68–17.49 ms**. The final two windows did not show a loss of the measured 60 FPS capability. These are sampled-window statistics, not an uninterrupted 20-minute distribution.

Minecraft RSS ranged **2,670.73–2,990.91 MiB** (about 2.61–2.92 GiB), ending at 2,936.97 MiB. Sampled Java heap ranged **586.07–1,665.11 MiB**, leaving substantial room within the 4 GB cap. The system-wide swap reading decreased from **2,707.5 to 2,611.5 MiB** (−96 MiB). `memory_pressure -Q` reported a free-percentage range of 74–80%; that output is preserved verbatim and is not a process-private allocation metric. A separate kernel pressure query returned level 1 during the run. Other applications were not closed, so system-wide changes cannot be attributed solely to Minecraft.

Evidence: [completion](runs/sustained-completion.json), [summary](runs/sustained-summary.json), [resource log](runs/sustained.jsonl), [per-pass values](results-table.md). The final preset retains all 14 mods and a 4 GB heap; no mod-removal or heap-increase experiment was warranted by the observed workload.

## Final installation and practical limits

The game was restarted with the final Custom graphics profile, a compact Prisma configuration and an empty profiling wrapper. Temporary forced chunks created for test-area construction were released. Restarting unloaded the diagnostic helpers from the measured session. A single readback helper was attached after restart to confirm persistence; it is now idle and disappears on the next normal game exit. No helper is installed in the mods folder or launch configuration.

[Final live verification](runs/inspect-final-persisted-1789379040597.txt) confirmed an actual 1920×1200 framebuffer, Custom graphics, 12/8 chunk distances, voxel radius 8, a 60 FPS cap, all three inspected lighting flags enabled, and an unpaused loaded world. The live FPS counter read 60. The final original-instance hash check found no changed files and confirmed all 14 test mods remain installed: [verification](evidence/original-verification.json).

The target is supported for the defined sampled scenes at the nominal 60 cap. This is not a guarantee for every world, exact physical display scanout, or future hardware ray tracing. The public Prisma checkout still lacks buildable renderer sources. Hardware intersections, general glass/metal reflections and multi-bounce GI remain development work described in the roadmap.
