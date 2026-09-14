# Persistent Metal RT controls

Implemented, built and verified in the copied development instance. The initial controls build passed 41 automated checks; the current build passes 44. Live commands apply and save settings, and a fresh game process restores the balanced preset without session-setting helpers. The initial controls build retained the native renderer used in the completed [twenty-minute stationary test](SUSTAINED-VALIDATION.md). Subsequent surface-lighting and direct-specular changes have their own validation reports; that sustained result is historical.

## Interface

The implementation uses Fabric's [client command API for Minecraft 26.2](https://docs.fabricmc.net/develop/commands/basics). Commands run locally, without server operator permissions or server-side installation. Mutating branches require an attended client command; feedback stays on the local client.

| Command | Behavior |
|---|---|
| `/metalrt status` | Current effective controls, renderer state, framebuffer size and FPS |
| `/metalrt help` | Commands, supported keys, ranges and current values |
| `/metalrt preset performance` | All effects, two ray samples, one diffuse bounce |
| `/metalrt preset balanced` | All effects, three samples, one bounce |
| `/metalrt preset quality` | All effects, four samples, two bounces |
| `/metalrt set reflections 0.5` | Set a normalized effect strength and save it |
| `/metalrt set mode off` | Disable hardware effects while retaining the raster renderer |
| `/metalrt set mode hybrid` | Enable the hardware effect pass |
| `/metalrt save` | Persist all effective settings, including valid session changes |
| `/metalrt reload` | Validate and apply the saved configuration |

Presets enable temporal and dynamic temporal reconstruction, local lights and entities; they leave experimental MetalFX disabled and use an eight-chunk ray scene. They do not change Minecraft render/simulation distance, window size, FPS limit or Java heap. Quality costs more GPU work and does not promise 60 FPS.

Supported settings: `toneMapping` (default true; applies highlight rolloff and display exposure only to physical surface lighting), `exposureEv` (-8..8, fractional, default zero), `directSpecular` (default true, applies to opaque materials in physical surface lighting), `physicalLighting` (experimental, default false; see [validation](PHYSICAL-LIGHTING-VALIDATION.md)), `mode`, `samples` (0 automatic, 1–4 explicit), `bounces` (1–4), `ao`, `shadows`, `reflections`, `gi` (each 0–1), `localLights`, `entities`, `temporal`, `dynamicTemporal`, `transmissionGi`, `edgeRefine`, `metalfx`, `metalfxSurfaceGuides`, `metalfxFullSamples` (booleans), and `chunkRadius` (1–8). Changing radius invalidates the collected ray scene so the new radius is applied. One sample retains the known within-frame variance-estimation limitation.

## Persistence and failure behavior

The instance-local file is `minecraft/config/metallum-raytracing.properties`, schema version 1. Without a file, existing launcher properties are honored and unspecified values use the declared defaults; hardware mode defaults to off. A saved user choice takes precedence over older launcher flags on subsequent starts.

Commands validate the complete new snapshot, write a temporary file, keep the previous file as `.bak`, and replace the target before applying runtime changes. The filesystem's atomic replacement is used where supported. A failed write or invalid value leaves the live settings unchanged. Unknown keys, unsupported schema versions, malformed numbers and files over 64 KiB are rejected. Invalid startup files are preserved with a logged warning; they are not silently rewritten. A later explicit save can repair the file, retaining its previous contents in the backup.

The store touches only its declared `metallum.rt.*` controls. It does not alter companion mods, vanilla options, launch arguments or the original Prisma instances. A renderer failure still retains raster rendering and is reported by status; these controls do not conceal that failure or claim the hardware pass recovered.

## Verification work

`diagnostics/RtSettingsProof.java` covers real disk round-trips, precedence, backups, presets, invalid values, invalid reloads and write failures. `diagnostics/RtClientControlsProof.java` exercises the actual registered Brigadier command tree, local feedback and rejection of unattended mutations. The build runs both proofs through `check`: 29 settings checks and 12 command-tree checks pass. See `persistent-controls-build.log`.

The new compile dependencies are exactly Fabric Command API v2 `3.1.0+00cb03469e` and API Base `2.0.4+ece063239e`, already included in the installed Fabric API. Official Maven JAR/POM hashes are pinned in dependency verification. All non-manifest entries match the installed modules; the command JAR's sole difference is ordering in a generated manifest entry. Provenance is recorded in `runs/client-api-provenance.json`. No replacement Fabric API has been installed.

## Live verification and rollback

The scoped development diagnostic executed the actual registered client command tree for status, balanced preset, two samples, GI strength 0.5, reload, hardware off and hardware on. Every command returned success. Off-mode status explicitly reported raster rendering. The balanced preset was restored before restarting. These checks use the real dispatcher and a local command source; keyboard entry and the chat UI were not independently tested.

After a clean close and relaunch, process 84804 reported hybrid mode, three samples, one bounce, AO/shadows 0.65, reflections/GI 1.0, dynamic temporal enabled, MetalFX off, an active hardware scene and a 1920×1200 framebuffer. Only the read-only status helper was used after restart. Evidence: `runs/client-controls-status-1789407777014.txt`; all command receipts are `runs/client-controls-*.txt`.

Use `/metalrt preset balanced` to restore the tested controls, or `/metalrt set mode off` for raster rendering. To restore the preceding saved configuration, close the development game and copy `metallum-raytracing.properties.bak` over `metallum-raytracing.properties` in its config directory. The backup represents the immediately previous save. Renderer rollback remains available through `tools/install_development_renderer.py --rollback-sha` from the workspace root. The prior native-equivalent renderer hash is `1aecee0f9817779e98bd33edb1bb79eee4bfd689f1629069f5c08075872c552a`.

The subsequent physical-lighting build adds persistence coverage for `physicalLighting`: 31 settings checks plus 12 command checks pass. The earlier 41-check result and native-equivalence statement describe the original controls build; the newer renderer has its own validation record.

The HDR display build adds negative/fractional exposure commands, toggle persistence and native display validation: 40 settings checks plus 14 command checks pass. Tone mapping off bypasses exposure too; neither control changes hybrid lighting. See [HDR display validation](HDR-DISPLAY-VALIDATION.md).
