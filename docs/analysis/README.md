# Prisma on M5 Pro — results and files

The isolated instance is **26.2 Prisma — M5 Pro Test**. The original **26.2** instance remains the rollback path. All 14 original mods are retained.

The subsequently authorized renderer implementation is tracked separately in [Metal RT development](../development/README.md). Its experimental intersection/lighting kernels are not enabled in this tuned Prisma instance.

- [Before-and-after viewer](BEFORE-AFTER.html): matched lakeside and material-test views, plus AO, point-light and sun-control comparisons. Open the HTML in a browser, keeping the `screenshots` folder alongside it. Its local in-app preview uses a temporary loopback server at port 8876.
- [Benchmark results](BENCHMARKS.md): accepted samples, GPU timing, memory, sustained-run status and measurement limits.
- [Renderer audit](REPORT.md): what ray tracing means, how the installed Prisma renderer works, requested effects, and Cyberpunk/Control case studies.
- [Hardware RT development specification](HARDWARE-RT-ROADMAP.md): staged interfaces, source-access dependency, real intersection proof, scene updates, effects and reconstruction.
- [Visual test results](VALIDATION.md) and [mod compatibility matrix](MOD-COMPATIBILITY.md).
- [Profiles, reproduction and rollback](BENCHMARK-PROTOCOL.md).
- [Installed Minecraft skills](SKILLS.md) and [local diagnostic tools](../tools/README.md).

## Gameplay preset

Actual framebuffer: 1920×1200, obtained with a 960×600-point window on this Retina display. Minecraft graphics preset: Custom. Render/simulation distances: 12/8 chunks. Prisma voxel radius: 8. Java maximum heap: 4 GB. Final cap: 60 FPS. Original AO, point lights, shadow controls and water settings remain enabled. This release still uses software voxel tracing in Metal; hardware ray tracing and general multi-bounce GI were not added by configuration changes.

Do not pretty-print `prisma.json`: this release’s parser mishandles spaces after colons. The supplied profile tool writes the compact form Prisma itself uses.

## Revisit the test scenes

The user-created copied-world folder remains `New World (5)`, with the displayed world name changed by the user to `Minecrafy_RT_Test`. It is Creative/Peaceful with commands enabled. The test clock/weather are fixed for reproducible views.

Water/material test:

```mcfunction
execute in minecraft:overworld run tp @p 1040 129 1055 180 15
```

Lakeside view:

```mcfunction
execute in minecraft:overworld run tp @p -91.91068512257155 63 -154.7452272161358 39.30002 23.84996
```

To resume the normal day and weather cycle in this test world:

```mcfunction
gamerule minecraft:advance_time true
gamerule minecraft:advance_weather true
```

No test-world edits should be copied over the original saves as part of rollback. Launching the untouched original instance returns to the original setup; resetting the test profile with the supplied tool preserves the copied test worlds.
