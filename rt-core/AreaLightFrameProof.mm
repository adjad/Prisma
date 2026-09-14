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
    constexpr unsigned size=64,frames=4;
    auto device=MTLCreateSystemDefaultDevice();if(!device)return 1;auto queue=[device newCommandQueue];auto fence=[device newFence];
    auto manager=[MTLCaptureManager sharedCaptureManager];bool capture=argc==3&&strcmp(argv[1],"--capture")==0;
    if(capture){auto request=[MTLCaptureDescriptor new];request.captureObject=device;request.destination=MTLCaptureDestinationGPUTraceDocument;request.outputURL=[NSURL fileURLWithPath:@(argv[2])];NSError *error=nil;if(![manager startCaptureWithDescriptor:request error:&error]){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 1;}}
    NSString *shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];char error[4096];
    fprintf(stderr,"area-light frame proof: creating context\n");
    auto ctx=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));if(!ctx){fprintf(stderr,"%s\n",error);return 1;}
    std::vector<RtVertex> floor,actor;quad(floor,{0,0,2},{8,0,2},{8,8,2},{0,8,2});quad(actor,{3,3,3},{5,3,3},{5,5,3},{3,5,3});
    if(!rt_build_triangles(ctx,floor.data(),unsigned(floor.size())))return 1;
    std::vector<RtMaterial> materials(actor.size()/3);for(auto &m:materials){for(auto &v:m.tint)v=1;m.surface[0]=.85;m.surface[2]=2;m.optics[0]=1.5;m.optics[2]=1;m.image[1]=m.image[2]=1;}
    auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:size height:size mipmapped:NO];desc.storageMode=MTLStorageModePrivate;desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    auto color=[device newTextureWithDescriptor:desc];desc.pixelFormat=MTLPixelFormatDepth32Float;auto depth=[device newTextureWithDescriptor:desc];
    RtFrameParameters p={};p.inverse_view_projection[0]=p.inverse_view_projection[5]=4;p.inverse_view_projection[10]=-4;p.inverse_view_projection[15]=1;
    p.camera[0]=p.camera[1]=p.camera[2]=4;p.camera[3]=8;p.sun[1]=.6;p.sun[2]=.8;p.sun[3]=.04;
    p.controls[0]=1.5;p.controls[1]=.003;p.transport[1]=0;p.transport[2]=3.1415927;p.transport[3]=16;p.dimensions[0]=p.dimensions[1]=size/2;p.dimensions[2]=25;p.dimensions[3]=0;
    id<MTLCommandBuffer> buffers[frames];id<MTLBuffer> readbacks[frames];RtAttributeStatistics stats[frames]={};
    RtAreaLight lamp={{4,4,4,0},{1,0,0,0},{0,-1,0,0},{0,0,0,0}};
    for(unsigned frame=0;frame<frames;frame++){
        fprintf(stderr,"area-light frame proof: encoding frame %u\n",frame);
        for(unsigned i=0;i<3;i++)lamp.radiance[i]=i==frame?6:0;
        if(!rt_set_area_lights(ctx,frame==3?nullptr:&lamp,frame==3?0:1))return 1;
        p.dimensions[2]++;
        auto cb=[queue commandBuffer];cb.label=@"Retained local lamps: queued RGB and removal frames";buffers[frame]=cb;
        auto pass=[MTLRenderPassDescriptor renderPassDescriptor];auto ca=pass.colorAttachments[0];ca.texture=color;ca.loadAction=MTLLoadActionClear;ca.storeAction=MTLStoreActionStore;ca.clearColor=MTLClearColorMake(.5,.5,.5,.5);
        pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=.5;
        auto clear=[cb renderCommandEncoderWithDescriptor:pass];[clear updateFence:fence afterStages:MTLRenderStageVertex|MTLRenderStageFragment];[clear endEncoding];
        if(!rt_encode_frame(ctx,(__bridge void*)cb,(__bridge void*)color,(__bridge void*)depth,(__bridge void*)fence,&p)){fprintf(stderr,"%s\n",rt_error(ctx));return 1;}
        if(!rt_attribute_statistics(ctx,&stats[frame]))return 1;
        readbacks[frame]=[device newBufferWithLength:size*size*4 options:MTLResourceStorageModeShared];
        auto blit=[cb blitCommandEncoder];[blit waitForFence:fence];[blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(size,size,1) toBuffer:readbacks[frame] destinationOffset:0 destinationBytesPerRow:size*4 destinationBytesPerImage:size*size*4];[blit endEncoding];
    }
    // All colored frames plus light removal are queued but unsubmitted. Each immutable
    // light allocation must survive scene destruction and retain its own radiance.
    fprintf(stderr,"area-light frame proof: destroying context\n");rt_destroy(ctx);
    fprintf(stderr,"area-light frame proof: committing frames\n");for(auto cb:buffers)[cb commit];
    double energy[3]={};unsigned alphaErrors=0,removalErrors=0;bool sameStatic=true;
    for(unsigned frame=0;frame<frames;frame++){
        auto cb=buffers[frame];fprintf(stderr,"area-light frame proof: waiting frame %u\n",frame);[cb waitUntilCompleted];if(cb.status!=MTLCommandBufferStatusCompleted){fprintf(stderr,"%s\n",cb.error.localizedDescription.UTF8String);return 1;}
        auto bytes=(const uint8_t*)readbacks[frame].contents;
        for(unsigned pixel=0;pixel<size*size;pixel++){
            if(bytes[pixel*4+3]!=128)alphaErrors++;
            if(frame<3){unsigned other=std::max(bytes[pixel*4+(frame+1)%3],bytes[pixel*4+(frame+2)%3]);energy[frame]+=std::max(0,int(bytes[pixel*4+frame])-int(other));}
            else for(unsigned channel=0;channel<3;channel++)if(bytes[pixel*4+channel]!=128)removalErrors++;
        }
        for(unsigned i=0;i<3;i++)sameStatic&=stats[frame].static_addresses[i]==stats[0].static_addresses[i]&&stats[frame].static_addresses[i]!=0;
    }
    if(capture)[manager stopCapture];
    bool passed=sameStatic&&!removalErrors&&!alphaErrors&&energy[0]>1000&&energy[1]>1000&&energy[2]>1000;
    printf("{\"passed\":%s,\"queuedLightsSurviveContextDestruction\":%s,\"directWorksWithGiAndReflectionDisabled\":%s,\"staticResourceAddressesUnchanged\":%s,\"rgbDirectEnergy\":[%.1f,%.1f,%.1f],\"alphaErrors\":%u,\"removalErrors\":%u}\n",passed?"true":"false",passed?"true":"false",passed?"true":"false",sameStatic?"true":"false",energy[0],energy[1],energy[2],alphaErrors,removalErrors);
    return passed?0:1;
}}
