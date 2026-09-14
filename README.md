# Prisma

Native Apple Silicon Metal voxel shader engine for Minecraft and Sodium.

Prisma renders real-time lighting, voxel shadows, and reflections directly through native Apple Metal pipelines (MSL), delivering 60+ FPS on base M-series Macs without the overhead of OpenGL compatibility layers.

## Features

- **VPLS**: Dynamic point light shadows with soft contact penumbra for held and placed light sources.
- **VXR**: Real-time 3D voxel ray-traced reflections on water and glossy surfaces sampling real block textures directly from the Minecraft texture atlas (pure voxel ray tracing, no SSR).
- **Voxel Texture Atlas**: Full per-block UV mapping from Minecraft's block atlas into the GPU voxel grid for high-fidelity reflections and shading.
- **WaterWaves**: Trochoidal wave animation with physical slope lighting and Fresnel reflection.
- **VXAO**: Dithered contact ambient occlusion computed from the local 3D voxel grid.
- **Native Metal Engine**: Pure MSL compute and render pipelines with Reverse-Z floating-point depth.
- **Sodium UI**: Fully configurable under Video Settings -> VXE Effects.

## Requirements

- **OS**: macOS 13 (Ventura) or newer
- **Hardware**: Apple Silicon Mac (M1, M2, M3, M4)
- **Minecraft**: 26.2
- **Dependencies**: Fabric Loader 0.19+, Fabric API, Sodium

## Installation

1. Install Fabric Loader, Fabric API, and Sodium.
2. Drop `prisma-x.x.x.jar` into your `.minecraft/mods` folder.
3. Launch Minecraft and tune effects in Video Settings -> VXE Effects.

## Availability

Prisma is closed source until version 1.0.0. Pre-compiled binaries are published on Modrinth and GitHub Releases. The project will transition to an open-source license upon reaching version 1.0.0.

## Credits

Built on top of Metallum by kokodio. Powered by Fabric and Sodium.

