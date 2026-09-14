# Twenty-minute stationary session

The development instance completed a 1,200.27-second session on AC power using renderer `1aecee0f9817779e98bd33edb1bb79eee4bfd689f1629069f5c08075872c552a`. The process survived, and every sampled client inspection reported an unpaused world, no inactive-window throttle, no ray-pass failure, a 1920×1200 framebuffer and a 60 FPS cap.

The restored platform camera remained stationary. All effects were enabled, with three samples, one diffuse bounce, dynamic temporal reconstruction, local lights, an eight-chunk full-height ray scene and MetalFX off. No blocks, camera positions, settings or renderer binaries were changed during the session. Lightweight source editing and dependency inspection occurred in Codex; compilation and native GPU tests were deferred until completion. Other desktop applications remained open.

| Measurement | Result |
|---|---:|
| Session duration | 1,200.27 s |
| Ten-second profiles | 20, covering 200.16 s total |
| Weighted sampled CPU frame-loop FPS | 59.636 |
| Sampled frame-loop p95 | 17.355 ms |
| Sampled frame-loop p99 | 18.001 ms |
| Largest sampled interval | 22.342 ms |
| Process RSS, start → end | 6.43 → 3.76 GiB |
| Process RSS range | 3.50–8.91 GiB |
| System swap growth | 0 GiB; 1.60 GiB remained in use |
| Profiled Java heap range | 847.6–1,376.2 MiB |
| Native mean command GPU-time snapshots | 6.60–7.84 ms |

The sampled p95 meets the requested 20 ms threshold. This supports a sustained stationary result near the 60 FPS cap; it does not establish continuous presentation timing or acceptance under chunk streaming, dimension changes and rapid camera movement. No generated frames were used.

Resident memory rose and then fell below its starting value. This run does not show monotonic resident-memory growth, but RSS alone cannot prove absence of a leak or identify native allocation ownership. `memory_pressure -Q` reported a system-wide free percentage of 40–67%, ending at 40%; this is a global reading, not the game's exclusive memory footprint. Swap did not grow.

![Measured RSS and sampled p95](runs/sparse-sustained-20260914/sustained.svg)

## Evidence and reproducibility

- `runs/sparse-sustained-20260914/metadata.json` records renderer hash, process identity, setup and start time.
- `resources.jsonl` contains 121 ten-second process, power, swap and free-percentage snapshots.
- `completion.json` records successful duration, process survival and all profile requests.
- `profiles.json` and the twenty raw profiling ZIPs contain the sampled timings and heap readings.
- `summary.json` includes every checked client inspection and the precise aggregate statistics.
- `run_sustained.py` captures a marked development instance; `summarize_sustained.py` derives the report from completed raw evidence.

Native GPU numbers are command-buffer means, not a separate measurement of each full displayed frame. Profiling covered roughly one sixth of the session. The original Prisma instances are preserved; this result does not replace their original benchmark record or the remaining broader acceptance work.
