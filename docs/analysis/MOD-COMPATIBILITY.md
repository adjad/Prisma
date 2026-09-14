# Mod compatibility matrix

Exact JAR versions, declared dependencies and SHA-256 hashes are in [mod-manifest.json](evidence/mod-manifest.json). All 14 top-level mods remain enabled. No speculative removal has been applied. “Launch observed” establishes startup, not every gameplay interaction.

| Mod | Decision | Evidence and remaining targeted check |
|---|---|---|
| Prisma 0.1.2-A | Keep | Active Metal backend; shader audit documents its limits. |
| Sodium 0.9.2+mc26.2 | Keep | Renderer integration baseline; active in test launch. |
| Fabric API 0.160.0+26.2 | Keep | Existing dependency baseline. |
| Fabric Language Kotlin 1.14.1+kotlin.2.4.20 | Keep | Runtime dependency; no evidence supporting removal. |
| Lithium 0.25.3+mc26.2 | Keep | Simulation optimization; launch observed. Watch tick time independently of GPU time. |
| FerriteCore 9.0.0 | Keep | Memory optimization; launch observed. |
| Fzzy Config 0.7.6+26.2 | Keep | Existing configuration dependency. |
| ZConfig 1.0.0+26.x | Keep | Existing configuration dependency. |
| ImmediatelyFast 1.16.4+26.2 | Keep | Explicitly reports successful initialization on Apple M5 Pro using Metal. Check HUD, transparent draws and particles if artifacts occur. |
| EntityCulling 1.10.5 | Keep | No demonstrated startup conflict. Current Prisma voxel reflections do not establish general entity reflection support; a future RT scene must bypass camera-only culling for reflected entities. |
| C2ME 0.4.2-alpha.0.52+26.2 | Keep | World loads and negotiates extended render-distance support. Missing macOS arm64 native math library indicates that optional acceleration is unavailable; it does not prove all C2ME acceleration is disabled. Check chunk-edit/streaming consistency. |
| ScalableLux 0.3.0-alpha.0.3+26.2 | Keep | Lighting-engine optimization, not replacement hardware GI. Check light propagation after placing/removing emitters. |
| AsyncParticles 26.2.2.8 | Keep | Log explicitly says certain cancelled mixins are expected compatibility behavior. Check motion/lighting during particle-heavy scenes. |
| Particle Core 0.3.3+26.2 | Keep | Launch observed alongside AsyncParticles; a cancelled brightness mixin alone does not establish failure. Compare both mods separately only if a reproducible particle defect occurs. |

If a reproducible artifact or crash appears, save its log and camera/world state. Reproduce twice, disable one implicated top-level JAR through Prism's checkbox in the test instance, rerun, and then restore it to confirm the result. Preserve required dependency libraries. Record both successful and unsuccessful isolation attempts. Do not remove performance mods merely because a warning mentions them.

## Executed integration checks

The current combined mod set passed the scoped visual smoke tests described in [VALIDATION.md](VALIDATION.md): material/HUD rendering, moving pig, 800-particle burst, block and emitter removal/restoration, eight streaming teleports, and a Nether/Overworld round trip. No individual mod was disabled because these checks did not produce a reproducible conflict to isolate. These results do not certify every mod interaction or missing reflection feature.
