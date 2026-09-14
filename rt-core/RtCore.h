// SPDX-License-Identifier: MIT
#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct RtContext RtContext;
typedef struct RtChunkCache RtChunkCache;
typedef struct { float x, y, z; } RtVertex;
// 96-byte triangle material ABI. Texels are ARGB8 sRGB; tint is linear RGB.
typedef struct {
    float tint[4];
    float surface[4]; // roughness, metallic, emission radiance multiplier, transmission
    float uv01[4];
    float uv2[4];
    float optics[4]; // IOR, alpha cutoff, specular scale, absorption density per block
    uint32_t image[4]; // texel offset, width, height, flags (bit 0: alpha tested)
} RtMaterial;
typedef struct {
    float reflection[4]; // RGB reflected/refracted radiance, specular energy removed from base
    float indirect[4]; // RGB one-bounce outgoing radiance, primary hit marker
} RtTransport;
// origin.w is minimum distance; direction.w is maximum distance.
typedef struct { float origin[4]; float direction[4]; } RtRay;
typedef struct { float distance; uint32_t primitive; uint32_t hit; float reserved; } RtHit;
typedef struct {
    float sun_direction[4]; // xyz unit direction toward sun; w angular disk radius in radians
    float ao_distance, ray_bias;
    uint32_t samples, seed;
} RtVisibilitySettings;
typedef struct { float ambient_visibility, sun_visibility, depth, hit; } RtVisibility;
// Scene-relative rectangular emitter. Axes are half-edge vectors; cross(U,V)
// is the emitting normal. Reserved w values must be zero except half_v.w (0/1 two-sided).
typedef struct { float center[4],half_u[4],half_v[4],radiance[4]; } RtAreaLight;
typedef struct { float position[4],normal[4]; } RtLightReceiver;
typedef struct { float rgb[3],reserved; } RtIrradiance;
typedef struct { uint64_t count,bytes,revision; } RtLightStatistics;
// Immutable publication, maximum 8192 lights. Empty removes all lights. Failed
// validation/allocation leaves the prior lights and temporal history intact.
int rt_set_area_lights(RtContext *context,const RtAreaLight *lights,uint32_t count);
int rt_light_statistics(RtContext *context,RtLightStatistics *statistics);
// Sampling distribution only; does not change emitted energy or invalidate history.
int rt_set_light_sampling_origin(RtContext *context,const float origin[3]);
// Synchronous validation API. Returns incident irradiance, before receiver BRDF.
// Receiver normals must be unit length, w reserved zero. Scene must be built.
int rt_local_lighting(RtContext *context,const RtLightReceiver *receivers,RtIrradiance *output,
                      uint32_t count,uint32_t samples,uint32_t seed,float bias);
typedef struct {
    float inverse_view_projection[16];
    float camera[4]; // scene-relative camera xyz; scene side in blocks
    float sun[4]; // unit direction and angular radius
    float controls[4]; // AO distance, ray bias, AO strength, shadow strength
    uint32_t dimensions[4]; // half width/height, seed, flags: 0 linear raster, 1 no custom temporal, 2 no transmitted GI, 3 no edges, 4 MetalFX, 5 no surface replacement, 6 full MetalFX samples, 7 reactive dynamic temporal, 8..10 bounce count (0=1), 11 full-height horizontal coverage, 12..14 ray samples (0=automatic, 1..4 override), 15 physical surface lighting, 16 disable direct specular sampling
    float transport[4]; // reflection strength, GI strength, sun irradiance, max ray distance
    float display[4]; // exposure EV (-8..8), tone mapping enabled (0/1), reserved zero, reserved zero
} RtFrameParameters;
// device is an optional borrowed id<MTLDevice>. Context retains it.
RtContext *rt_create(void *device, const char *shader, char *error, size_t error_size);
void rt_destroy(RtContext *context);
// Synchronous prototype API. A failed build preserves the previous committed scene.
int rt_build_triangles(RtContext *context, const RtVertex *vertices, uint32_t vertex_count);
// Complete immutable chunk-scene publication. Geometry is chunk-local; offset
// places it in the current scene coordinates. Materials/texels are local per chunk.
// Keys must be unique. Zero chunks publishes an empty, non-intersecting scene.
typedef struct {
    uint64_t key;
    float offset[4];
    uint32_t vertex_count,texel_count;
    const RtVertex *vertices;
    const RtMaterial *materials;
    const uint32_t *texels;
} RtChunkMesh;
typedef struct {uint64_t chunks,triangles,built,reused,removed,geometry_bytes,packed_bytes;} RtChunkStatistics;
int rt_build_chunks(RtContext *context,const RtChunkMesh *chunks,uint32_t count);
int rt_chunk_statistics(RtContext *context,RtChunkStatistics *statistics);
// O(1) retained immutable cache snapshot; survives destruction of the old scene.
RtChunkCache *rt_acquire_chunk_cache(RtContext *context);
int rt_seed_chunk_cache(RtContext *context,const RtChunkCache *cache);
void rt_release_chunk_cache(RtChunkCache *cache);
// Material count must match the current geometry. A failed update preserves old materials.
int rt_set_materials(RtContext *context, const RtMaterial *materials, uint32_t count, const uint32_t *texels, uint32_t texel_count);
// Stage an independently animated triangle mesh. Applied on the next encoded
// frame without a CPU/GPU wait; zero vertices removes it. Texture offsets are local.
int rt_set_dynamic_mesh(RtContext *context,const RtVertex *vertices,uint32_t vertex_count,const RtMaterial *materials,const uint32_t *texels,uint32_t texel_count);
typedef struct { uint64_t triangles,updates,pending,completed_frames; } RtDynamicStatistics;
int rt_dynamic_statistics(RtContext *context,RtDynamicStatistics *statistics);
// Last encoded dynamic attributes and currently committed static attributes; addresses are diagnostic only.
typedef struct { uint64_t static_bytes,dynamic_bytes,static_addresses[3],dynamic_addresses[3]; } RtAttributeStatistics;
int rt_attribute_statistics(RtContext *context,RtAttributeStatistics *statistics);
int rt_transport(RtContext *context, const RtRay *rays, RtTransport *output, uint32_t count, const RtFrameParameters *parameters, uint32_t samples);
int rt_trace(RtContext *context, const RtRay *rays, RtHit *hits, uint32_t count);
// Diagnostic only: caller must complete the last encoded frame before querying
// its combined scene from this synchronous, separate command queue.
int rt_trace_last_frame(RtContext *context,const RtRay *rays,RtHit *hits,uint32_t count);
int rt_visibility(RtContext *context, const RtRay *rays, RtVisibility *output, uint32_t count, const RtVisibilitySettings *settings);
// Encodes into the caller's open command buffer after all other encoders have ended.
// Does not submit or wait. Resource dependencies join the renderer's existing fence.
int rt_encode_frame(RtContext *context, void *command_buffer, void *color, void *depth, void *fence, const RtFrameParameters *parameters);
// Optional MetalFX mode (frame flag bit 4). Scene-relative world-to-view and the
// actual raster projection, column-major. Both must be finite and invertible.
int rt_set_metalfx_camera(RtContext *context,const float *world_to_view,const float *view_to_clip);
typedef struct { uint64_t supported, active, encoded_frames, completed_frames, history_resets; } RtMetalFxStatistics;
int rt_metalfx_statistics(RtContext *context,RtMetalFxStatistics *statistics);
// Transfer temporal state only when the complete immutable scene/material payload matches.
// Call on the render thread between frames; both contexts must use the same device/queue ordering.
int rt_inherit_history(RtContext *destination, RtContext *source);
typedef struct { uint64_t encoded_frames, completed_frames, history_resets; double last_command_gpu_ms, mean_command_gpu_ms; } RtFrameStatistics;
int rt_frame_statistics(RtContext *context, RtFrameStatistics *statistics);
const char *rt_error(RtContext *context);
uint64_t rt_scene_epoch(RtContext *context);
double rt_last_gpu_ms(RtContext *context);
#ifdef __cplusplus
}
#endif
