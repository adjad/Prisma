# Reconstruction of rare bright ray samples

The development renderer now carries per-channel sampling variance for reflections, indirect diffuse light and local direct light into custom temporal reconstruction. Installed candidate: `1aecee0f9817779e98bd33edb1bb79eee4bfd689f1629069f5c08075872c552a`.

## Problem and implementation

The earlier dynamic filter compared one noisy frame against history and clipped history to a small current neighborhood. Rare bright samples triggered the same response as real lighting changes, while zero-event neighborhoods erased accumulated light. A controlled three-ray Bernoulli test at 3% event probability retained 96.8% of the raw mean-squared error: very little smoothing.

Each lighting estimator now computes the unbiased variance of its sample mean: `(sum(x²) - sum(x)²/n) / (n*(n-1))`. Separate RGB estimates retain color-specific noise information. Reprojection carries those estimates across matching surfaces; a short variance history keeps uncertainty through frames in which all rays miss a rare contributor. That uncertainty expands the existing clipping and innovation bounds. It does not multiply light energy, add rays or average neighboring colors into the displayed radiance.

This is a targeted modification of this renderer's existing temporal filter. Variance-guided reconstruction is established in [Schied et al., *Spatiotemporal Variance-Guided Filtering*](https://research.nvidia.com/labs/rtr/publication/schied2017spatiotemporal/), which combines temporal accumulation and variance-guided spatial filtering. This implementation does not reproduce the paper's full algorithm or its wavelet filter.

Three current and six history RGBA32F textures cost a calculated 79.1 MiB at 1920×1200 with half-resolution ray shading. This is an allocation calculation, not a process-memory measurement. A one-ray tier cannot estimate within-frame variance and retains the older response for this case. MetalFX's denoiser and the unfiltered full-resolution edge-repair path are unchanged.

## Native evidence

`rt-core/TemporalProof.mm` now binds every local-light/variance resource and tests independent rare-event samples across reflection, GI and direct lighting. The earlier test harness had omitted the local-light texture bindings; that omission is corrected.

| Measurement | Previous filter | Variance-aware filter |
|---|---:|---:|
| Sparse radiance MSE / raw MSE | 0.967935 | 0.070493 |
| Mean output energy / input energy | 0.986074 | 0.996996 |
| Mean remaining radiance after 32 zero-input frames | 0 | 0.000426 |

The new filter lowers this test's MSE by 92.7% relative to the previous filter and preserves mean energy within 0.4%. The deterministic disappearing-reflection and moving hard-shadow cases still have zero maximum error. Surface/normal/depth rejection, explicit reset, exact reprojection, odd framebuffer dimensions and ordinary noise tests continue to pass. This controlled test does not establish full-game motion quality or absence of ghosting.

All twelve tests in `rt-core/results/sparse-final-regression-suite.json` pass with Metal API validation. `sparse-temporal-shader.json` passes shader validation. `sparse-temporal-20260914.gputrace` captures the full local-light frame path; its resource-lifetime/removal/alpha tests pass.

The first broader API-validation run exposed an existing empty-light binding bug: tiny triangle buffers were being used where Metal expected at least one 80-byte sampled-light element. The renderer now binds a dedicated empty resource. Initial failures remain in `sparse-regression-suite.json`; final results above demonstrate the correction.

## Live validation

Twelve unmodified frames per renderer were captured at 200 ms spacing, from the same camera and reversible lamp/hidden-ceiling fixture, using reflection-only mode, local lighting, three samples and dynamic temporal filtering. In `runs/sparse-temporal-live-noise.json`, mean temporal variance falls 72.8% in lamp-reflection rectangle [840,490,1070,690], and 55.4% in reflected-ceiling rectangle [700,760,1150,960]. Mean RGB changes by less than 0.24 eight-bit levels in those regions. The left-floor region shows 8.9% more variance, while the distant grazing-floor region is essentially unchanged (+0.6%). Those results are retained; this is not a uniform whole-image improvement. The distant edge path does not use this temporal filter.

Three ten-second all-effects profiles with the same white-receiver fixture as the prior stage measure 59.670, 59.588 and 59.582 CPU frame-loop FPS. Their p95 values are 17.336, 17.498 and 17.516 ms; p99 is 17.954–18.071 ms. No interval exceeds 18.231 ms in those profiles. The previous build's corresponding short profiles measured 59.546–59.746 FPS and p95 17.162–17.514 ms. These short runs do not establish a statistically resolved performance difference. Raw profiles: `runs/sparse-temporal-all-effects-results.json`.

The temporary blocks were restored and the player returned to the normal platform view. The previous renderer is backed up by SHA (`ccdeb8e53ffbdedb942fd4acfd2699e66805f7fbb3e02c7561339600880ac18c`); the scoped installer can restore that backup while the development game is closed. `runs/original-preserved-sparse-temporal.json` reports no changed original-instance files and 14 retained mods in the tuned Prisma instance. Source and packaged/native hashes are recorded in `runs/sparse-temporal-build-verification.json`.

The 20-minute monitoring script is `run_sustained.py`. It verifies the development process identity and AC power, samples memory/swap/pressure every ten seconds, and requests ten-second CPU frame profiles once per minute. It neither changes settings nor moves the player. This measures a sustained stationary session with sampled frame timings; continuous presentation intervals, broader motion acceptance and full physical composition remain open.

The stationary monitoring run is now complete. See [SUSTAINED-VALIDATION.md](SUSTAINED-VALIDATION.md) for the measured results and their limits.
