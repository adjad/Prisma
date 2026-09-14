// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#include "RtCore.h"
#include <vector>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
struct Mesh {
 std::vector<RtVertex> vertices;std::vector<RtMaterial> materials;std::vector<uint32_t> texels;
 void plane(float z,uint32_t color,float emission=0) {
  RtVertex a{0,0,z},b{8,0,z},c{8,8,z},d{0,8,z};
  RtMaterial m={};for(float &v:m.tint)v=1;m.surface[0]=.85;m.surface[2]=emission;m.optics[0]=1.5;m.optics[2]=1;m.image[0]=uint32_t(texels.size());m.image[1]=m.image[2]=1;texels.push_back(color);
  for(auto v:{a,b,c,a,c,d})vertices.push_back(v);materials.push_back(m);materials.push_back(m);
 }
 bool upload(RtContext *ctx){return rt_build_triangles(ctx,vertices.data(),uint32_t(vertices.size()))&&rt_set_materials(ctx,materials.data(),uint32_t(materials.size()),texels.data(),uint32_t(texels.size()));}
};
int main(){@autoreleasepool{
 constexpr unsigned size=256;auto device=MTLCreateSystemDefaultDevice();if(!device)return 1;auto queue=[device newCommandQueue];auto fence=[device newFence];
 NSString *shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];char error[4096];auto ctx=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));if(!ctx){fprintf(stderr,"%s\n",error);return 1;}
 auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:size height:size mipmapped:NO];desc.storageMode=MTLStorageModePrivate;desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;auto color=[device newTextureWithDescriptor:desc];desc.pixelFormat=MTLPixelFormatDepth32Float;auto depth=[device newTextureWithDescriptor:desc];
 RtFrameParameters p={};p.inverse_view_projection[0]=p.inverse_view_projection[5]=4;p.inverse_view_projection[10]=-4;p.inverse_view_projection[15]=1;p.camera[0]=p.camera[1]=p.camera[2]=4;p.camera[3]=8;p.sun[1]=.6;p.sun[2]=.8;p.controls[0]=2;p.controls[1]=.003;p.controls[2]=p.controls[3]=1;p.transport[2]=3.14159265f;p.transport[3]=16;p.dimensions[0]=p.dimensions[1]=size/2;p.dimensions[3]=32768u|2u|(4u<<12);
 int failures=0;auto check=[&](bool condition,const char *name){if(!condition){failures++;fprintf(stderr,"FAIL %s: %s\n",name,rt_error(ctx));}};
 auto frame=[&](float raster,float z=.5f){
  auto cb=[queue commandBuffer];auto pass=[MTLRenderPassDescriptor renderPassDescriptor];auto ca=pass.colorAttachments[0];ca.texture=color;ca.loadAction=MTLLoadActionClear;ca.storeAction=MTLStoreActionStore;ca.clearColor=MTLClearColorMake(raster,raster,raster,.375);
  pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=z;
  auto clear=[cb renderCommandEncoderWithDescriptor:pass];[clear updateFence:fence afterStages:MTLRenderStageVertex|MTLRenderStageFragment];[clear endEncoding];p.dimensions[2]++;
  check(rt_encode_frame(ctx,(__bridge void*)cb,(__bridge void*)color,(__bridge void*)depth,(__bridge void*)fence,&p),"encode");
  auto output=[device newBufferWithLength:size*size*16 options:MTLResourceStorageModeShared];auto blit=[cb blitCommandEncoder];[blit waitForFence:fence];[blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(size,size,1) toBuffer:output destinationOffset:0 destinationBytesPerRow:size*16 destinationBytesPerImage:size*size*16];[blit endEncoding];[cb commit];[cb waitUntilCompleted];check(cb.status==MTLCommandBufferStatusCompleted,"GPU completion");
  std::array<double,4> mean{};auto values=(const float*)output.contents;for(unsigned y=size/2-8;y<size/2+8;y++)for(unsigned x=size/2-8;x<size/2+8;x++)for(unsigned k=0;k<4;k++)mean[k]+=values[(y*size+x)*4+k]/256.;return mean;
 };

 // A real frame pipeline, with deterministic emissive radiance and no sampled light.
 Mesh emission;emission.plane(2,0xffff8040,100);check(emission.upload(ctx),"HDR emissive surface");
 p.sun[1]=-1;p.sun[2]=0;p.transport[2]=0;p.dimensions[3]=32768u|1u|(4u<<12);
 auto raw=frame(.7);check(raw[0]>99.99&&raw[0]<100.01,"scene-linear HDR retained");
 p.display[1]=1;auto mapped=frame(.7);
 check(std::abs(mapped[0]-100./101)<.00001,"highlight rolloff reference");
 check(std::abs(mapped[1]/mapped[0]-raw[1]/raw[0])<.00001,"RGB ratios preserved");
 RtFrameStatistics before{},after{};rt_frame_statistics(ctx,&before);
 p.display[0]=-1;auto darker=frame(.7);rt_frame_statistics(ctx,&after);
 check(std::abs(darker[0]-50./51)<.00001,"minus one EV halves scene exposure");
 check(before.history_resets==after.history_resets,"exposure does not reset scene-linear history");
 p.display[1]=0;auto bypassed=frame(.7);check(std::abs(bypassed[0]-raw[0])<.00001,"master bypass ignores exposure");
 p.display[1]=1;p.display[0]=8;auto sky=frame(.7,0);check(std::abs(sky[0]-.7)<.000001&&std::abs(sky[3]-.375)<.000001,"sky and alpha unchanged at maximum exposure");
 // Radius-transition pixels contain a mix of traced radiance and raster fallback.
 // Infer their mean coverage from raw linear output, then independently calculate
 // the expected blend of mapped surface radiance and unmodified raster color.
 p.camera[0]=1;p.display[0]=0;p.display[1]=0;auto partialRaw=frame(.7);
 double coverage=(partialRaw[0]-.7)/(100-.7);p.display[1]=1;auto partialMapped=frame(.7);
 check(coverage>.2&&coverage<.8,"fixture has partial coverage");
 check(std::abs(partialMapped[0]-(.7*(1-coverage)+(100./101)*coverage))<.00001,"tone map surface before coverage blend");
 p.camera[0]=4;
 auto view=matrix_identity_float4x4;view.columns[3]={-4,-4,-4,1};simd_float4x4 inv;memcpy(&inv,p.inverse_view_projection,64);auto projection=simd_inverse(inv);
 check(rt_set_metalfx_camera(ctx,(float*)&view,(float*)&projection),"MetalFX camera");
 p.dimensions[3]|=16u|64u;p.display[1]=0;std::array<double,4> fxRaw{};
 for(unsigned f=0;f<12;f++)fxRaw=frame(.7);
 check(std::isfinite(fxRaw[0])&&std::abs(fxRaw[0]-100)<2,"MetalFX carries HDR radiance");
 RtMetalFxStatistics fxBefore{},fxAfter{};rt_metalfx_statistics(ctx,&fxBefore);p.display[1]=1;auto fxMapped=frame(.7);p.display[0]=-1;auto fxDarker=frame(.7);rt_metalfx_statistics(ctx,&fxAfter);
 check(std::abs(fxMapped[0]-100./101)<.001,"MetalFX tone mapping after reconstruction");
 check(std::abs(fxDarker[0]-50./51)<.001,"MetalFX exposure applied once");
 check(fxBefore.history_resets==fxAfter.history_resets,"MetalFX exposure preserves history");
 auto fxSky=frame(.7,0);check(std::abs(fxSky[0]-.7)<.000001&&std::abs(fxSky[3]-.375)<.000001,"MetalFX sky and alpha preserved");
 p.dimensions[3]&=~32768u;p.controls[2]=p.controls[3]=0;p.dimensions[2]=10000;auto hybrid=frame(.7);
 p.display[1]=0;p.dimensions[2]=10000;auto hybridBypass=frame(.7);
 check(std::abs(hybrid[0]-hybridBypass[0])<.00001,"hybrid MetalFX display unaffected by tone mapping");
 p.dimensions[3]&=~16u;p.display[1]=1;auto plainHybrid=frame(.7);check(std::abs(plainHybrid[0]-.7)<.000001,"hybrid raster value preserved");
 // A valid extremely smooth metal and directional sun exceed 65,504, the largest
 // finite half float. Keep this actual traced frame finite through history and mapping.
 Mesh mirror;mirror.plane(2,0xffffffff);for(auto &m:mirror.materials){m.surface[0]=.001;m.surface[1]=1;}check(mirror.upload(ctx),"smooth HDR mirror");
 p.dimensions[3]=32768u|1u|(4u<<12);p.inverse_view_projection[0]=p.inverse_view_projection[5]=.00001f;
 p.sun[1]=.001f;p.sun[2]=std::sqrt(1-.001f*.001f);p.inverse_view_projection[13]=.002f;p.transport[0]=1;p.transport[2]=100;p.display[1]=0;
 auto extreme=frame(.7);check(std::isfinite(extreme[0])&&extreme[0]>65504,"traced specular radiance exceeds half-float range without overflow");
 p.display[1]=1;p.display[0]=-8;auto extremeMapped=frame(.7);
 check(std::isfinite(extremeMapped[0])&&extremeMapped[0]>.9&&extremeMapped[0]<=1,"extreme specular history maps to finite display");
 // Invalid display controls must fail before encoding or advancing history.
 auto cb=[queue commandBuffer];for(float bad:{NAN,INFINITY,-8.01f,8.01f}){p.display[0]=bad;check(!rt_encode_frame(ctx,(__bridge void*)cb,(__bridge void*)color,(__bridge void*)depth,(__bridge void*)fence,&p),"invalid exposure rejected");}
 p.display[0]=0;p.display[1]=.5;check(!rt_encode_frame(ctx,(__bridge void*)cb,(__bridge void*)color,(__bridge void*)depth,(__bridge void*)fence,&p),"invalid tone toggle rejected");
 printf("{\"passed\":%s,\"failures\":%d,\"rawLinear\":%.8f,\"mappedLinear\":%.8f,\"minusOneEv\":%.8f,\"partialCoverage\":%.8f,\"partialMapped\":%.8f,\"fxRawLinear\":%.8f,\"fxMappedLinear\":%.8f,\"fxMinusOneEv\":%.8f,\"fxCompletedFrames\":%llu,\"extremeLinear\":%.8f,\"extremeMapped\":%.8f}\n",failures?"false":"true",failures,raw[0],mapped[0],darker[0],coverage,partialMapped[0],fxRaw[0],fxMapped[0],fxDarker[0],(unsigned long long)fxAfter.completed_frames,extreme[0],extremeMapped[0]);
 rt_destroy(ctx);return failures?1:0;
}}
