// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "RtCore.h"
#include <vector>
#include <cstdio>
#include <string>
static void quad(std::vector<RtVertex>&v,RtVertex a,RtVertex b,RtVertex c,RtVertex d){for(auto p:{a,b,c,a,c,d})v.push_back(p);}
int main(int argc,char **argv){@autoreleasepool{
    bool horizontal=false;unsigned raySamples=0;
    for(int i=1;i<argc;i++){std::string arg=argv[i];if(arg=="--horizontal-coverage")horizontal=true;if(arg=="--samples-one")raySamples=1;if(arg=="--samples-two")raySamples=2;}
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    NSString *shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];
    char error[4096];auto ctx=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));
    if(!ctx){fprintf(stderr,"%s\n",error);return 1;}
    std::vector<RtVertex> vertices;
    quad(vertices,{0,0,2},{8,0,2},{8,8,2},{0,8,2});
    quad(vertices,{3,3,2},{5,3,2},{5,3,3},{3,3,3});
    quad(vertices,{5,5,2},{3,5,2},{3,5,3},{5,5,3});
    quad(vertices,{3,5,2},{3,3,2},{3,3,3},{3,5,3});
    quad(vertices,{5,3,2},{5,5,2},{5,5,3},{5,3,3});
    quad(vertices,{3,3,3},{5,3,3},{5,5,3},{3,5,3});
    if(horizontal)for(auto &v:vertices)v.y+=16;
    if(!rt_build_triangles(ctx,vertices.data(),uint32_t(vertices.size()))){fprintf(stderr,"%s\n",rt_error(ctx));return 1;}
    auto colorDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
    colorDesc.storageMode=MTLStorageModePrivate;colorDesc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    auto depthDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:64 height:64 mipmapped:NO];
    depthDesc.storageMode=MTLStorageModePrivate;depthDesc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    id<MTLTexture> color=[device newTextureWithDescriptor:colorDesc],depth=[device newTextureWithDescriptor:depthDesc];
    id<MTLFence> fence=[device newFence];id<MTLCommandQueue> queue=[device newCommandQueue];
    RtFrameParameters p={};p.inverse_view_projection[0]=4;p.inverse_view_projection[5]=4;p.inverse_view_projection[10]=-4;p.inverse_view_projection[15]=1;
    p.camera[0]=4;p.camera[1]=4;p.camera[2]=4;p.camera[3]=8;if(horizontal){p.camera[1]+=16;p.dimensions[3]|=2048;}
    p.sun[0]=0;p.sun[1]=.6;p.sun[2]=.8;p.sun[3]=.04;
    p.controls[0]=1.5;p.controls[1]=.003;p.dimensions[3]|=(raySamples<<12);p.dimensions[0]=32;p.dimensions[1]=32;p.dimensions[2]=25;
    unsigned changed=0,baselineErrors=0,alphaErrors=0;unsigned minColor=255;
    for(int enabled=0;enabled<2;enabled++){
        p.controls[2]=p.controls[3]=float(enabled);
        id<MTLCommandBuffer> cb=[queue commandBuffer];cb.label=@"RT live frame correctness proof";
        auto pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=color;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(1,1,1,1);
        pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=.5;
        auto clear=[cb renderCommandEncoderWithDescriptor:pass];[clear updateFence:fence afterStages:MTLRenderStageVertex|MTLRenderStageFragment];[clear endEncoding];
        if(!rt_encode_frame(ctx,(__bridge void*)cb,(__bridge void*)color,(__bridge void*)depth,(__bridge void*)fence,&p)){fprintf(stderr,"%s\n",rt_error(ctx));return 1;}
        id<MTLBuffer> readback=[device newBufferWithLength:64*64*4 options:MTLResourceStorageModeShared];
        auto blit=[cb blitCommandEncoder];[blit waitForFence:fence];
        [blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(64,64,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:64*256];
        [blit endEncoding];[cb commit];[cb waitUntilCompleted];
        if(cb.status!=MTLCommandBufferStatusCompleted){fprintf(stderr,"%s\n",cb.error.localizedDescription.UTF8String);return 1;}
        auto bytes=(const unsigned char*)readback.contents;
        for(int pixel=0;pixel<64*64;pixel++){
            if(bytes[pixel*4+3]!=255)alphaErrors++;
            if(!enabled&&bytes[pixel*4]!=255)baselineErrors++;
            if(enabled){if(bytes[pixel*4]<250)changed++;minColor=std::min(minColor,unsigned(bytes[pixel*4]));}
        }
    }
    char copyError[4096];auto copy=rt_create((__bridge void*)device,shader.UTF8String,copyError,sizeof(copyError));
    bool historyTransferred=copy&&rt_build_triangles(copy,vertices.data(),uint32_t(vertices.size()))&&rt_inherit_history(copy,ctx);
    RtFrameStatistics statistics={};bool statisticsRead=rt_frame_statistics(copy,&statistics)&&statistics.encoded_frames==2&&statistics.history_resets==2;
    vertices[0].x+=.25f;
    bool changedSceneRejected=rt_build_triangles(copy,vertices.data(),uint32_t(vertices.size()))&&!rt_inherit_history(copy,ctx);
    rt_destroy(copy);
    bool passed=historyTransferred&&statisticsRead&&changedSceneRejected&&!baselineErrors&&!alphaErrors&&changed>(raySamples?20u:50u)&&minColor<200;
    printf("{\"passed\":%s,\"changedPixels\":%u,\"minimumEnabledChannel\":%u,\"zeroStrengthErrors\":%u,\"alphaErrors\":%u,\"historyTransfer\":%s,\"changedSceneRejected\":%s,\"statisticsRead\":%s}\n",passed?"true":"false",changed,minColor,baselineErrors,alphaErrors,historyTransferred?"true":"false",changedSceneRejected?"true":"false",statisticsRead?"true":"false");
    fprintf(stderr,"historyTransfer=%d, changedSceneRejected=%d, statisticsRead=%d\n",historyTransferred,changedSceneRejected,statisticsRead);
    rt_destroy(ctx);return passed?0:1;
}}
