# Temporal lighting during entity motion

This stage evaluates an optional custom-filter change. It does not complete per-entity motion vectors, full temporal acceptance or the wider renderer plan.

## Implementation

The previous path resets all lighting history when any posed geometry changes. The new `metallum.rt.dynamicTemporal` option instead preserves primary-surface reprojection, then rectifies old lighting against a 3×3 neighborhood of current samples on the same surface. Neighbors must have compatible normals, roughness, plane position and static/dynamic classification. Neighborhood colors are not spatially averaged into the output.

History is clipped to the intersection of the sampled range and a two-standard-deviation interval. Innovations outside the interval select the current sample. AO uses a broader three-standard-deviation innovation band with a 0.25 minimum because four visibility rays produce discrete Monte Carlo variation. The responsive interval limits history to eight frames and continues for 32 frames after the last geometry change, including removal. Changed dynamic primary surfaces reject history outright. Static camera/normal/primitive/disocclusion checks remain in place.

Neighborhood validation and rectification are established temporal reconstruction techniques; this is a local implementation, not a port of the cited renderer. [Adaptive Temporal Antialiasing](https://research.nvidia.com/sites/default/files/pubs/2018-08_Adaptive-Temporal-Antialiasing/adaptive-temporal-antialiasing-preprint.pdf).

The option uses bit 7 of the existing frame flags. The internal native/shader temporal-parameter layout grows from 240 to 256 bytes; the public 144-byte frame ABI remains unchanged. The option defaults off while evaluated. MetalFX retains conservative whole-history resets because this custom resolve does not run in MetalFX mode.

## Native tests

`TemporalProof.mm` now includes a moving secondary-light rectangle on an unchanged primary plane. A fixed region receives four-ray AO noise while the rectangle changes hard-shadow visibility and reflection color elsewhere. It also tests removal. The first candidate reduced AO variance by only 47%, failing the preselected 70% reduction requirement. The revised AO rule produces a variance ratio of 0.08477, or 91.5% reduction. The controlled hard-shadow and removed-reflection channels have zero maximum error within the printed precision. These synthetic signals do not establish correctness for every glossy, transparent or animated scene.

The existing static-noise, reprojection, five rejection cases and odd-size tests still pass. Frame composition and MetalFX regression tests pass with the extended parameter layout. Results are under `rt-core/results/dynamic-temporal-*.json`.

## Live validation

A fixed gold pillar was added beside the tagged cow. Twelve frames per mode were captured at 1920×1200 with the camera stationary and the cow moving. Regions were selected from the fixture image before comparing the series. All effects remained enabled, using four half-resolution samples and eight edge samples.

| Region | Before variance | After variance | Reduction |
|---|---:|---:|---:|
| Pillar contact region | 27.774 | 8.874 | 68.05% |
| Plain floor reflection | 0.874 | 0.810 | 7.28% |
| Gold face | 3.453 | 2.756 | 20.18% |

The contact-region mean RGB changes by less than 0.4 on the 0–255 scale. A fourth preselected region, named `pillar_shadow`, also contains the moving cow's reflection; its measured 4.17% variance decrease includes actual scene movement and is not a sampling-noise result. All selected regions and source hashes remain in [the measurement artifact](runs/dynamic-temporal-live-noise.json), reproducible with `../tools/measure_dynamic_temporal.py`.

The native counters show geometry continuing to update while global history resets remain fixed after enabling the option. The screenshots still contain noise near the pillar and glossy surfaces. The full-resolution edge repair bypasses this custom temporal resolve. No claim of full-scene ghosting elimination or completed entity motion vectors is made.

The installed build retains the option as a development setting, enabled in this running test session and off by default after restart. `rt-temporal-diagnostics.jar PID dynamic-on` and `dynamic-off` switch between the candidate and prior behavior; both require Java's `--add-modules jdk.attach` launcher option. Testing affects only the copied development world.

## Performance, preservation and limits

Three ten-second profiles during the new 60-second motion trial measured 59.33–59.69 CPU frame-loop FPS, p95 17.08–17.68 ms, and a maximum sampled frame time of 27.31 ms. This meets the short-test p95 threshold but does not establish presented 60 FPS or the required 20-minute final acceptance. [Profiles](runs/dynamic-temporal-performance.json).

Across the start/end diagnostic interval, 3,551 dynamic updates occurred while the global reset count remained at 2,152. The interval includes time after the motion stopped; it is not used as a pure-motion GPU timing measurement. Compare `entities-inspect-dynamic-profile-start-*` and `entities-inspect-dynamic-profile-end-*` under `runs`.

The source JAR, native library and shader are verified against the installed development build. The prior entity build is backed up under SHA-256 `2c2c473873ce374af9a0bc0113e31010e1cf61980e7a01afbdd476a551ee22dc`. With the development game closed, the guarded installer can restore it with `--rollback-sha`; `--dry-run` checks the source without changing the game.

Remaining work includes per-entity motion vectors, rough/transmissive material history validation, stronger live disocclusion and thin-shadow checks, temporally reconstructed full-resolution edge samples, larger scene coverage and final sustained testing. The full goal remains active.
