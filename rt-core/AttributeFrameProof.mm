// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "RtCore.h"
#include <vector>
#include <cstdio>
#include <cstring>
#include <algorithm>
static void quad(std::vector<RtVertex>&v,RtVertex a,RtVertex b,RtVertex c,RtVertex d){for(auto p:{a,b,c,a,c,d})v.push_back(p);}
int main(int argc,char **argv){@autoreleasepool{
    constexpr unsigned size=64;
    auto device=MTLCreateSystemDefaultDevice();if(!device)return 1;auto queue=[device newCommandQueue];auto fence=[device newFence];
    auto manager=[MTLCaptureManager sharedCaptureManager];bool capture=argc==3&&strcmp(argv[1],"--capture")==0;
    if(capture){auto request=[MTLCaptureDescriptor new];request.captureObject=device;request.destination=MTLCaptureDestinationGPUTraceDocument;request.outputURL=[NSURL fileURLWithPath:@(argv[2])];NSError *error=nil;if(![manager startCaptureWithDescriptor:request error:&error]){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 1;}}
    NSString *shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];char error[4096];
    fprintf(stderr,"attribute proof: creating context\n");
    auto ctx=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));if(!ctx){fprintf(stderr,"%s\n",error);return 1;}
    std::vector<RtVertex> floor,actor;quad(floor,{0,0,2},{8,0,2},{8,8,2},{0,8,2});quad(actor,{3,3,3},{5,3,3},{5,5,3},{3,5,3});
    if(!rt_build_triangles(ctx,floor.data(),unsigned(floor.size())))return 1;
    std::vector<RtMaterial> materials(actor.size()/3);for(auto &m:materials){for(auto &v:m.tint)v=1;m.surface[0]=.85;m.surface[2]=2;m.optics[0]=1.5;m.optics[2]=1;m.image[1]=m.image[2]=1;}
    auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:size height:size mipmapped:NO];desc.storageMode=MTLStorageModePrivate;desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    auto color=[device newTextureWithDescriptor:desc];desc.pixelFormat=MTLPixelFormatDepth32Float;auto depth=[device newTextureWithDescriptor:desc];
    RtFrameParameters p={};p.inverse_view_projection[0]=p.inverse_view_projection[5]=4;p.inverse_view_projection[10]=-4;p.inverse_view_projection[15]=1;
    p.camera[0]=p.camera[1]=p.camera[2]=4;p.camera[3]=8;p.sun[1]=.6;p.sun[2]=.8;p.sun[3]=.04;
    p.controls[0]=1.5;p.controls[1]=.003;p.transport[1]=1;p.transport[2]=3.1415927;p.transport[3]=16;p.dimensions[0]=p.dimensions[1]=size/2;p.dimensions[2]=25;p.dimensions[3]=2;
    id<MTLCommandBuffer> buffers[3];id<MTLBuffer> readbacks[3];RtAttributeStatistics stats[3]={};
    const uint32_t colors[]={0xffff0000,0xff00ff00,0xff0000ff};
    for(unsigned frame=0;frame<3;frame++){
        fprintf(stderr,"attribute proof: encoding frame %u\n",frame);
        if(frame)for(auto &v:actor)v.x+=.4f;
        if(!rt_set_dynamic_mesh(ctx,actor.data(),unsigned(actor.size()),materials.data(),&colors[frame],1))return 1;
        auto cb=[queue commandBuffer];cb.label=@"Retained separate attributes: queued RGB entity frames";buffers[frame]=cb;
        auto pass=[MTLRenderPassDescriptor renderPassDescriptor];auto ca=pass.colorAttachments[0];ca.texture=color;ca.loadAction=MTLLoadActionClear;ca.storeAction=MTLStoreActionStore;ca.clearColor=MTLClearColorMake(.5,.5,.5,.5);
        pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=.5;
        auto clear=[cb renderCommandEncoderWithDescriptor:pass];[clear updateFence:fence afterStages:MTLRenderStageVertex|MTLRenderStageFragment];[clear endEncoding];
        if(!rt_encode_frame(ctx,(__bridge void*)cb,(__bridge void*)color,(__bridge void*)depth,(__bridge void*)fence,&p)){fprintf(stderr,"%s\n",rt_error(ctx));return 1;}
        if(!rt_attribute_statistics(ctx,&stats[frame]))return 1;
        readbacks[frame]=[device newBufferWithLength:size*size*4 options:MTLResourceStorageModeShared];
        auto blit=[cb blitCommandEncoder];[blit waitForFence:fence];[blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(size,size,1) toBuffer:readbacks[frame] destinationOffset:0 destinationBytesPerRow:size*4 destinationBytesPerImage:size*size*4];[blit endEncoding];
    }
    // All three frames are encoded but unsubmitted. Release the scene and its latest pose;
    // indirect resources for every earlier pose must remain alive through their commands.
    fprintf(stderr,"attribute proof: destroying context\n");rt_destroy(ctx);
    fprintf(stderr,"attribute proof: committing frames\n");for(auto cb:buffers)[cb commit];
    double energy[3]={};unsigned alphaErrors=0;bool sameStatic=true,independentPoses=true;
    for(unsigned frame=0;frame<3;frame++){
        auto cb=buffers[frame];fprintf(stderr,"attribute proof: waiting frame %u\n",frame);[cb waitUntilCompleted];if(cb.status!=MTLCommandBufferStatusCompleted){fprintf(stderr,"%s\n",cb.error.localizedDescription.UTF8String);return 1;}
        auto bytes=(const uint8_t*)readbacks[frame].contents;
        for(unsigned pixel=0;pixel<size*size;pixel++){
            if(bytes[pixel*4+3]!=128)alphaErrors++;
            unsigned other=std::max(bytes[pixel*4+(frame+1)%3],bytes[pixel*4+(frame+2)%3]);
            energy[frame]+=std::max(0,int(bytes[pixel*4+frame])-int(other));
        }
        for(unsigned i=0;i<3;i++){
            sameStatic&=stats[frame].static_addresses[i]==stats[0].static_addresses[i]&&stats[frame].static_addresses[i]!=0;
            independentPoses&=stats[frame].dynamic_addresses[i]!=stats[frame].static_addresses[i]&&stats[frame].dynamic_addresses[i]!=0;
            if(frame){if(i==1)independentPoses&=stats[frame].dynamic_addresses[i]==stats[frame-1].dynamic_addresses[i];
                else independentPoses&=stats[frame].dynamic_addresses[i]!=stats[frame-1].dynamic_addresses[i];}
        }
    }
    if(capture)[manager stopCapture];
    bool passed=sameStatic&&independentPoses&&!alphaErrors&&energy[0]>1000&&energy[1]>1000&&energy[2]>1000&&stats[0].dynamic_bytes==268;
    printf("{\"passed\":%s,\"queuedFramesSurviveContextDestruction\":%s,\"staticResourceAddressesUnchanged\":%s,\"independentPoseResources\":%s,\"unchangedMaterialAllocationReused\":%s,\"dynamicAttributeBytesPerPose\":%llu,\"staticAttributeBytes\":%llu,\"rgbIndirectEnergy\":[%.1f,%.1f,%.1f],\"alphaErrors\":%u}\n",passed?"true":"false",passed?"true":"false",sameStatic?"true":"false",independentPoses?"true":"false",independentPoses?"true":"false",(unsigned long long)stats[0].dynamic_bytes,(unsigned long long)stats[0].static_bytes,energy[0],energy[1],energy[2],alphaErrors);
    return passed?0:1;
}}
