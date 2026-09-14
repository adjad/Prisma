// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#include "RtCore.h"
#include <vector>
#include <cstdio>
#include <cmath>
#include <cstring>
#include <cstdlib>
static void quad(std::vector<RtVertex>&v,RtVertex a,RtVertex b,RtVertex c,RtVertex d){for(auto p:{a,b,c,a,c,d})v.push_back(p);}
int main(){@autoreleasepool{
    constexpr unsigned size=128,frames=48,warmup=24;
    auto device=MTLCreateSystemDefaultDevice();auto queue=[device newCommandQueue];auto fence=[device newFence];
    NSString *shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];char error[4096];
    auto ctx=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));if(!ctx){fprintf(stderr,"%s\n",error);return 1;}
    std::vector<RtVertex> vertices;
    quad(vertices,{2.25,2.25,2},{5.75,2.25,2},{5.75,5.75,2},{2.25,5.75,2});
    quad(vertices,{3.5,3.5,2},{4.5,3.5,2},{4.5,3.5,2.75},{3.5,3.5,2.75});
    quad(vertices,{4.5,4.5,2},{3.5,4.5,2},{3.5,4.5,2.75},{4.5,4.5,2.75});
    quad(vertices,{3.5,4.5,2},{3.5,3.5,2},{3.5,3.5,2.75},{3.5,4.5,2.75});
    quad(vertices,{4.5,3.5,2},{4.5,4.5,2},{4.5,4.5,2.75},{4.5,3.5,2.75});
    if(!rt_build_triangles(ctx,vertices.data(),unsigned(vertices.size()))){fprintf(stderr,"%s\n",rt_error(ctx));return 1;}
    simd_float4x4 projection={};projection.columns[0].x=projection.columns[1].y=1;
    projection.columns[2].z=.1f/(20-.1f);projection.columns[2].w=-1;projection.columns[3].z=2.f/(20-.1f);
    auto view=matrix_identity_float4x4;view.columns[3]={-4,-4,-4,1};
    if(!rt_set_metalfx_camera(ctx,(float*)&view,(float*)&projection)){fprintf(stderr,"%s\n",rt_error(ctx));return 1;}
    auto invalid=view;invalid.columns[0].x=NAN;
    bool rejectsInvalid=!rt_set_metalfx_camera(ctx,(float*)&invalid,(float*)&projection);
    auto colorDesc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:size height:size mipmapped:NO];
    colorDesc.storageMode=MTLStorageModePrivate;colorDesc.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    auto color=[device newTextureWithDescriptor:colorDesc];colorDesc.pixelFormat=MTLPixelFormatDepth32Float;auto depth=[device newTextureWithDescriptor:colorDesc];
    auto readback=[device newBufferWithLength:size*size*4 options:MTLResourceStorageModeShared];
    RtFrameParameters p={};auto inverse=simd_inverse(projection);memcpy(p.inverse_view_projection,&inverse,64);
    p.camera[0]=p.camera[1]=p.camera[2]=4;p.camera[3]=8;p.sun[1]=.6;p.sun[2]=.8;p.sun[3]=.1;
    p.controls[0]=1.5;p.controls[1]=.003;p.controls[2]=p.controls[3]=1;p.dimensions[0]=p.dimensions[1]=size/2;
    double variance[2]={},mean[2]={},gpuMs[2]={};unsigned alphaErrors=0,bypassErrors=0;
    auto render=[&](){
        auto cb=[queue commandBuffer];cb.label=@"MetalFX integration, variance and reset proof";
        auto pass=[MTLRenderPassDescriptor renderPassDescriptor];auto ca=pass.colorAttachments[0];ca.texture=color;ca.loadAction=MTLLoadActionClear;ca.storeAction=MTLStoreActionStore;ca.clearColor=MTLClearColorMake(1,1,1,.5);
        pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=(projection.columns[2].z*-2+projection.columns[3].z)/2;
        auto clear=[cb renderCommandEncoderWithDescriptor:pass];[clear updateFence:fence afterStages:MTLRenderStageVertex|MTLRenderStageFragment];[clear endEncoding];
        if(!rt_encode_frame(ctx,(__bridge void*)cb,(__bridge void*)color,(__bridge void*)depth,(__bridge void*)fence,&p)){fprintf(stderr,"%s\n",rt_error(ctx));return false;}
        auto blit=[cb blitCommandEncoder];[blit waitForFence:fence];[blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(size,size,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:size*4 destinationBytesPerImage:size*size*4];[blit endEncoding];
        [cb commit];[cb waitUntilCompleted];if(cb.status!=MTLCommandBufferStatusCompleted){fprintf(stderr,"%s\n",cb.error.localizedDescription.UTF8String);return false;}return true;
    };
    for(unsigned mode=0;mode<2;mode++){
        std::vector<double> sum(size*size),squared(size*size);p.dimensions[3]=8|64|(mode?16:2);
        for(unsigned frame=0;frame<frames;frame++){@autoreleasepool{
            bool capture=mode==1&&frame==warmup&&getenv("RT_METALFX_CAPTURE_PATH");
            if(capture){
                auto desc=[MTLCaptureDescriptor new];desc.captureObject=device;desc.destination=MTLCaptureDestinationGPUTraceDocument;
                desc.outputURL=[NSURL fileURLWithPath:@(getenv("RT_METALFX_CAPTURE_PATH"))];NSError *captureError=nil;
                if(![[MTLCaptureManager sharedCaptureManager] startCaptureWithDescriptor:desc error:&captureError]){fprintf(stderr,"%s\n",captureError.localizedDescription.UTF8String);return 1;}
            }
            ++p.dimensions[2];if(!render())return 1;
            if(capture)[[MTLCaptureManager sharedCaptureManager] stopCapture];
            RtFrameStatistics stats={};rt_frame_statistics(ctx,&stats);if(frame>=warmup)gpuMs[mode]+=stats.last_command_gpu_ms/(frames-warmup);
            auto pixels=(const uint8_t*)readback.contents;
            for(unsigned i=0;i<size*size;i++){
                if(pixels[i*4+3]!=128)alphaErrors++;
                unsigned x=i%size,y=i/size;if((x<4||x>=size-4||y<4||y>=size-4)&&pixels[i*4]!=255)bypassErrors++;
                if(frame>=warmup){double value=pixels[i*4]/255.;sum[i]+=value;squared[i]+=value*value;}
            }
        }}
        unsigned samples=0;
        for(unsigned y=12;y<116;y++)for(unsigned x=12;x<116;x++){
            auto i=y*size+x;double average=sum[i]/(frames-warmup);mean[mode]+=average;
            variance[mode]+=std::max(0.,squared[i]/(frames-warmup)-average*average);samples++;
        }
        variance[mode]/=samples;mean[mode]/=samples;
    }
    RtMetalFxStatistics before={};rt_metalfx_statistics(ctx,&before);
    p.dimensions[2]+=100;p.controls[2]=p.controls[3]=0;if(!render())return 1;
    RtMetalFxStatistics after={};rt_metalfx_statistics(ctx,&after);
    double resetMean=0;auto pixels=(const uint8_t*)readback.contents;for(unsigned i=0;i<size*size;i++)resetMean+=pixels[i*4]/255.;resetMean/=size*size;
    bool passed=rejectsInvalid&&before.supported&&before.active&&before.completed_frames==frames&&before.history_resets==1&&after.history_resets==2&&!alphaErrors&&!bypassErrors&&variance[0]>1e-6&&variance[1]<variance[0]*.8&&std::abs(mean[1]-mean[0])<.12&&resetMean>.98;
    printf("{\"passed\":%s,\"denoiserExecuted\":true,\"encodedFrames\":%llu,\"completedFrames\":%llu,\"historyResets\":%llu,\"rawVariance\":%.9f,\"denoisedVariance\":%.9f,\"varianceReductionPercent\":%.3f,\"rawMean\":%.6f,\"denoisedMean\":%.6f,\"resetMean\":%.6f,\"rawCommandGpuMs\":%.4f,\"denoisedCommandGpuMs\":%.4f,\"alphaErrors\":%u,\"bypassErrors\":%u,\"invalidMatrixRejected\":%s}\n",passed?"true":"false",(unsigned long long)after.encoded_frames,(unsigned long long)after.completed_frames,(unsigned long long)after.history_resets,variance[0],variance[1],100*(1-variance[1]/variance[0]),mean[0],mean[1],resetMean,gpuMs[0],gpuMs[1],alphaErrors,bypassErrors,rejectsInvalid?"true":"false");
    rt_destroy(ctx);return passed?0:1;
}}
