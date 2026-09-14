// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "RtCore.h"
#include <vector>
#include <cstdio>
#include <cmath>
#include <cstring>
#define REQUIRE(x) do {if(!(x)){fprintf(stderr,"Chunk proof failed at line %d: %s (%s)\n",__LINE__,#x,ctx?rt_error(ctx):"no context");return 1;}}while(0)
static std::vector<RtVertex> quad(float x=0,float y=0,float z=0){return {{x-2,y-2,z},{x+2,y-2,z},{x+2,y+2,z},{x-2,y-2,z},{x+2,y+2,z},{x-2,y+2,z}};}
static RtMaterial material(bool mirror,uint32_t texel=0){RtMaterial m={};for(auto &v:m.tint)v=1;m.surface[0]=mirror?.001f:.85f;m.surface[1]=mirror?1:0;m.surface[2]=mirror?0:2;m.optics[0]=1.5;m.optics[2]=1;m.image[0]=texel;m.image[1]=m.image[2]=1;return m;}
int main(int argc,char **argv){@autoreleasepool{
 if(argc!=1&&(argc!=3||strcmp(argv[1],"--capture"))){fprintf(stderr,"usage: chunk-proof [--capture path.gputrace]\n");return 2;}
 auto device=MTLCreateSystemDefaultDevice();char error[4096];auto shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];
 RtContext *ctx=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));REQUIRE(ctx);
 auto capture=[MTLCaptureManager sharedCaptureManager];
 if(argc==3){auto descriptor=[MTLCaptureDescriptor new];descriptor.captureObject=device;descriptor.destination=MTLCaptureDestinationGPUTraceDocument;descriptor.outputURL=[NSURL fileURLWithPath:@(argv[2])];NSError *failure=nil;REQUIRE([capture startCaptureWithDescriptor:descriptor error:&failure]);}
 auto vertices=quad();std::vector<RtMaterial> mirror(2,material(true)),emitter(2,material(false));
 uint32_t white=0xffffffff,red=0xffff0000,green=0xff00ff00,blue=0xff0000ff;
 RtChunkMesh chunks[]={
  {11,{4,4,2,0},6,1,vertices.data(),mirror.data(),&white},
  {22,{4,4,6,0},6,1,vertices.data(),emitter.data(),&red},
  {33,{132,4,2,0},6,1,vertices.data(),emitter.data(),&blue}};
 REQUIRE(rt_build_chunks(ctx,chunks,3));RtChunkStatistics stats={};REQUIRE(rt_chunk_statistics(ctx,&stats));REQUIRE(stats.chunks==3&&stats.built==3&&stats.reused==0&&stats.triangles==6);
 RtRay rays[]={{{4,4,10,0},{0,0,-1,20}},{{132,4,4,0},{0,0,-1,20}},{{4,4,4,0},{0,0,-1,20}},{{4,4,4,0},{float(128/std::sqrt(16388.0)),0,float(-2/std::sqrt(16388.0)),256}}};RtHit hits[4]={};
 REQUIRE(rt_trace(ctx,rays,hits,4));REQUIRE(hits[0].hit&&std::abs(hits[0].distance-4)<1e-5&&hits[0].primitive>=2&&hits[0].primitive<4);REQUIRE(hits[1].hit&&std::abs(hits[1].distance-2)<1e-5&&hits[1].primitive>=4);REQUIRE(hits[2].hit&&hits[2].primitive<2);REQUIRE(hits[3].hit&&hits[3].primitive>=4&&std::abs(hits[3].distance-std::sqrt(16388.0))<.002);float farDistance=hits[3].distance;
 RtFrameParameters p={};p.camera[3]=256;p.sun[1]=1;p.sun[3]=.00465;p.controls[0]=2;p.controls[1]=.003;p.transport[0]=1;p.transport[2]=3.1415927;p.transport[3]=256;
 RtTransport reflected={};REQUIRE(rt_transport(ctx,&rays[2],&reflected,1,&p,16));REQUIRE(reflected.reflection[0]>1.9&&reflected.reflection[1]<.001&&reflected.reflection[2]<.001);
 // Cache is retained independently of the old renderer/context lifetime.
 auto cache=rt_acquire_chunk_cache(ctx);REQUIRE(cache);
 auto other=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));REQUIRE(other&&rt_seed_chunk_cache(other,cache));
 chunks[2].offset[0]=133;REQUIRE(rt_build_chunks(other,chunks,3));REQUIRE(!rt_inherit_history(other,ctx));
 chunks[2].offset[0]=132;REQUIRE(rt_build_chunks(other,chunks,3));REQUIRE(rt_inherit_history(other,ctx));rt_destroy(other);
 rt_destroy(ctx);ctx=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));REQUIRE(ctx&&rt_seed_chunk_cache(ctx,cache));rt_release_chunk_cache(cache);
 chunks[1].offset[2]=8;chunks[1].texels=&green;
 REQUIRE(rt_build_chunks(ctx,chunks,3));REQUIRE(rt_chunk_statistics(ctx,&stats));REQUIRE(stats.built==0&&stats.reused==3);
 REQUIRE(rt_trace(ctx,rays,hits,4));REQUIRE(std::abs(hits[0].distance-2)<1e-5);
 REQUIRE(rt_transport(ctx,&rays[2],&reflected,1,&p,16));REQUIRE(reflected.reflection[1]>1.9&&reflected.reflection[0]<.001);
 auto edited=vertices;for(auto &v:edited)v.z+=1;chunks[1].vertices=edited.data();
 REQUIRE(rt_build_chunks(ctx,chunks,3));REQUIRE(rt_chunk_statistics(ctx,&stats));REQUIRE(stats.built==1&&stats.reused==2);
 REQUIRE(rt_trace(ctx,rays,hits,4));REQUIRE(std::abs(hits[0].distance-1)<1e-5);
 auto epoch=rt_scene_epoch(ctx);chunks[1].offset[0]=NAN;REQUIRE(!rt_build_chunks(ctx,chunks,3));REQUIRE(rt_scene_epoch(ctx)==epoch);chunks[1].offset[0]=4;
 chunks[1].key=11;REQUIRE(!rt_build_chunks(ctx,chunks,3));REQUIRE(rt_scene_epoch(ctx)==epoch);chunks[1].key=22;
 REQUIRE(rt_trace(ctx,rays,hits,4));REQUIRE(std::abs(hits[0].distance-1)<1e-5);
 REQUIRE(rt_build_chunks(ctx,chunks,1));REQUIRE(rt_chunk_statistics(ctx,&stats));REQUIRE(stats.chunks==1&&stats.reused==1&&stats.built==0&&stats.removed==2);
 REQUIRE(rt_trace(ctx,rays,hits,4));REQUIRE(!hits[1].hit&&!hits[3].hit&&std::abs(hits[0].distance-8)<1e-5);
 REQUIRE(rt_build_chunks(ctx,nullptr,0));REQUIRE(rt_trace(ctx,rays,hits,4));for(auto h:hits)REQUIRE(!h.hit);
 REQUIRE(rt_chunk_statistics(ctx,&stats));REQUIRE(stats.chunks==0&&stats.triangles==0&&stats.removed==1);
 // Empty static scene plus a dynamic mirror and emitter exercises combined
 // attribute offsets, masked-placeholder handling and indirect AS residency.
 auto dynamic=quad(4,4,2),back=quad(4,4,6);dynamic.insert(dynamic.end(),back.begin(),back.end());
 std::vector<RtMaterial> materials={material(true),material(true),material(false,1),material(false,1)};uint32_t texels[]={white,red};
 REQUIRE(rt_set_dynamic_mesh(ctx,dynamic.data(),unsigned(dynamic.size()),materials.data(),texels,2));
 constexpr unsigned size=32;auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:size height:size mipmapped:NO];desc.storageMode=MTLStorageModePrivate;desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
 auto color=[device newTextureWithDescriptor:desc];desc.pixelFormat=MTLPixelFormatDepth32Float;auto depth=[device newTextureWithDescriptor:desc];auto queue=[device newCommandQueue];auto cb=[queue commandBuffer];auto fence=[device newFence];
 auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=color;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(.5,.5,.5,.5);pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=.5;
 auto clear=[cb renderCommandEncoderWithDescriptor:pass];[clear updateFence:fence afterStages:MTLRenderStageVertex|MTLRenderStageFragment];[clear endEncoding];
 p.inverse_view_projection[0]=p.inverse_view_projection[5]=4;p.inverse_view_projection[10]=-4;p.inverse_view_projection[15]=1;p.camera[0]=p.camera[1]=p.camera[2]=4;p.camera[3]=8;p.dimensions[0]=p.dimensions[1]=size/2;p.dimensions[2]=1;p.dimensions[3]=2;
 REQUIRE(rt_encode_frame(ctx,(__bridge void*)cb,(__bridge void*)color,(__bridge void*)depth,(__bridge void*)fence,&p));
 auto pixels=[device newBufferWithLength:size*size*4 options:MTLResourceStorageModeShared];auto blit=[cb blitCommandEncoder];[blit waitForFence:fence];[blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(size,size,1) toBuffer:pixels destinationOffset:0 destinationBytesPerRow:size*4 destinationBytesPerImage:size*size*4];[blit endEncoding];[cb commit];[cb waitUntilCompleted];REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
 REQUIRE(rt_trace_last_frame(ctx,rays,hits,4));REQUIRE(hits[2].hit&&hits[2].primitive<2&&std::abs(hits[2].distance-2)<1e-5);
 auto rgba=static_cast<uint8_t*>(pixels.contents)+(size/2*size+size/2)*4;REQUIRE(rgba[0]>240&&rgba[1]<10&&rgba[2]<10&&rgba[3]==128);
 if(argc==3)[capture stopCapture];
 printf("{\"passed\":true,\"initialChunks\":3,\"unchangedBlasReused\":3,\"editedBlasBuilt\":1,\"editedSceneBlasReused\":2,\"retainedCacheAfterContextDestruction\":true,\"changedTransformRejectsHistory\":true,\"farGeometryOffsetBlocks\":128,\"longRayHitDistanceBlocks\":%.6f,\"materialOnlyEditReusesGeometry\":true,\"invalidUpdatePreservesScene\":true,\"chunkRemoval\":true,\"emptyScene\":true,\"dynamicReflectionWithEmptyStaticScene\":true,\"dynamicCenterRGBA\":[%u,%u,%u,%u]}\n",farDistance,rgba[0],rgba[1],rgba[2],rgba[3]);
 rt_destroy(ctx);return 0;
}}
