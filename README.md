# Prisma

Native Apple Silicon Metal rendering engine and voxel shader framework for Minecraft.

Prisma replaces the legacy rendering path on macOS with direct, native Apple Metal pipelines (MSL). It brings modern real-time lighting and reflection effects to Apple Silicon Macs running Minecraft with Sodium, maintaining 60+ FPS on base M-series chips.

---

## Core Features

- **VPLS (Voxel Point Light Shadows)**: Dynamic point light shadows with contact-hardening penumbra raymarched through a 3D voxel grid. Works with handheld lights (torches, lanterns) and placed light sources. True RGB color reproduction per light type.
- **VXR (Voxel & Screen-Space Reflections)**: Real-time reflections on water and reflective surfaces using hybrid Hi-Z screen-space raymarching with voxel-grid fallback for off-screen geometry.
- **WaterWaves**: Trochoidal water wave animation with slope-based lighting perturbation and physical Fresnel response.
- **VXAO (Voxel Ambient Occlusion)**: High-performance contact ambient occlusion generated from the local 3D voxel grid volume.
- **Native Metal Pipeline**: Custom MSL shaders, Reverse-Z floating-point depth buffer, and asynchronous double-buffered voxel generation.
- **Sodium Integration**: Configurable directly from the Sodium video settings menu under the VXE Effects tab.

---

## Requirements

- **OS**: macOS 13 (Ventura) or newer
- **Hardware**: Apple Silicon Mac (M1, M2, M3, M4 family)
- **Minecraft**: 26.2
- **Loader**: Fabric Loader 0.19+
- **Mods**: Sodium, Fabric API

---

## Installation

1. Install Fabric Loader for Minecraft 26.2.
2. Put Fabric API and Sodium into your `.minecraft/mods` folder.
3. Download the latest `prisma-x.x.x.jar` release and place it into `.minecraft/mods`.
4. Launch the game using your Fabric profile.

Settings can be customized in Options -> Video Settings -> VXE Effects.

---

## Source & Distribution

Prisma is currently closed source until version 1.0.0. Pre-compiled binaries and release builds are distributed via GitHub Releases. The project will transition to an open-source license upon reaching the 1.0.0 milestone.

---

## Credits

Built on top of Metallum by kokodio. Powered by Fabric and Sodium.

