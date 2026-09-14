// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "RtCore.h"
#include "MetalFxFrame.h"
#include <mutex>
#include <string>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <vector>
#include <memory>
#include <atomic>
#include <unordered_map>
#include <unordered_set>
#include <algorithm>
#import <simd/simd.h>
static_assert(sizeof(RtMaterial)==96);
static_assert(sizeof(RtAreaLight)==64);
static_assert(sizeof(RtLightReceiver)==32);
static_assert(sizeof(RtIrradiance)==16);
static_assert(sizeof(RtFrameParameters)==160);

struct RtTemporalParameters {
    RtFrameParameters current;
    float previous_view_projection[16];
    float previous_camera[4];
    uint32_t history[4]; // valid, max samples, full width, full height
    uint32_t dynamic[4]; // reactive interval, static triangles, changed this frame, reserved
};
static_assert(sizeof(RtTemporalParameters)==272);
struct RtHistory {
    id<MTLTexture> images[2][9]; // visibility, reflection, GI/count, normal/roughness, position/primitive, local direct, three sampling variances
    RtFrameParameters previous={};
    bool valid=false;
    unsigned index=0;
    unsigned dynamicFramesLeft=0;
    std::shared_ptr<MetalFxFrame> metalFx;
};
struct RtMetrics {
    std::atomic<uint64_t> encoded{0},completed{0},resets{0};
    std::atomic<double> last{0},total{0};
    std::atomic<uint64_t> fxEncoded{0},fxCompleted{0},fxResets{0};
    std::atomic<uint64_t> dynamicCompleted{0};
};
struct RtInstance {
    id<MTLAccelerationStructure> bottom;
    RtVertex offset={0,0,0};
    uint32_t primitiveOffset=0,mask=0xff;
};
struct RtChunkGeometry {id<MTLBuffer> vertices;id<MTLAccelerationStructure> bottom;};
using RtChunkMap=std::unordered_map<uint64_t,std::shared_ptr<RtChunkGeometry>>;
struct RtChunkCache {id<MTLDevice> device;std::shared_ptr<const RtChunkMap> geometry;};
static bool sameInstances(const std::vector<RtInstance>&a,const std::vector<RtInstance>&b){
    if(a.size()!=b.size())return false;
    for(size_t i=0;i<a.size();i++)if(memcmp(&a[i].offset,&b[i].offset,sizeof(RtVertex))||a[i].primitiveOffset!=b[i].primitiveOffset||a[i].mask!=b[i].mask)return false;
    return true;
}
static void useInstances(id<MTLComputeCommandEncoder> encoder,const std::vector<RtInstance>&instances){
    for(const auto &i:instances)[encoder useResource:i.bottom usage:MTLResourceUsageRead];
}
struct RtDynamicFrame {
    id<MTLAccelerationStructure> bottom,top;
    std::vector<RtInstance> instances;
    id<MTLBuffer> vertices,materials,texels,sourceMaterials;
    uint32_t triangles=0,texelOffset=0;
};
struct RtContext {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> pipeline;
    id<MTLComputePipelineState> visibilityPipeline;
    id<MTLLibrary> library;
    id<MTLComputePipelineState> framePipeline, transportPipeline, temporalPipeline, edgePipeline;
    id<MTLComputePipelineState> guidePipeline,localLightPipeline;
    id<MTLBuffer> areaLights,rawAreaLights,emptyLights;
    float lightSamplingOrigin[3]={};bool lightSamplingValid=false;
    uint32_t lightCount=0;
    uint64_t lightRevision=0;
    id<MTLRenderPipelineState> fxPresentPipeline;
    MTLPixelFormat fxPresentFormat=MTLPixelFormatInvalid;
    float fxView[16]={},fxProjection[16]={};
    bool fxCameraValid=false,fxActive=false;
    id<MTLRenderPipelineState> compositePipeline;
    MTLPixelFormat compositeFormat = MTLPixelFormatInvalid;
    bool compositeForFx=false;
    id<MTLTexture> frameVisibility, frameReflection, frameIndirect, frameBase, frameNormal, framePosition, frameMotion, frameReactive, edgeVisibility, edgeReflection, edgeIndirect, frameLocal, edgeLocal;
    id<MTLTexture> frameVariance[3];
    std::shared_ptr<RtHistory> history=std::make_shared<RtHistory>();
    std::shared_ptr<RtMetrics> metrics=std::make_shared<RtMetrics>();
    id<MTLAccelerationStructure> scene;
    std::vector<RtInstance> instances;
    std::shared_ptr<const RtChunkMap> chunkCache=std::make_shared<RtChunkMap>();
    RtChunkStatistics chunkStats={};
    id<MTLBuffer> dynamicVertices,dynamicMaterials,dynamicTexels;
    std::shared_ptr<RtDynamicFrame> dynamicFrame;
    bool dynamicDirty=false;
    uint64_t dynamicUpdates=0;
    id<MTLBuffer> vertices, materials, texels;
    uint32_t triangles=0;
    std::mutex lock;
    std::string error;
    uint64_t epoch = 0;
    double gpuMs = 0;
};
struct RtGeometryBindings {
    uint64_t vertices[2],materials[2],texels[2];
    uint32_t sizes[4];
};
static_assert(sizeof(RtGeometryBindings)==64);
struct RtGeometryFrame {
    id<MTLBuffer> table;
    id<MTLBuffer> resources[6];
};
static std::shared_ptr<RtGeometryFrame> geometryFrame(RtContext *c,const std::shared_ptr<RtDynamicFrame>&dynamic={}){
    auto frame=std::make_shared<RtGeometryFrame>();
    frame->resources[0]=c->vertices;frame->resources[2]=c->materials;frame->resources[4]=c->texels;
    frame->resources[1]=dynamic?dynamic->vertices:c->vertices;
    frame->resources[3]=dynamic?dynamic->materials:c->materials;
    frame->resources[5]=dynamic?dynamic->texels:c->texels;
    RtGeometryBindings bindings={};
    for(unsigned i=0;i<2;i++){
        bindings.vertices[i]=frame->resources[i].gpuAddress;
        bindings.materials[i]=frame->resources[i+2].gpuAddress;
        bindings.texels[i]=frame->resources[i+4].gpuAddress;
    }
    bindings.sizes[0]=c->triangles;bindings.sizes[1]=uint32_t(c->texels.length/4);
    frame->table=[c->device newBufferWithBytes:&bindings length:sizeof(bindings) options:MTLResourceStorageModeShared];
    frame->table.label=@"RT static and dynamic attribute addresses";
    return frame->table?frame:nullptr;
}
static void bindGeometry(id<MTLComputeCommandEncoder> encoder,unsigned index,const std::shared_ptr<RtGeometryFrame>&frame){
    [encoder setBuffer:frame->table offset:0 atIndex:index];
    for(const auto &resource:frame->resources)[encoder useResource:resource usage:MTLResourceUsageRead];
}
static bool fail(RtContext *c, const char *message) { c->error = message; return false; }
static id<MTLAccelerationStructure> encodeTop(RtContext *c,id<MTLCommandBuffer> cb,const std::vector<RtInstance>&refs,id<MTLFence> fence=nil){
    std::vector<MTLAccelerationStructureUserIDInstanceDescriptor> instances(refs.size());
    NSMutableArray<id<MTLAccelerationStructure>> *bottoms=[NSMutableArray arrayWithCapacity:refs.size()];
    for(unsigned i=0;i<instances.size();i++){
        const auto &ref=refs[i];[bottoms addObject:ref.bottom];
        auto &v=instances[i];v.transformationMatrix.columns[0].x=1;v.transformationMatrix.columns[1].y=1;v.transformationMatrix.columns[2].z=1;
        v.transformationMatrix.columns[3].x=ref.offset.x;v.transformationMatrix.columns[3].y=ref.offset.y;v.transformationMatrix.columns[3].z=ref.offset.z;
        v.options=MTLAccelerationStructureInstanceOptionOpaque;v.mask=ref.mask;v.accelerationStructureIndex=i;v.userID=ref.primitiveOffset;
    }
    auto buffer=[c->device newBufferWithBytes:instances.data() length:instances.size()*sizeof(instances[0]) options:MTLResourceStorageModeShared];
    auto desc=[MTLInstanceAccelerationStructureDescriptor descriptor];desc.instanceCount=instances.size();desc.instanceDescriptorBuffer=buffer;
    desc.instanceDescriptorStride=sizeof(instances[0]);desc.instanceDescriptorType=MTLAccelerationStructureInstanceDescriptorTypeUserID;desc.instancedAccelerationStructures=bottoms;
    auto sizes=[c->device accelerationStructureSizesWithDescriptor:desc];auto top=[c->device newAccelerationStructureWithSize:sizes.accelerationStructureSize];
    auto scratch=[c->device newBufferWithLength:sizes.buildScratchBufferSize options:MTLResourceStorageModePrivate];
    if(!buffer||!top||!scratch){fail(c,"Instance acceleration structure allocation failed");return nil;}
    auto encoder=[cb accelerationStructureCommandEncoder];if(!encoder){fail(c,"Instance acceleration structure encoder unavailable");return nil;}
    encoder.label=@"RT chunk/entity top-level instances";if(fence)[encoder waitForFence:fence];[encoder buildAccelerationStructure:top descriptor:desc scratchBuffer:scratch scratchBufferOffset:0];if(fence)[encoder updateFence:fence];[encoder endEncoding];
    return top;
}
static bool validRays(RtContext *c, const RtRay *rays, uint32_t count) {
    if (!rays || !count) return fail(c, "Empty ray batch");
    if (size_t(count)*sizeof(RtRay)>c->device.maxBufferLength) return fail(c, "Ray batch exceeds Metal buffer limit");
    for(uint32_t i=0;i<count;++i) {
        const auto &r=rays[i];
        for(int j=0;j<4;++j)
            if(!std::isfinite(r.origin[j]) || !std::isfinite(r.direction[j])) return fail(c,"Non-finite ray");
        float length2=r.direction[0]*r.direction[0]+r.direction[1]*r.direction[1]+r.direction[2]*r.direction[2];
        if(length2<1e-12f || r.origin[3]<0 || r.direction[3]<r.origin[3]) return fail(c,"Invalid ray interval or direction");
    }
    return true;
}
static bool validParameters(RtContext *c,const RtFrameParameters *p) {
    if(!p)return fail(c,"Missing frame parameters");
    for(float v:p->inverse_view_projection)if(!std::isfinite(v))return fail(c,"Non-finite camera matrix");
    for(const float *group:{p->camera,p->sun,p->controls,p->transport,p->display})for(int i=0;i<4;i++)if(!std::isfinite(group[i]))return fail(c,"Non-finite frame controls");
    float length=p->sun[0]*p->sun[0]+p->sun[1]*p->sun[1]+p->sun[2]*p->sun[2];
    if(std::abs(length-1)>1e-3||p->sun[3]<0||p->sun[3]>.5||p->controls[0]<0||p->controls[1]<=0)return fail(c,"Invalid light or ray controls");
    for(int i=2;i<4;i++)if(p->controls[i]<0||p->controls[i]>1)return fail(c,"Invalid visibility strength");
    for(int i=0;i<2;i++)if(p->transport[i]<0||p->transport[i]>1)return fail(c,"Invalid transport strength");
    if(p->transport[2]<0||p->transport[2]>100||p->transport[3]<0||p->transport[3]>4096||((p->transport[0]>0||p->transport[1]>0)&&p->transport[3]<=0))return fail(c,"Invalid transport light or distance");
    if(p->display[0]<-8||p->display[0]>8||(p->display[1]!=0&&p->display[1]!=1)||p->display[2]!=0||p->display[3]!=0)return fail(c,"Invalid display controls");
    if((p->dimensions[3]&~0x1ffffu)||((p->dimensions[3]>>8)&7u)>4||((p->dimensions[3]>>12)&7u)>4)return fail(c,"Invalid reconstruction or GI tier flags");
    return true;
}
static bool completed(RtContext *c, id<MTLCommandBuffer> cb) {
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted)
        return fail(c, cb.error.localizedDescription.UTF8String ?: "Metal command failed");
    c->gpuMs = (cb.GPUEndTime - cb.GPUStartTime) * 1000;
    return true;
}
RtContext *rt_create(void *device, const char *shader, char *error, size_t error_size) {
    @autoreleasepool {
        auto c = new RtContext();
        c->device = device ? (__bridge id<MTLDevice>)device : MTLCreateSystemDefaultDevice();
        if (!c->device || !c->device.supportsRaytracing) c->error = "Metal ray tracing unsupported";
        else if(c->device.argumentBuffersSupport!=MTLArgumentBuffersTier2)c->error="Metal Tier-2 argument buffers unsupported";
        else if (!shader) c->error = "Missing shader source";
        else {
            c->queue = [c->device newCommandQueue];
            c->queue.label = @"RT development queue";
            // Metal validates the declared element size even when the light count is
            // zero. A tiny triangle buffer is not a valid 80-byte SampledLight.
            c->emptyLights=[c->device newBufferWithLength:80 options:MTLResourceStorageModeShared];
            c->emptyLights.label=@"RT empty sampled-light binding";
            NSError *e = nil;
            MTLCompileOptions *options = [MTLCompileOptions new];
            options.languageVersion = MTLLanguageVersion3_1;
            id<MTLLibrary> library = [c->device newLibraryWithSource:@(shader) options:options error:&e];
            c->library = library;
            id<MTLFunction> function = [library newFunctionWithName:@"trace_triangles"];
            if (function) c->pipeline = [c->device newComputePipelineStateWithFunction:function error:&e];
            id<MTLFunction> visibility = [library newFunctionWithName:@"trace_visibility"];
            if (visibility) c->visibilityPipeline = [c->device newComputePipelineStateWithFunction:visibility error:&e];
            id<MTLFunction> frame = [library newFunctionWithName:@"frame_visibility"];
            if(frame)c->framePipeline = [c->device newComputePipelineStateWithFunction:frame error:&e];
            id<MTLFunction> edge=[library newFunctionWithName:@"refine_frame_edges"];
            if(edge)c->edgePipeline=[c->device newComputePipelineStateWithFunction:edge error:&e];
            id<MTLFunction> transport=[library newFunctionWithName:@"trace_transport"];
            if(transport)c->transportPipeline=[c->device newComputePipelineStateWithFunction:transport error:&e];
            id<MTLFunction> local=[library newFunctionWithName:@"trace_local_lighting"];
            if(local)c->localLightPipeline=[c->device newComputePipelineStateWithFunction:local error:&e];
            id<MTLFunction> temporal=[library newFunctionWithName:@"resolve_temporal"];
            if(temporal)c->temporalPipeline=[c->device newComputePipelineStateWithFunction:temporal error:&e];
            id<MTLFunction> guides=[library newFunctionWithName:@"metalfx_guides"];
            if(guides)c->guidePipeline=[c->device newComputePipelineStateWithFunction:guides error:&e];
            if (!c->emptyLights || !c->queue || !c->pipeline || !c->visibilityPipeline || !c->framePipeline || !c->transportPipeline || !c->temporalPipeline || !c->edgePipeline || !c->localLightPipeline) c->error = e.localizedDescription.UTF8String ?: "RT pipeline initialization failed";
        }
        if (!c->error.empty()) {
            if (error && error_size) snprintf(error, error_size, "%s", c->error.c_str());
            delete c; return nullptr;
        }
        if (error && error_size) error[0] = 0;
        return c;
    }
}
void rt_destroy(RtContext *c) { delete c; }
int rt_build_triangles(RtContext *c, const RtVertex *vertices, uint32_t count) {
    if (!c) return 0;
    std::lock_guard<std::mutex> guard(c->lock);
    @autoreleasepool {
        c->error.clear();
        if (!vertices || !count || count % 3) return fail(c, "Triangle vertices must be nonempty and divisible by three");
        size_t bytes = size_t(count) * sizeof(RtVertex);
        if (bytes > c->device.maxBufferLength) return fail(c, "Geometry exceeds Metal buffer limit");
        for (uint32_t i = 0; i < count; ++i)
            if (!std::isfinite(vertices[i].x) || !std::isfinite(vertices[i].y) || !std::isfinite(vertices[i].z))
                return fail(c, "Non-finite vertex");
        id<MTLBuffer> vb = [c->device newBufferWithBytes:vertices length:bytes options:MTLResourceStorageModeShared];
        if (!vb) return fail(c, "Vertex allocation failed");
        vb.label = @"RT immutable triangle vertices";
        auto geometry = [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
        geometry.vertexBuffer = vb;
        geometry.vertexFormat = MTLAttributeFormatFloat3;
        geometry.vertexStride = sizeof(RtVertex);
        geometry.triangleCount = count / 3;
        geometry.opaque = YES;
        auto desc = [MTLPrimitiveAccelerationStructureDescriptor descriptor];
        desc.geometryDescriptors = @[geometry];
        MTLAccelerationStructureSizes sizes = [c->device accelerationStructureSizesWithDescriptor:desc];
        id<MTLAccelerationStructure> scene = [c->device newAccelerationStructureWithSize:sizes.accelerationStructureSize];
        id<MTLBuffer> scratch = [c->device newBufferWithLength:sizes.buildScratchBufferSize options:MTLResourceStorageModePrivate];
        if (!scene || !scratch) return fail(c, "Acceleration structure allocation failed");
        scene.label = @"RT committed triangle scene";
        id<MTLCommandBuffer> cb = [c->queue commandBuffer];
        cb.label = @"RT build triangle acceleration structure";
        id<MTLAccelerationStructureCommandEncoder> encoder = [cb accelerationStructureCommandEncoder];
        if (!cb || !encoder) return fail(c, "Acceleration structure encoder unavailable");
        [encoder buildAccelerationStructure:scene descriptor:desc scratchBuffer:scratch scratchBufferOffset:0];
        [encoder endEncoding];
        std::vector<RtInstance> instances={{scene,{0,0,0},0,0xff}};
        auto top=encodeTop(c,cb,instances);if(!top)return 0;
        if (!completed(c, cb)) return 0;
        std::vector<RtMaterial> defaults(count/3);
        for(auto &m:defaults){m.tint[0]=m.tint[1]=m.tint[2]=m.tint[3]=1;m.surface[0]=1;m.optics[0]=1.5;m.optics[2]=1;m.image[1]=m.image[2]=1;}
        uint32_t white=0xffffffff;
        id<MTLBuffer> mb=[c->device newBufferWithBytes:defaults.data() length:defaults.size()*sizeof(RtMaterial) options:MTLResourceStorageModeShared];
        id<MTLBuffer> tb=[c->device newBufferWithBytes:&white length:4 options:MTLResourceStorageModeShared];
        if(!mb||!tb)return fail(c,"Default material allocation failed");
        c->vertices = vb; c->instances=std::move(instances);c->chunkCache=std::make_shared<RtChunkMap>();c->chunkStats={};c->scene = top;c->dynamicFrame.reset();c->dynamicDirty=c->dynamicVertices!=nil; c->materials=mb;c->texels=tb;c->triangles=count/3;if(c->history.use_count()>1)c->history=std::make_shared<RtHistory>();else c->history->valid=false; ++c->epoch;
        return 1;
    }
}
static bool validMaterials(RtContext *c,const RtMaterial *materials,uint32_t count,uint32_t texelCount){
        for(uint32_t i=0;i<count;i++) {
            const auto &m=materials[i];
            for(const float *v:{m.tint,m.surface,m.uv01,m.uv2,m.optics})for(int j=0;j<4;j++)if(!std::isfinite(v[j]))return fail(c,"Non-finite material");
            for(int j=0;j<4;j++)if(m.tint[j]<0||m.tint[j]>1)return fail(c,"Invalid material tint");
            if(m.surface[0]<.001||m.surface[0]>1||m.surface[1]<0||m.surface[1]>1||m.surface[2]<0||m.surface[2]>100||m.surface[3]<0||m.surface[3]>1||m.optics[0]<1||m.optics[0]>3||m.optics[1]<0||m.optics[1]>1||m.optics[2]<0||m.optics[2]>1||m.optics[3]<0||m.optics[3]>10)return fail(c,"Invalid material properties");
            if(!m.image[1]||!m.image[2]||uint64_t(m.image[0])+uint64_t(m.image[1])*m.image[2]>texelCount||(m.image[3]&~1u))return fail(c,"Material texel range invalid");
        }
    return true;
}
static_assert(sizeof(RtChunkMesh)==56);
static std::shared_ptr<RtChunkGeometry> buildChunkGeometry(RtContext *c,id<MTLCommandBuffer> cb,const RtVertex *vertices,uint32_t count){
    auto result=std::make_shared<RtChunkGeometry>();
    result->vertices=[c->device newBufferWithBytes:vertices length:size_t(count)*sizeof(RtVertex) options:MTLResourceStorageModeShared];
    if(!result->vertices){fail(c,"Chunk vertex allocation failed");return {};}
    auto geometry=[MTLAccelerationStructureTriangleGeometryDescriptor descriptor];geometry.vertexBuffer=result->vertices;
    geometry.vertexFormat=MTLAttributeFormatFloat3;geometry.vertexStride=sizeof(RtVertex);geometry.triangleCount=count/3;geometry.opaque=YES;
    auto desc=[MTLPrimitiveAccelerationStructureDescriptor descriptor];desc.geometryDescriptors=@[geometry];
    auto sizes=[c->device accelerationStructureSizesWithDescriptor:desc];result->bottom=[c->device newAccelerationStructureWithSize:sizes.accelerationStructureSize];
    auto scratch=[c->device newBufferWithLength:sizes.buildScratchBufferSize options:MTLResourceStorageModePrivate];
    if(!result->bottom||!scratch){fail(c,"Chunk acceleration structure allocation failed");return {};}
    auto encoder=[cb accelerationStructureCommandEncoder];if(!encoder){fail(c,"Chunk build encoder unavailable");return {};}
    encoder.label=@"RT changed chunk BLAS";[encoder buildAccelerationStructure:result->bottom descriptor:desc scratchBuffer:scratch scratchBufferOffset:0];[encoder endEncoding];return result;
}
RtChunkCache *rt_acquire_chunk_cache(RtContext *c){
    if(!c)return nullptr;std::lock_guard<std::mutex> guard(c->lock);
    auto cache=new RtChunkCache;cache->device=c->device;cache->geometry=c->chunkCache;return cache;
}
void rt_release_chunk_cache(RtChunkCache *cache){delete cache;}
int rt_seed_chunk_cache(RtContext *c,const RtChunkCache *cache){
    if(!c||!cache)return 0;std::lock_guard<std::mutex> guard(c->lock);
    if(c->scene)return fail(c,"Seed a new scene before its first build");
    if(c->device!=cache->device)return fail(c,"Chunk cache belongs to another Metal device");
    c->chunkCache=cache->geometry;return 1;
}
int rt_chunk_statistics(RtContext *c,RtChunkStatistics *statistics){
    if(!c||!statistics)return 0;std::lock_guard<std::mutex> guard(c->lock);*statistics=c->chunkStats;return 1;
}
int rt_build_chunks(RtContext *c,const RtChunkMesh *chunks,uint32_t count){
    if(!c)return 0;std::lock_guard<std::mutex> guard(c->lock);
    @autoreleasepool {
        c->error.clear();if(count>8192||(count&&!chunks))return fail(c,"Invalid chunk list");
        uint64_t vertices=0,texels=0;std::unordered_set<uint64_t> keys;
        for(uint32_t i=0;i<count;i++){
            const auto &chunk=chunks[i];
            if(!keys.insert(chunk.key).second)return fail(c,"Duplicate chunk key");
            if(!chunk.vertex_count||chunk.vertex_count%3||!chunk.texel_count||!chunk.vertices||!chunk.materials||!chunk.texels)return fail(c,"Incomplete chunk payload");
            for(float v:chunk.offset)if(!std::isfinite(v))return fail(c,"Non-finite chunk transform");
            if(chunk.offset[3]!=0)return fail(c,"Reserved chunk transform field must be zero");
            vertices+=chunk.vertex_count;texels+=chunk.texel_count;
            if(vertices>24000000||texels>64*1024*1024)return fail(c,"Chunk scene exceeds geometry or texture budget");
            for(uint32_t v=0;v<chunk.vertex_count;v++)if(!std::isfinite(chunk.vertices[v].x)||!std::isfinite(chunk.vertices[v].y)||!std::isfinite(chunk.vertices[v].z))return fail(c,"Non-finite chunk vertex");
            if(!validMaterials(c,chunk.materials,chunk.vertex_count/3,chunk.texel_count))return 0;
        }
        uint64_t vbytes=vertices*sizeof(RtVertex),mbytes=vertices/3*sizeof(RtMaterial),tbytes=texels*4;
        if(std::max({vbytes,mbytes,tbytes})>c->device.maxBufferLength)return fail(c,"Packed chunk attributes exceed Metal buffer limit");
        auto vb=[c->device newBufferWithLength:std::max<uint64_t>(vbytes,3*sizeof(RtVertex)) options:MTLResourceStorageModeShared];
        auto mb=[c->device newBufferWithLength:std::max<uint64_t>(mbytes,sizeof(RtMaterial)) options:MTLResourceStorageModeShared];
        auto tb=[c->device newBufferWithLength:std::max<uint64_t>(tbytes,4) options:MTLResourceStorageModeShared];
        if(!vb||!mb||!tb)return fail(c,"Packed chunk attribute allocation failed");
        auto next=std::make_shared<RtChunkMap>();std::vector<RtInstance> instances;RtChunkStatistics stats={};stats.chunks=count;stats.triangles=vertices/3;
        stats.packed_bytes=vb.length+mb.length+tb.length;
        auto cb=[c->queue commandBuffer];if(!cb)return fail(c,"Chunk build command buffer unavailable");cb.label=@"RT incremental chunk scene publication";
        size_t vertexBase=0,texelBase=0;
        for(uint32_t i=0;i<count;i++){
            const auto &chunk=chunks[i];size_t bytes=size_t(chunk.vertex_count)*sizeof(RtVertex);
            auto found=c->chunkCache->find(chunk.key);std::shared_ptr<RtChunkGeometry> geometry;
            if(found!=c->chunkCache->end()&&found->second->vertices.length==bytes&&memcmp(found->second->vertices.contents,chunk.vertices,bytes)==0){geometry=found->second;stats.reused++;}
            else{geometry=buildChunkGeometry(c,cb,chunk.vertices,chunk.vertex_count);if(!geometry)return 0;stats.built++;}
            next->emplace(chunk.key,geometry);stats.geometry_bytes+=geometry->vertices.length+geometry->bottom.size;
            memcpy(static_cast<RtVertex*>(vb.contents)+vertexBase,chunk.vertices,bytes);
            auto materials=static_cast<RtMaterial*>(mb.contents)+vertexBase/3;memcpy(materials,chunk.materials,size_t(chunk.vertex_count/3)*sizeof(RtMaterial));
            for(uint32_t m=0;m<chunk.vertex_count/3;m++)materials[m].image[0]+=uint32_t(texelBase);
            memcpy(static_cast<uint32_t*>(tb.contents)+texelBase,chunk.texels,size_t(chunk.texel_count)*4);
            instances.push_back({geometry->bottom,{chunk.offset[0],chunk.offset[1],chunk.offset[2]},uint32_t(vertexBase/3),0xff});
            vertexBase+=chunk.vertex_count;texelBase+=chunk.texel_count;
        }
        for(const auto &entry:*c->chunkCache)if(!keys.count(entry.first))stats.removed++;
        if(!count){
            // A masked degenerate placeholder makes an empty scene queryable and
            // keeps all shader resource bindings valid without inventing a hit.
            RtVertex empty[3]={};auto geometry=buildChunkGeometry(c,cb,empty,3);if(!geometry)return 0;
            instances.push_back({geometry->bottom,{0,0,0},0,0});
            memset(vb.contents,0,vb.length);memset(mb.contents,0,mb.length);*static_cast<uint32_t*>(tb.contents)=0xffffffff;
            stats.geometry_bytes=geometry->vertices.length+geometry->bottom.size;
        }
        auto top=encodeTop(c,cb,instances);if(!top||!completed(c,cb))return 0;
        c->vertices=vb;c->materials=mb;c->texels=tb;c->scene=top;c->instances=std::move(instances);c->triangles=uint32_t(vertices/3);
        c->chunkCache=next;c->chunkStats=stats;c->dynamicFrame.reset();c->dynamicDirty=c->dynamicVertices!=nil;
        if(c->history.use_count()>1)c->history=std::make_shared<RtHistory>();else c->history->valid=false;
        ++c->epoch;return 1;
    }
}
int rt_set_materials(RtContext *c,const RtMaterial *materials,uint32_t count,const uint32_t *texels,uint32_t texelCount) {
    if(!c)return 0;
    std::lock_guard<std::mutex> guard(c->lock);
    @autoreleasepool {
        c->error.clear();
        if(!c->scene||!materials||count!=c->triangles||!texels||!texelCount)return fail(c,"Material/geometry count mismatch or missing texels");
        if(size_t(count)*sizeof(RtMaterial)>c->device.maxBufferLength||size_t(texelCount)*4>c->device.maxBufferLength)return fail(c,"Materials exceed Metal buffer limit");
        if(!validMaterials(c,materials,count,texelCount))return 0;
        id<MTLBuffer> mb=[c->device newBufferWithBytes:materials length:size_t(count)*sizeof(RtMaterial) options:MTLResourceStorageModeShared];
        id<MTLBuffer> tb=[c->device newBufferWithBytes:texels length:size_t(texelCount)*4 options:MTLResourceStorageModeShared];
        if(!mb||!tb)return fail(c,"Material allocation failed");
        mb.label=@"RT triangle UV and surface materials";tb.label=@"RT immutable sprite texels ARGB8";
        c->materials=mb;c->texels=tb;c->dynamicDirty=c->dynamicVertices!=nil;c->dynamicFrame.reset();if(c->history.use_count()>1)c->history=std::make_shared<RtHistory>();else c->history->valid=false;++c->epoch;return 1;
    }
}
struct RtSampledLight {RtAreaLight light;float distribution[4];};
static_assert(sizeof(RtSampledLight)==80);
static id<MTLBuffer> sampledLights(id<MTLDevice> device,const RtAreaLight *lights,uint32_t count,const float *origin){
    std::vector<RtSampledLight> packed(count);std::vector<double> weights(count);double total=0;
    for(uint32_t i=0;i<count;i++){
        packed[i].light=lights[i];double weight=1;
        if(origin){const auto &l=lights[i];simd_float3 u={l.half_u[0],l.half_u[1],l.half_u[2]},v={l.half_v[0],l.half_v[1],l.half_v[2]};
            double area=4*simd_length(simd_cross(u,v)),d2=0;for(int j=0;j<3;j++){double delta=l.center[j]-origin[j];d2+=delta*delta;}
            double luminance=.2126*l.radiance[0]+.7152*l.radiance[1]+.0722*l.radiance[2];
            weight=area*luminance/std::max(d2,area);}
        weights[i]=weight;total+=weight;
    }
    double cumulative=0;float previous=0;
    for(uint32_t i=0;i<count;i++){
        // A ten-percent uniform mixture keeps every retained light reachable.
        double probability=total>0?.9*weights[i]/total+.1/count:1./count;cumulative+=probability;
        float endpoint=i+1==count?1.f:float(cumulative);
        packed[i].distribution[0]=endpoint;packed[i].distribution[1]=endpoint-previous;previous=endpoint;
    }
    auto buffer=[device newBufferWithBytes:packed.data() length:packed.size()*sizeof(packed[0]) options:MTLResourceStorageModeShared];
    buffer.label=@"RT area lights and importance distribution";return buffer;
}
static bool updateLightSampling(RtContext *c,const float *origin){
    float cell[3];for(int j=0;j<3;j++){
        if(!std::isfinite(origin[j])||std::abs(origin[j])>1000000)return fail(c,"Invalid light sampling origin");
        cell[j]=std::floor(origin[j]/4)*4+2;
    }
    if(!c->lightCount)return true;
    if(c->lightSamplingValid&&memcmp(cell,c->lightSamplingOrigin,sizeof(cell))==0)return true;
    auto buffer=sampledLights(c->device,(const RtAreaLight*)c->rawAreaLights.contents,c->lightCount,cell);
    if(!buffer)return fail(c,"Light sampling allocation failed");
    c->areaLights=buffer;memcpy(c->lightSamplingOrigin,cell,sizeof(cell));c->lightSamplingValid=true;return true;
}
int rt_set_light_sampling_origin(RtContext *c,const float *origin){
    if(!c||!origin)return 0;std::lock_guard<std::mutex> guard(c->lock);@autoreleasepool{c->error.clear();return updateLightSampling(c,origin);}
}
int rt_set_area_lights(RtContext *c,const RtAreaLight *lights,uint32_t count){
    if(!c)return 0;std::lock_guard<std::mutex> guard(c->lock);
    @autoreleasepool {
        c->error.clear();
        if(count>8192||(count&&!lights))return fail(c,"Invalid area-light count or missing lights");
        for(uint32_t i=0;i<count;i++){
            const auto &l=lights[i];
            for(const float *group:{l.center,l.half_u,l.half_v,l.radiance})for(int j=0;j<4;j++)
                if(!std::isfinite(group[j]))return fail(c,"Non-finite area light");
            if(l.center[3]!=0||l.half_u[3]!=0||l.radiance[3]!=0||(l.half_v[3]!=0&&l.half_v[3]!=1))return fail(c,"Invalid area-light flags");
            simd_float3 u={l.half_u[0],l.half_u[1],l.half_u[2]},v={l.half_v[0],l.half_v[1],l.half_v[2]};
            float lu=simd_length(u),lv=simd_length(v),area=4*simd_length(simd_cross(u,v));
            if(lu<.0001f||lv<.0001f||lu>64||lv>64||!std::isfinite(area)||area<.000001f||std::abs(simd_dot(u,v))>lu*lv*.0001f)
                return fail(c,"Area-light axes must be nondegenerate orthogonal half edges");
            for(int j=0;j<3;j++)if(std::abs(l.center[j])>1000000||l.radiance[j]<0||l.radiance[j]>100000)
                return fail(c,"Area-light position or radiance out of range");
        }
        if(count==c->lightCount&&(!count||memcmp(c->rawAreaLights.contents,lights,size_t(count)*sizeof(*lights))==0))return 1;
        id<MTLBuffer> buffer=nil;
        if(count){buffer=[c->device newBufferWithBytes:lights length:size_t(count)*sizeof(*lights) options:MTLResourceStorageModeShared];
            if(!buffer)return fail(c,"Area-light allocation failed");buffer.label=@"RT immutable finite area lights";}
        auto distribution=count?sampledLights(c->device,lights,count,nullptr):nil;
        if(count&&!distribution)return fail(c,"Light sampling allocation failed");
        c->rawAreaLights=buffer;c->areaLights=distribution;c->lightCount=count;c->lightRevision++;c->lightSamplingValid=false;
        if(c->history.use_count()>1)c->history=std::make_shared<RtHistory>();else c->history->valid=false;
        return 1;
    }
}
int rt_light_statistics(RtContext *c,RtLightStatistics *s){
    if(!c||!s)return 0;std::lock_guard<std::mutex> guard(c->lock);
    *s={c->lightCount,c->areaLights.length,c->lightRevision};return 1;
}
int rt_local_lighting(RtContext *c,const RtLightReceiver *receivers,RtIrradiance *values,uint32_t count,uint32_t samples,uint32_t seed,float bias){
    if(!c)return 0;std::lock_guard<std::mutex> guard(c->lock);
    @autoreleasepool {
        c->error.clear();
        if(!c->scene||!receivers||!values||!count||samples<1||samples>4096||!std::isfinite(bias)||bias<.000001f||bias>.1f)
            return fail(c,"Invalid local-lighting batch");
        if(size_t(count)*sizeof(*receivers)>c->device.maxBufferLength)return fail(c,"Local-lighting batch exceeds buffer limit");
        for(uint32_t i=0;i<count;i++){
            const auto &r=receivers[i];
            for(const float *group:{r.position,r.normal})for(int j=0;j<4;j++)if(!std::isfinite(group[j]))return fail(c,"Non-finite light receiver");
            for(int j=0;j<3;j++)if(std::abs(r.position[j])>1000000)return fail(c,"Light receiver position out of range");
            float n=r.normal[0]*r.normal[0]+r.normal[1]*r.normal[1]+r.normal[2]*r.normal[2];
            if(std::abs(n-1)>.001f||r.position[3]!=0||r.normal[3]!=0)return fail(c,"Invalid light receiver normal or reserved values");
        }
        if(!c->lightCount){memset(values,0,size_t(count)*sizeof(*values));return 1;}
        auto input=[c->device newBufferWithBytes:receivers length:size_t(count)*sizeof(*receivers) options:MTLResourceStorageModeShared];
        auto output=[c->device newBufferWithLength:size_t(count)*sizeof(*values) options:MTLResourceStorageModeShared];
        if(!input||!output)return fail(c,"Local-lighting allocation failed");
        auto cb=[c->queue commandBuffer];auto encoder=[cb computeCommandEncoder];if(!cb||!encoder)return fail(c,"Local-lighting encoder unavailable");
        cb.label=@"RT finite area-light hardware visibility";
        [encoder setComputePipelineState:c->localLightPipeline];[encoder setAccelerationStructure:c->scene atBufferIndex:0];useInstances(encoder,c->instances);
        auto geometry=geometryFrame(c);if(!geometry)return fail(c,"Attribute table allocation failed");bindGeometry(encoder,1,geometry);
        [encoder setBuffer:input offset:0 atIndex:2];[encoder setBuffer:output offset:0 atIndex:3];[encoder setBuffer:c->areaLights offset:0 atIndex:4];
        uint32_t settings[]={count,samples,seed,c->lightCount};[encoder setBytes:settings length:sizeof(settings) atIndex:5];[encoder setBytes:&bias length:4 atIndex:6];
        [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(c->localLightPipeline.threadExecutionWidth,1,1)];
        [encoder endEncoding];if(!completed(c,cb))return 0;memcpy(values,output.contents,size_t(count)*sizeof(*values));return 1;
    }
}
int rt_transport(RtContext *c,const RtRay *rays,RtTransport *values,uint32_t count,const RtFrameParameters *p,uint32_t samples) {
    if(!c)return 0;
    std::lock_guard<std::mutex> guard(c->lock);
    @autoreleasepool {
        c->error.clear();
        if(!c->scene||!values||!p||samples<1||samples>4096)return fail(c,"Invalid transport batch");
        if(!validRays(c,rays,count)||!validParameters(c,p))return 0;
        id<MTLBuffer> input=[c->device newBufferWithBytes:rays length:size_t(count)*sizeof(RtRay) options:MTLResourceStorageModeShared];
        id<MTLBuffer> output=[c->device newBufferWithLength:size_t(count)*sizeof(RtTransport) options:MTLResourceStorageModeShared];
        if(!input||!output)return fail(c,"Transport allocation failed");
        id<MTLCommandBuffer> cb=[c->queue commandBuffer];cb.label=@"RT material reflection and one-bounce GI proof";
        auto encoder=[cb computeCommandEncoder];
        if(!cb||!encoder)return fail(c,"Transport encoder unavailable");
        [encoder setComputePipelineState:c->transportPipeline];[encoder setAccelerationStructure:c->scene atBufferIndex:0];useInstances(encoder,c->instances);
        auto geometry=geometryFrame(c);if(!geometry)return fail(c,"Attribute table allocation failed");bindGeometry(encoder,1,geometry);
        [encoder setBuffer:input offset:0 atIndex:4];[encoder setBuffer:output offset:0 atIndex:5];
        [encoder setBytes:p length:sizeof(*p) atIndex:6];[encoder setBytes:&count length:4 atIndex:7];[encoder setBytes:&samples length:4 atIndex:8];
        [encoder setBuffer:c->areaLights?:c->emptyLights offset:0 atIndex:9];[encoder setBytes:&c->lightCount length:4 atIndex:10];
        [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(c->transportPipeline.threadExecutionWidth,1,1)];
        [encoder endEncoding];if(!completed(c,cb))return 0;
        memcpy(values,output.contents,size_t(count)*sizeof(RtTransport));return 1;
    }
}
static int traceScene(RtContext *c, const RtRay *rays, RtHit *hits, uint32_t count,bool lastFrame) {
    if (!c) return 0;
    std::lock_guard<std::mutex> guard(c->lock);
    @autoreleasepool {
        c->error.clear();
        if (!c->scene) return fail(c, "No committed scene");
        if (!rays || !hits || !count) return fail(c, "Empty ray batch");
        if (!validRays(c,rays,count)) return 0;
        id<MTLBuffer> input = [c->device newBufferWithBytes:rays length:count*sizeof(RtRay) options:MTLResourceStorageModeShared];
        id<MTLBuffer> output = [c->device newBufferWithLength:count*sizeof(RtHit) options:MTLResourceStorageModeShared];
        if (!input || !output) return fail(c, "Ray allocation failed");
        id<MTLCommandBuffer> cb = [c->queue commandBuffer];
        cb.label = @"RT hardware intersection correctness batch";
        id<MTLComputeCommandEncoder> encoder = [cb computeCommandEncoder];
        if (!cb || !encoder) return fail(c, "Compute encoder unavailable");
        encoder.label = @"trace_triangles — Metal intersector";
        [encoder setComputePipelineState:c->pipeline];
        auto frame=lastFrame?c->dynamicFrame:std::shared_ptr<RtDynamicFrame>{};
        [encoder setAccelerationStructure:frame?frame->top:c->scene atBufferIndex:0];useInstances(encoder,frame?frame->instances:c->instances);
        [encoder setBuffer:input offset:0 atIndex:1];
        [encoder setBuffer:output offset:0 atIndex:2];
        [encoder setBytes:&count length:sizeof(count) atIndex:3];
        [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(c->pipeline.threadExecutionWidth,1,1)];
        [encoder endEncoding];
        if (!completed(c, cb)) return 0;
        memcpy(hits, output.contents, count*sizeof(RtHit));
        return 1;
    }
}
int rt_trace(RtContext *c,const RtRay *rays,RtHit *hits,uint32_t count){return traceScene(c,rays,hits,count,false);}
int rt_trace_last_frame(RtContext *c,const RtRay *rays,RtHit *hits,uint32_t count){return traceScene(c,rays,hits,count,true);}
int rt_visibility(RtContext *c,const RtRay *rays,RtVisibility *values,uint32_t count,const RtVisibilitySettings *settings) {
    if(!c)return 0;
    std::lock_guard<std::mutex> guard(c->lock);
    @autoreleasepool {
        c->error.clear();
        if(!c->scene || !values || !settings)return fail(c,"Missing scene, settings or output");
        if(!validRays(c,rays,count))return 0;
        float directionLength=0;
        for(int i=0;i<4;i++)if(!std::isfinite(settings->sun_direction[i]))return fail(c,"Non-finite light direction");
        for(int i=0;i<3;i++)directionLength+=settings->sun_direction[i]*settings->sun_direction[i];
        if(std::abs(directionLength-1)>1e-3f || settings->sun_direction[3]<0 || settings->sun_direction[3]>.5f ||
           !std::isfinite(settings->ao_distance) || settings->ao_distance<=0 || !std::isfinite(settings->ray_bias) || settings->ray_bias<=0 ||
           settings->samples<1 || settings->samples>256)return fail(c,"Invalid visibility settings");
        id<MTLBuffer> input=[c->device newBufferWithBytes:rays length:count*sizeof(RtRay) options:MTLResourceStorageModeShared];
        id<MTLBuffer> output=[c->device newBufferWithLength:count*sizeof(RtVisibility) options:MTLResourceStorageModeShared];
        if(!input || !output)return fail(c,"Visibility allocation failed");
        id<MTLCommandBuffer> cb=[c->queue commandBuffer];cb.label=@"RT soft sun shadows and ambient occlusion";
        id<MTLComputeCommandEncoder> encoder=[cb computeCommandEncoder];
        if(!cb || !encoder)return fail(c,"Visibility encoder unavailable");
        encoder.label=@"trace_visibility — finite sun disk and hemisphere rays";
        [encoder setComputePipelineState:c->visibilityPipeline];
        [encoder setAccelerationStructure:c->scene atBufferIndex:0];useInstances(encoder,c->instances);
        [encoder setBuffer:input offset:0 atIndex:1];[encoder setBuffer:output offset:0 atIndex:2];
        [encoder setBytes:&count length:sizeof(count) atIndex:3];
        [encoder setBytes:settings length:sizeof(*settings) atIndex:4];
        auto geometry=geometryFrame(c);if(!geometry)return fail(c,"Attribute table allocation failed");bindGeometry(encoder,5,geometry);
        [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(c->visibilityPipeline.threadExecutionWidth,1,1)];
        [encoder endEncoding];if(!completed(c,cb))return 0;
        memcpy(values,output.contents,count*sizeof(RtVisibility));return 1;
    }
}
static bool sameBuffer(id<MTLBuffer> a,id<MTLBuffer> b){return a&&b&&a.length==b.length&&memcmp(a.contents,b.contents,a.length)==0;}
int rt_set_dynamic_mesh(RtContext *c,const RtVertex *vertices,uint32_t count,const RtMaterial *materials,const uint32_t *texels,uint32_t texelCount){
    if(!c)return 0;std::lock_guard<std::mutex> guard(c->lock);c->error.clear();
    if(!c->scene)return fail(c,"Dynamic mesh needs a static scene");
    if(!count){if(c->dynamicVertices){c->dynamicVertices=nil;c->dynamicMaterials=nil;c->dynamicTexels=nil;c->dynamicDirty=true;}return 1;}
    if(!vertices||count%3||count>300000||!materials||!texels||!texelCount||texelCount>16*1024*1024)return fail(c,"Dynamic mesh exceeds budget or has incomplete input");
    for(uint32_t i=0;i<count;i++)if(!std::isfinite(vertices[i].x)||!std::isfinite(vertices[i].y)||!std::isfinite(vertices[i].z))return fail(c,"Non-finite dynamic vertex");
    if(!validMaterials(c,materials,count/3,texelCount))return 0;
    auto matches=[](id<MTLBuffer> b,const void *data,size_t bytes){return b&&b.length==bytes&&memcmp(b.contents,data,bytes)==0;};
    bool sameVertices=matches(c->dynamicVertices,vertices,size_t(count)*sizeof(RtVertex));
    bool sameMaterials=matches(c->dynamicMaterials,materials,size_t(count/3)*sizeof(RtMaterial));
    bool sameTexels=matches(c->dynamicTexels,texels,size_t(texelCount)*4);
    if(sameVertices&&sameMaterials&&sameTexels)return 1;
    auto vb=sameVertices?c->dynamicVertices:[c->device newBufferWithBytes:vertices length:size_t(count)*sizeof(RtVertex) options:MTLResourceStorageModeShared];
    auto mb=sameMaterials?c->dynamicMaterials:[c->device newBufferWithBytes:materials length:size_t(count/3)*sizeof(RtMaterial) options:MTLResourceStorageModeShared];
    auto tb=sameTexels?c->dynamicTexels:[c->device newBufferWithBytes:texels length:size_t(texelCount)*4 options:MTLResourceStorageModeShared];
    if(!vb||!mb||!tb)return fail(c,"Dynamic staging allocation failed");
    c->dynamicVertices=vb;c->dynamicMaterials=mb;c->dynamicTexels=tb;c->dynamicDirty=true;return 1;
}
int rt_dynamic_statistics(RtContext *c,RtDynamicStatistics *s){
    if(!c||!s)return 0;std::lock_guard<std::mutex> guard(c->lock);
    s->triangles=c->dynamicFrame?c->dynamicFrame->triangles:0;s->updates=c->dynamicUpdates;s->pending=c->dynamicDirty;s->completed_frames=c->metrics->dynamicCompleted.load();return 1;
}
int rt_attribute_statistics(RtContext *c,RtAttributeStatistics *s){
    if(!c||!s)return 0;std::lock_guard<std::mutex> guard(c->lock);*s={};
    id<MTLBuffer> base[]={c->vertices,c->materials,c->texels};
    auto dynamic=c->dynamicFrame;
    id<MTLBuffer> posed[]={dynamic?dynamic->vertices:nil,dynamic?dynamic->materials:nil,dynamic?dynamic->texels:nil};
    for(unsigned i=0;i<3;i++){s->static_bytes+=base[i].length;s->dynamic_bytes+=posed[i].length;s->static_addresses[i]=base[i].gpuAddress;s->dynamic_addresses[i]=posed[i].gpuAddress;}
    return 1;
}
static bool encodeDynamic(RtContext *c,id<MTLCommandBuffer> cb,id<MTLFence> fence){
    if(!c->dynamicDirty)return true;
    if(!c->dynamicVertices){c->dynamicFrame.reset();c->dynamicDirty=false;c->dynamicUpdates++;return true;}
    auto frame=std::make_shared<RtDynamicFrame>();frame->instances=c->instances;
    frame->triangles=uint32_t(c->dynamicVertices.length/sizeof(RtVertex)/3);
    frame->sourceMaterials=c->dynamicMaterials;frame->texelOffset=uint32_t(c->texels.length/4);
    if(c->dynamicFrame&&c->dynamicFrame->sourceMaterials==c->dynamicMaterials&&c->dynamicFrame->texelOffset==frame->texelOffset)frame->materials=c->dynamicFrame->materials;
    else {
        auto adjusted=std::vector<RtMaterial>(frame->triangles);memcpy(adjusted.data(),c->dynamicMaterials.contents,c->dynamicMaterials.length);
        for(auto &m:adjusted)m.image[0]+=frame->texelOffset;
        frame->materials=[c->device newBufferWithBytes:adjusted.data() length:c->dynamicMaterials.length options:MTLResourceStorageModeShared];
    }
    if(!frame->materials)return fail(c,"Dynamic material allocation failed");
    frame->vertices=c->dynamicVertices;frame->texels=c->dynamicTexels;
    auto geometry=[MTLAccelerationStructureTriangleGeometryDescriptor descriptor];geometry.vertexBuffer=c->dynamicVertices;geometry.vertexFormat=MTLAttributeFormatFloat3;geometry.vertexStride=sizeof(RtVertex);geometry.triangleCount=frame->triangles;geometry.opaque=YES;
    auto desc=[MTLPrimitiveAccelerationStructureDescriptor descriptor];desc.geometryDescriptors=@[geometry];
    auto sizes=[c->device accelerationStructureSizesWithDescriptor:desc];frame->bottom=[c->device newAccelerationStructureWithSize:sizes.accelerationStructureSize];
    auto scratch=[c->device newBufferWithLength:sizes.buildScratchBufferSize options:MTLResourceStorageModePrivate];
    if(!frame->bottom||!scratch)return fail(c,"Dynamic acceleration structure allocation failed");
    auto build=[cb accelerationStructureCommandEncoder];if(!build)return fail(c,"Dynamic acceleration structure encoder unavailable");
    build.label=@"RT posed entity BLAS";[build waitForFence:fence];[build buildAccelerationStructure:frame->bottom descriptor:desc scratchBuffer:scratch scratchBufferOffset:0];[build updateFence:fence];[build endEncoding];
    frame->instances.push_back({frame->bottom,{0,0,0},c->triangles,0xff});
    frame->top=encodeTop(c,cb,frame->instances,fence);if(!frame->top)return false;
    c->dynamicFrame=frame;c->dynamicDirty=false;c->dynamicUpdates++;return true;
}
int rt_inherit_history(RtContext *destination,RtContext *source) {
    if(!destination||!source||destination==source)return 0;
    std::scoped_lock guard(destination->lock,source->lock);
    if(destination->lightCount!=source->lightCount||(destination->lightCount&&!sameBuffer(destination->rawAreaLights,source->rawAreaLights)))return 0;
    if(destination->device!=source->device||!sameBuffer(destination->vertices,source->vertices)||!sameBuffer(destination->materials,source->materials)||!sameBuffer(destination->texels,source->texels)||!sameInstances(destination->instances,source->instances))return 0;
    destination->history=source->history;destination->metrics=source->metrics;
    destination->dynamicVertices=source->dynamicVertices;destination->dynamicMaterials=source->dynamicMaterials;destination->dynamicTexels=source->dynamicTexels;
    destination->dynamicFrame=source->dynamicFrame;destination->dynamicDirty=source->dynamicDirty;destination->dynamicUpdates=source->dynamicUpdates;return 1;
}
int rt_frame_statistics(RtContext *c,RtFrameStatistics *statistics) {
    if(!c||!statistics)return 0;
    std::lock_guard<std::mutex> guard(c->lock);auto metrics=c->metrics;
    statistics->encoded_frames=metrics->encoded.load();statistics->completed_frames=metrics->completed.load();statistics->history_resets=metrics->resets.load();
    statistics->last_command_gpu_ms=metrics->last.load();statistics->mean_command_gpu_ms=statistics->completed_frames?metrics->total.load()/statistics->completed_frames:0;
    return 1;
}
int rt_set_metalfx_camera(RtContext *c,const float *worldToView,const float *viewToClip){
    if(!c)return 0;std::lock_guard<std::mutex> guard(c->lock);
    if(!worldToView||!viewToClip)return fail(c,"Missing MetalFX camera matrices");
    for(const float *values:{worldToView,viewToClip}){
        for(int i=0;i<16;i++)if(!std::isfinite(values[i]))return fail(c,"Non-finite MetalFX camera matrix");
        simd_float4x4 matrix;memcpy(&matrix,values,64);
        if(std::abs(simd_determinant(matrix))<1e-10)return fail(c,"Singular MetalFX camera matrix");
    }
    memcpy(c->fxView,worldToView,64);memcpy(c->fxProjection,viewToClip,64);c->fxCameraValid=true;return 1;
}
int rt_metalfx_statistics(RtContext *c,RtMetalFxStatistics *s){
    if(!c||!s)return 0;std::lock_guard<std::mutex> guard(c->lock);
    s->supported=[MTLFXTemporalDenoisedScalerDescriptor supportsDevice:c->device];s->active=c->fxActive;
    s->encoded_frames=c->metrics->fxEncoded.load();s->completed_frames=c->metrics->fxCompleted.load();s->history_resets=c->metrics->fxResets.load();return 1;
}
const char *rt_error(RtContext *c) { return c ? c->error.c_str() : "No RT context"; }
uint64_t rt_scene_epoch(RtContext *c) { return c ? c->epoch : 0; }
double rt_last_gpu_ms(RtContext *c) { return c ? c->gpuMs : 0; }

int rt_encode_frame(RtContext *c,void *commandBuffer,void *colorTexture,void *depthTexture,void *globalFence,const RtFrameParameters *p) {
    if(!c)return 0;
    std::lock_guard<std::mutex> guard(c->lock);
    @autoreleasepool {
        c->error.clear();
        id<MTLCommandBuffer> cb=(__bridge id<MTLCommandBuffer>)commandBuffer;
        id<MTLTexture> color=(__bridge id<MTLTexture>)colorTexture,depth=(__bridge id<MTLTexture>)depthTexture;
        id<MTLFence> fence=(__bridge id<MTLFence>)globalFence;
        if(!c->scene||!c->framePipeline||!cb||!color||!depth||!fence||!p)return fail(c,"Live frame dependencies unavailable");
        if(!validParameters(c,p))return 0;
        RtFrameParameters effective=*p;
        bool useFx=(p->dimensions[3]&16u)&&[MTLFXTemporalDenoisedScalerDescriptor supportsDevice:c->device];
        if(!useFx)effective.dimensions[3]&=~16u;
        p=&effective;c->fxActive=useFx;
        if(useFx&&(!c->fxCameraValid||!c->guidePipeline))return fail(c,"MetalFX camera or guide pipeline unavailable");
        if(color.width!=depth.width||color.height!=depth.height)return fail(c,"Color/depth dimensions mismatch");
        if(p->dimensions[0]!=(color.width+1)/2||p->dimensions[1]!=(color.height+1)/2)return fail(c,"Live frame dimensions mismatch");
        bool dynamicChanged=c->dynamicDirty;
        if(!encodeDynamic(c,cb,fence))return 0;
        bool dynamicTemporal=(p->dimensions[3]&128u)!=0;
        if(dynamicChanged){
            c->history->dynamicFramesLeft=32;
            if(!dynamicTemporal)c->history->valid=false;
        }
        auto frameBundle=c->dynamicFrame;
        id<MTLAccelerationStructure> sceneAS=frameBundle?frameBundle->top:c->scene;
        const auto &sceneInstances=frameBundle?frameBundle->instances:c->instances;
        if(!updateLightSampling(c,p->camera))return 0;
        id<MTLBuffer> retainedLights=c->areaLights?:c->emptyLights;uint32_t lightCount=c->lightCount;
        auto attributes=geometryFrame(c,frameBundle);if(!attributes)return fail(c,"Attribute table allocation failed");
        if(!c->frameVisibility||c->frameVisibility.width!=p->dimensions[0]||c->frameVisibility.height!=p->dimensions[1]) {
            auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:p->dimensions[0] height:p->dimensions[1] mipmapped:NO];
            desc.storageMode=MTLStorageModePrivate;desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
            c->frameVisibility=[c->device newTextureWithDescriptor:desc];c->frameVisibility.label=@"RT live AO and sun visibility";
            // Radiance can exceed half-float range for smooth specular emitters.
            c->frameReflection=[c->device newTextureWithDescriptor:desc];c->frameReflection.label=@"RT rough material reflection";
            c->frameIndirect=[c->device newTextureWithDescriptor:desc];c->frameIndirect.label=@"RT one-bounce diffuse radiance";
            c->frameLocal=[c->device newTextureWithDescriptor:desc];c->frameLocal.label=@"RT finite local-light direct radiance";
            desc.pixelFormat=MTLPixelFormatRGBA16Float;
            c->frameNormal=[c->device newTextureWithDescriptor:desc];c->frameNormal.label=@"RT primary normal and roughness";
            c->frameMotion=[c->device newTextureWithDescriptor:desc];c->frameMotion.label=@"RT static-scene camera motion and temporal validity";
            desc.pixelFormat=MTLPixelFormatR16Float;
            c->frameReactive=[c->device newTextureWithDescriptor:desc];c->frameReactive.label=@"RT per-pixel temporal rejection for MetalFX";
            desc.pixelFormat=MTLPixelFormatRGBA32Float;
            c->framePosition=[c->device newTextureWithDescriptor:desc];c->framePosition.label=@"RT primary scene position and primitive";
            for(unsigned k=0;k<3;k++){c->frameVariance[k]=[c->device newTextureWithDescriptor:desc];c->frameVariance[k].label=@"RT radiance sample-mean variance";if(!c->frameVariance[k])return fail(c,"Sampling variance allocation failed");}
        }
        if(!c->edgeVisibility||c->edgeVisibility.width!=color.width||c->edgeVisibility.height!=color.height){
            auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:color.width height:color.height mipmapped:NO];
            desc.storageMode=MTLStorageModePrivate;desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
            c->edgeVisibility=[c->device newTextureWithDescriptor:desc];c->edgeVisibility.label=@"RT full-resolution edge coverage";
            desc.pixelFormat=MTLPixelFormatRGBA32Float;c->edgeReflection=[c->device newTextureWithDescriptor:desc];c->edgeIndirect=[c->device newTextureWithDescriptor:desc];c->edgeLocal=[c->device newTextureWithDescriptor:desc];
            if(!c->edgeVisibility||!c->edgeReflection||!c->edgeIndirect||!c->edgeLocal)return fail(c,"Edge refinement allocation failed");
        }
        auto h=c->history;
        if(useFx&&(!h->metalFx||h->metalFx->color.width!=color.width||h->metalFx->color.height!=color.height)){
            auto fx=MetalFxFrame::create(c->device,color.width,color.height,c->error);if(!fx)return 0;
            h->metalFx=fx;h->valid=false;
        }
        if(!h->images[0][0]||h->images[0][0].width!=p->dimensions[0]||h->images[0][0].height!=p->dimensions[1]){
            auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:p->dimensions[0] height:p->dimensions[1] mipmapped:NO];
            desc.storageMode=MTLStorageModePrivate;desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
            for(int index=0;index<2;index++)for(int kind=0;kind<9;kind++){
                desc.pixelFormat=kind==3?MTLPixelFormatRGBA16Float:MTLPixelFormatRGBA32Float;
                h->images[index][kind]=[c->device newTextureWithDescriptor:desc];h->images[index][kind].label=@"RT temporal history";
                if(!h->images[index][kind])return fail(c,"Temporal history allocation failed");
            }
            h->valid=false;
        }
        RtTemporalParameters temporal={};temporal.current=*p;temporal.history[1]=32;temporal.history[2]=uint32_t(color.width);temporal.history[3]=uint32_t(color.height);
        temporal.dynamic[0]=dynamicTemporal&&h->dynamicFramesLeft>0;temporal.dynamic[1]=c->triangles;temporal.dynamic[2]=dynamicChanged;
        if(h->dynamicFramesLeft)h->dynamicFramesLeft--;
        bool valid=h->valid&&p->dimensions[3]==h->previous.dimensions[3]&&(useFx||(!(p->dimensions[3]&2u)&&!(h->previous.dimensions[3]&2u)))&&p->dimensions[2]==h->previous.dimensions[2]+1;
        if(valid){
            for(int i=0;i<3;i++)if(std::abs(p->camera[i]-h->previous.camera[i])>2||std::abs(p->sun[i]-h->previous.sun[i])>.005f)valid=false;
            if(memcmp(p->controls,h->previous.controls,sizeof(p->controls))||memcmp(p->transport,h->previous.transport,sizeof(p->transport)))valid=false;
        }
        temporal.history[0]=valid;memcpy(temporal.previous_camera,h->previous.camera,16);
        if(valid){simd_float4x4 inverse;memcpy(&inverse,h->previous.inverse_view_projection,64);auto projection=simd_inverse(inverse);memcpy(temporal.previous_view_projection,&projection,64);}
        if(!valid)c->metrics->resets++;
        unsigned previous=h->index,next=1-previous;
        if(!c->frameBase||c->frameBase.width!=color.width||c->frameBase.height!=color.height||c->frameBase.pixelFormat!=color.pixelFormat){
            auto base=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:color.pixelFormat width:color.width height:color.height mipmapped:NO];
            base.storageMode=MTLStorageModePrivate;base.usage=MTLTextureUsageShaderRead;
            c->frameBase=[c->device newTextureWithDescriptor:base];c->frameBase.label=@"RT raster color snapshot for linear light composition";
        }
        id<MTLTexture> compositeTarget=useFx?h->metalFx->color:color;
        if(!c->compositePipeline||c->compositeFormat!=compositeTarget.pixelFormat||c->compositeForFx!=useFx) {
            auto desc=[MTLRenderPipelineDescriptor new];
            desc.vertexFunction=[c->library newFunctionWithName:@"visibility_vertex"];
            desc.fragmentFunction=[c->library newFunctionWithName:@"visibility_composite"];
            desc.colorAttachments[0].pixelFormat=compositeTarget.pixelFormat;
            desc.colorAttachments[0].blendingEnabled=YES;
            desc.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorOne;
            desc.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorZero;
            desc.colorAttachments[0].sourceAlphaBlendFactor=useFx?MTLBlendFactorOne:MTLBlendFactorZero;
            desc.colorAttachments[0].destinationAlphaBlendFactor=useFx?MTLBlendFactorZero:MTLBlendFactorOne;
            NSError *error=nil;c->compositePipeline=[c->device newRenderPipelineStateWithDescriptor:desc error:&error];
            if(!c->compositePipeline)return fail(c,error.localizedDescription.UTF8String?:"Composite pipeline failed");
            c->compositeFormat=compositeTarget.pixelFormat;
            c->compositeForFx=useFx;
        }
        if(!c->frameVisibility||!c->frameReflection||!c->frameIndirect||!c->frameBase||!c->frameNormal||!c->framePosition||!c->frameMotion||!c->frameReactive||!c->frameLocal)return fail(c,"Visibility texture allocation failed");
        auto copy=[cb blitCommandEncoder];if(!copy)return fail(c,"Raster color copy encoder unavailable");
        copy.label=@"RT preserve raster color";[copy waitForFence:fence];[copy copyFromTexture:color toTexture:c->frameBase];[copy updateFence:fence];[copy endEncoding];
        id<MTLComputeCommandEncoder> compute=[cb computeCommandEncoder];
        if(!compute)return fail(c,"Live compute encoder unavailable");
        compute.label=@"RT live visibility";[compute waitForFence:fence];
        [compute setComputePipelineState:c->framePipeline];[compute setAccelerationStructure:sceneAS atBufferIndex:0];useInstances(compute,sceneInstances);
        bindGeometry(compute,1,attributes);[compute setBytes:p length:sizeof(*p) atIndex:2];
        [compute setBuffer:retainedLights offset:0 atIndex:3];[compute setBytes:&lightCount length:4 atIndex:4];

        [compute setTexture:depth atIndex:0];[compute setTexture:c->frameVisibility atIndex:1];
        [compute setTexture:c->frameReflection atIndex:2];[compute setTexture:c->frameIndirect atIndex:3];
        [compute setTexture:c->frameNormal atIndex:4];[compute setTexture:c->framePosition atIndex:5];[compute setTexture:c->frameLocal atIndex:6];
        for(unsigned k=0;k<3;k++)[compute setTexture:c->frameVariance[k] atIndex:7+k];
        [compute dispatchThreads:MTLSizeMake(p->dimensions[0],p->dimensions[1],1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
        [compute updateFence:fence];[compute endEncoding];
        // In MetalFX mode this pass supplies validation/innovation history only.
        // MetalFX still receives the raw current lighting, avoiding double filtering.
        if(!useFx||dynamicTemporal){
        auto resolve=[cb computeCommandEncoder];if(!resolve)return fail(c,"Temporal encoder unavailable");
        resolve.label=@"RT temporal reprojection and surface rejection";[resolve waitForFence:fence];[resolve setComputePipelineState:c->temporalPipeline];
        [resolve setBytes:&temporal length:sizeof(temporal) atIndex:0];
        id<MTLTexture> raw[]={c->frameVisibility,c->frameReflection,c->frameIndirect,c->frameNormal,c->framePosition};
        for(int kind=0;kind<5;kind++){[resolve setTexture:raw[kind] atIndex:kind];[resolve setTexture:h->images[previous][kind] atIndex:kind+5];[resolve setTexture:h->images[next][kind] atIndex:kind+10];}
        [resolve setTexture:c->frameMotion atIndex:15];[resolve setTexture:c->frameReactive atIndex:28];
        [resolve setTexture:c->frameLocal atIndex:16];[resolve setTexture:h->images[previous][5] atIndex:17];[resolve setTexture:h->images[next][5] atIndex:18];
        for(unsigned k=0;k<3;k++){[resolve setTexture:c->frameVariance[k] atIndex:19+k];[resolve setTexture:h->images[previous][6+k] atIndex:22+k];[resolve setTexture:h->images[next][6+k] atIndex:25+k];}
        [resolve dispatchThreads:MTLSizeMake(p->dimensions[0],p->dimensions[1],1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
        [resolve updateFence:fence];[resolve endEncoding];
        }
        auto edge=[cb computeCommandEncoder];if(!edge)return fail(c,"Edge encoder unavailable");
        edge.label=@"RT full-resolution depth-edge repair";[edge waitForFence:fence];[edge setComputePipelineState:c->edgePipeline];
        [edge setAccelerationStructure:sceneAS atBufferIndex:0];useInstances(edge,sceneInstances);bindGeometry(edge,1,attributes);[edge setBytes:p length:sizeof(*p) atIndex:2];
        [edge setBuffer:retainedLights offset:0 atIndex:3];[edge setBytes:&lightCount length:4 atIndex:4];

        [edge setTexture:depth atIndex:0];[edge setTexture:c->edgeVisibility atIndex:1];[edge setTexture:c->edgeReflection atIndex:2];[edge setTexture:c->edgeIndirect atIndex:3];[edge setTexture:c->edgeLocal atIndex:4];
        [edge dispatchThreads:MTLSizeMake(color.width,color.height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[edge updateFence:fence];[edge endEncoding];
        auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=compositeTarget;
        pass.colorAttachments[0].loadAction=useFx?MTLLoadActionDontCare:MTLLoadActionLoad;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLRenderCommandEncoder> render=[cb renderCommandEncoderWithDescriptor:pass];
        if(!render)return fail(c,"Live composite encoder unavailable");
        render.label=@"RT visibility composite before hand and HUD";
        [render waitForFence:fence beforeStages:MTLRenderStageFragment];
        [render setRenderPipelineState:c->compositePipeline];
        [render setViewport:(MTLViewport){0,0,double(color.width),double(color.height),0,1}];
        [render setFragmentTexture:useFx?c->frameVisibility:h->images[next][0] atIndex:0];[render setFragmentTexture:depth atIndex:1];
        [render setFragmentTexture:useFx?c->frameReflection:h->images[next][1] atIndex:2];[render setFragmentTexture:useFx?c->frameIndirect:h->images[next][2] atIndex:3];
        [render setFragmentTexture:c->frameBase atIndex:4];
        [render setFragmentTexture:c->edgeVisibility atIndex:5];[render setFragmentTexture:c->edgeReflection atIndex:6];[render setFragmentTexture:c->edgeIndirect atIndex:7];
        [render setFragmentTexture:useFx?c->frameLocal:h->images[next][5] atIndex:8];[render setFragmentTexture:c->edgeLocal atIndex:9];
        [render setFragmentBytes:p length:sizeof(*p) atIndex:0];
        [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [render updateFence:fence afterStages:MTLRenderStageFragment];[render endEncoding];
        if(useFx){
            auto fx=h->metalFx;
            auto guides=[cb computeCommandEncoder];if(!guides)return fail(c,"MetalFX guide encoder unavailable");
            guides.label=@"MetalFX full-resolution material and motion guides";[guides waitForFence:fence];[guides setComputePipelineState:c->guidePipeline];
            [guides setAccelerationStructure:sceneAS atBufferIndex:0];useInstances(guides,sceneInstances);bindGeometry(guides,1,attributes);[guides setBytes:&temporal length:sizeof(temporal) atIndex:2];

            simd_float4x4 inverse;memcpy(&inverse,p->inverse_view_projection,64);auto vp=simd_inverse(inverse);[guides setBytes:&vp length:64 atIndex:5];
            id<MTLTexture> textures[]={depth,fx->depth,fx->motion,fx->diffuse,fx->specular,fx->normal,fx->roughness,fx->mask,fx->reactive,c->frameReactive};
            for(unsigned i=0;i<10;i++)[guides setTexture:textures[i] atIndex:i];
            [guides dispatchThreads:MTLSizeMake(color.width,color.height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[guides updateFence:fence];[guides endEncoding];
            bool reset=!valid||!fx->valid;if(reset)c->metrics->fxResets++;
            fx->encode(cb,fence,c->fxView,c->fxProjection,reset);c->metrics->fxEncoded++;
            if(!c->fxPresentPipeline||c->fxPresentFormat!=color.pixelFormat){
                auto desc=[MTLRenderPipelineDescriptor new];desc.vertexFunction=[c->library newFunctionWithName:@"visibility_vertex"];desc.fragmentFunction=[c->library newFunctionWithName:@"metalfx_present"];
                auto attachment=desc.colorAttachments[0];attachment.pixelFormat=color.pixelFormat;attachment.blendingEnabled=YES;
                attachment.sourceRGBBlendFactor=MTLBlendFactorOne;attachment.destinationRGBBlendFactor=MTLBlendFactorZero;
                attachment.sourceAlphaBlendFactor=MTLBlendFactorZero;attachment.destinationAlphaBlendFactor=MTLBlendFactorOne;
                NSError *error=nil;c->fxPresentPipeline=[c->device newRenderPipelineStateWithDescriptor:desc error:&error];
                if(!c->fxPresentPipeline)return fail(c,error.localizedDescription.UTF8String?:"MetalFX presentation pipeline failed");c->fxPresentFormat=color.pixelFormat;
            }
            pass.colorAttachments[0].texture=color;pass.colorAttachments[0].loadAction=MTLLoadActionLoad;
            auto present=[cb renderCommandEncoderWithDescriptor:pass];if(!present)return fail(c,"MetalFX presentation encoder unavailable");
            present.label=@"MetalFX denoised lighting before hand and HUD";[present waitForFence:fence beforeStages:MTLRenderStageFragment];[present setRenderPipelineState:c->fxPresentPipeline];
            [present setViewport:(MTLViewport){0,0,double(color.width),double(color.height),0,1}];
            [present setFragmentTexture:fx->output atIndex:0];[present setFragmentTexture:fx->color atIndex:1];[present setFragmentTexture:fx->mask atIndex:2];[present setFragmentTexture:c->frameBase atIndex:3];
            for(unsigned k=0;k<3;k++)[present setFragmentTexture:h->images[next][6+k] atIndex:4+k];
            [present setFragmentBytes:p length:sizeof(*p) atIndex:0];[present setFragmentBytes:&temporal.dynamic[0] length:4 atIndex:1];
            [present drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[present updateFence:fence afterStages:MTLRenderStageFragment];[present endEncoding];
        }else if(h->metalFx)h->metalFx->valid=false;
        h->index=next;h->previous=*p;h->valid=true;
        auto metrics=c->metrics;metrics->encoded++;
        // Keep the reusable framework object alive even if a block edit destroys
        // this scene while its last frame is still executing on the GPU.
        auto retainedFx=useFx?h->metalFx:std::shared_ptr<MetalFxFrame>{};
        [cb addCompletedHandler:^(id<MTLCommandBuffer> buffer){
            if(buffer.status==MTLCommandBufferStatusCompleted){double ms=(buffer.GPUEndTime-buffer.GPUStartTime)*1000;metrics->last.store(ms);metrics->total.fetch_add(ms);metrics->completed++;}
            if(retainedFx&&buffer.status==MTLCommandBufferStatusCompleted)metrics->fxCompleted++;
            if(frameBundle&&buffer.status==MTLCommandBufferStatusCompleted)metrics->dynamicCompleted++;
            (void)retainedLights; // Immutable per-frame light payload survives scene replacement.
            (void)attributes; // Retain the table and all indirect buffers through GPU completion.
        }];
        return 1;
    }
}
