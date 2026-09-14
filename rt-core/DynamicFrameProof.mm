// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "RtCore.h"
#include <vector>
#include <cstdio>
#include <cmath>
#include <cstring>
static void quad(std::vector<RtVertex>&v,RtVertex a,RtVertex b,RtVertex c,RtVertex d){for(auto p:{a,b,c,a,c,d})v.push_back(p);}
int main(){@autoreleasepool{
    constexpr unsigned size=64;auto device=MTLCreateSystemDefaultDevice();auto queue=[device newCommandQueue];auto fence=[device newFence];
    NSString *shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];char error[4096];
    auto ctx=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));if(!ctx){fprintf(stderr,"%s\n",error);return 1;}
    std::vector<RtVertex> floor,actor;
    quad(floor,{0,0,2},{8,0,2},{8,8,2},{0,8,2});
    quad(actor,{3,3,3},{5,3,3},{5,5,3},{3,5,3});
    if(!rt_build_triangles(ctx,floor.data(),unsigned(floor.size())))return 1;uint64_t staticEpoch=rt_scene_epoch(ctx);
    std::vector<RtMaterial> materials(actor.size()/3);
    for(auto &m:materials){for(auto &v:m.tint)v=1;m.surface[0]=.85;m.surface[2]=2;m.optics[0]=1.5;m.optics[2]=1;m.image[1]=m.image[2]=1;}
    uint32_t red=0xffff0000;
    auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:size height:size mipmapped:NO];desc.storageMode=MTLStorageModePrivate;desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    auto color=[device newTextureWithDescriptor:desc];desc.pixelFormat=MTLPixelFormatDepth32Float;auto depth=[device newTextureWithDescriptor:desc];
    auto readback=[device newBufferWithLength:size*size*4 options:MTLResourceStorageModeShared];
    RtFrameParameters p={};p.inverse_view_projection[0]=p.inverse_view_projection[5]=4;p.inverse_view_projection[10]=-4;p.inverse_view_projection[15]=1;
    p.camera[0]=p.camera[1]=p.camera[2]=4;p.camera[3]=8;p.sun[1]=.6;p.sun[2]=.8;p.sun[3]=.04;
    p.controls[0]=1.5;p.controls[1]=.003;p.transport[1]=1;p.transport[2]=3.1415927;p.transport[3]=16;p.dimensions[0]=p.dimensions[1]=size/2;p.dimensions[2]=25;p.dimensions[3]=2;
    auto render=[&](std::vector<uint8_t>&pixels){
        auto cb=[queue commandBuffer];cb.label=@"Independent dynamic BLAS and material-offset proof";
        auto pass=[MTLRenderPassDescriptor renderPassDescriptor];auto ca=pass.colorAttachments[0];ca.texture=color;ca.loadAction=MTLLoadActionClear;ca.storeAction=MTLStoreActionStore;ca.clearColor=MTLClearColorMake(.5,.5,.5,.5);
        pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=.5;
        auto clear=[cb renderCommandEncoderWithDescriptor:pass];[clear updateFence:fence afterStages:MTLRenderStageVertex|MTLRenderStageFragment];[clear endEncoding];
        if(!rt_encode_frame(ctx,(__bridge void*)cb,(__bridge void*)color,(__bridge void*)depth,(__bridge void*)fence,&p)){fprintf(stderr,"%s\n",rt_error(ctx));return false;}
        auto blit=[cb blitCommandEncoder];[blit waitForFence:fence];[blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(size,size,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:size*4 destinationBytesPerImage:size*size*4];[blit endEncoding];[cb commit];[cb waitUntilCompleted];
        if(cb.status!=MTLCommandBufferStatusCompleted){fprintf(stderr,"%s\n",cb.error.localizedDescription.UTF8String);return false;}
        pixels.resize(size*size*4);memcpy(pixels.data(),readback.contents,pixels.size());return true;
    };
    std::vector<uint8_t> before,first,moved,invalid,removed;
    if(!render(before)||!rt_set_dynamic_mesh(ctx,actor.data(),unsigned(actor.size()),materials.data(),&red,1)||!render(first))return 1;
    RtRay probes[]={{{4,4,4,0},{0,0,-1,8}},{{5.5,4,4,0},{0,0,-1,8}}};RtHit firstHits[2]={},movedHits[2]={};
    if(!rt_trace_last_frame(ctx,probes,firstHits,2))return 1;
    RtDynamicStatistics unchangedBefore={};rt_dynamic_statistics(ctx,&unchangedBefore);
    if(!rt_set_dynamic_mesh(ctx,actor.data(),unsigned(actor.size()),materials.data(),&red,1))return 1;
    RtDynamicStatistics unchangedAfter={};rt_dynamic_statistics(ctx,&unchangedAfter);
    for(auto &v:actor)v.x+=1.5;
    if(!rt_set_dynamic_mesh(ctx,actor.data(),unsigned(actor.size()),materials.data(),&red,1)||!render(moved))return 1;
    if(!rt_trace_last_frame(ctx,probes,movedHits,2))return 1;
    actor[0].x=NAN;bool invalidRejected=!rt_set_dynamic_mesh(ctx,actor.data(),unsigned(actor.size()),materials.data(),&red,1);
    if(!render(invalid)||!rt_set_dynamic_mesh(ctx,nullptr,0,nullptr,nullptr,0)||!render(removed))return 1;
    double total[2]={},moment[2]={};unsigned alphaErrors=0;
    for(auto *pixels:{&first,&moved}){
        unsigned index=pixels==&first?0:1;
        for(unsigned i=0;i<size*size;i++){double energy=std::max(0,int((*pixels)[i*4])-int((*pixels)[i*4+1]));total[index]+=energy;moment[index]+=energy*(i%size);if((*pixels)[i*4+3]!=128)alphaErrors++;}
    }
    RtDynamicStatistics stats={};rt_dynamic_statistics(ctx,&stats);
    bool preserved=invalid==moved,restored=before==removed,noStaticRebuild=rt_scene_epoch(ctx)==staticEpoch,unchangedSkipped=unchangedBefore.updates==unchangedAfter.updates&&!unchangedAfter.pending;
    double shift=total[0]>0&&total[1]>0?moment[1]/total[1]-moment[0]/total[0]:0;
    bool exactMovement=firstHits[0].hit&&firstHits[0].primitive>=2&&std::abs(firstHits[0].distance-1)<1e-5&&movedHits[0].hit&&movedHits[0].primitive<2&&std::abs(movedHits[0].distance-2)<1e-5&&movedHits[1].hit&&movedHits[1].primitive>=2&&std::abs(movedHits[1].distance-1)<1e-5;
    bool passed=invalidRejected&&preserved&&restored&&noStaticRebuild&&unchangedSkipped&&exactMovement&&!alphaErrors&&total[0]>1000&&total[1]>1000&&stats.updates==3&&stats.completed_frames==3&&stats.triangles==0;
    printf("{\"passed\":%s,\"redIndirectEnergy\":%.1f,\"movedRedEnergy\":%.1f,\"lightCentroidShiftPixels\":%.4f,\"staticBlasUnchanged\":%s,\"invalidUpdatePreservedDynamicScene\":%s,\"removalRestoredBaseline\":%s,\"unchangedMeshSkipped\":%s,\"dynamicUpdates\":%llu,\"completedDynamicFrames\":%llu,\"alphaErrors\":%u}\n",passed?"true":"false",total[0],total[1],shift,noStaticRebuild?"true":"false",preserved&&invalidRejected?"true":"false",restored?"true":"false",unchangedSkipped?"true":"false",(unsigned long long)stats.updates,(unsigned long long)stats.completed_frames,alphaErrors);
    fprintf(stderr,"Exact dynamic/static hit distance and primitive-offset checks: %s\n",exactMovement?"passed":"failed");
    rt_destroy(ctx);return passed?0:1;
}}
