# Prisma Metal RT

An experimental Minecraft 26.2 renderer for Apple silicon, built from
[Metallum](https://github.com/kokodio/metallum). It connects Sodium's rendering
backend to a native Metal core that builds triangle acceleration structures and
issues hardware ray-intersection queries.

The current development build includes ray-traced sun and local-light shadows,
ambient occlusion, roughness-aware reflections, diffuse global illumination,
water and glass transmission, posed entity geometry, temporal reconstruction,
HDR composition, and optional MetalFX reconstruction. These systems execute on
Metal's ray-tracing path; they are no longer Prisma's original shader-only voxel
traversal.

This remains a development renderer. The balanced preset targets 1920×1200 at
60 FPS on the tested M5 Pro, but broad-world, moving-camera, water, glass, and
MetalFX quality acceptance are still in progress. MetalFX is disabled in the
balanced preset because its latest targeted-history mode improves floor/contact
stability while increasing speckles on one tested gold surface.

## Repository layout

- `src/`: Fabric/Java 25 integration, Minecraft scene extraction, settings, and
  the Java-to-native bridge.
- `rt-core/`: Objective-C++ and Metal shaders for acceleration structures,
  lighting, reconstruction, MetalFX, and executable GPU proofs.
- `diagnostics/`: isolated command/settings proofs used by Gradle checks.
- `docs/analysis/`: the original renderer audit, benchmarks, compatibility
  notes, and hardware-RT roadmap.
- `docs/development/`: milestone reports, compact results, and the original
  before/after captures.

[Open the before/after comparison viewer](docs/development/BEFORE-AFTER.html),
or read the [current requirement status](docs/development/PHASE-STATUS.md).

## Requirements

- Apple silicon Mac with hardware ray tracing for the RT path (M3 generation or
  newer; developed and measured on M5 Pro)
- macOS 26 or newer for the current development target
- Xcode with the Metal and MetalFX SDKs
- Minecraft 26.2, Fabric Loader 0.19.5, Fabric API, and Sodium 0.9.2
- Java 25

## Build

```sh
./gradlew build
```

The build compiles `rt-core/librtcore.dylib`, packages it and `trace.metal` into
the Fabric JAR, then runs 40 persistent-setting checks and 14 real Brigadier
command checks. Native proof programs are built under `rt-core/build/`; run them
on supported Apple hardware as described in
[the development guide](docs/development/README.md).

The buildable mod still uses Metallum's internal package and mod identifiers to
preserve compatibility with the verified development instance.

## Verified state

The published milestone passed 18 native GPU regression programs. In the latest
moving-entity comparison, three ten-second passes stayed near 60 FPS with p95
CPU frame-loop times of about 16.7–16.8 ms. The targeted MetalFX history change
reduced measured temporal variation by 66% on a floor patch and 89% near a
contact region, while the gold-face patch regressed by 166%. These are controlled
scene measurements, not a claim of complete gameplay acceptance. See
[MetalFX dynamic validation](docs/development/METALFX-DYNAMIC-VALIDATION.md) for
the exact setup and limits.

## License and credits

The inherited Metallum source retains its MIT license in `LICENSE`. The native
RT core is MIT licensed separately in `rt-core/LICENSE`. Credit remains with
kokodio and the original Metallum contributors; the hardware-RT development is
documented in this repository's history and validation records.
