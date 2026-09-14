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
 std::vector<float> lastPixels(size*size*4);
 int failures=0;auto check=[&](bool condition,const char *name){if(!condition){failures++;fprintf(stderr,"FAIL %s: %s\n",name,rt_error(ctx));}};
 auto frame=[&](float raster,float z=.5f){
  auto cb=[queue commandBuffer];auto pass=[MTLRenderPassDescriptor renderPassDescriptor];auto ca=pass.colorAttachments[0];ca.texture=color;ca.loadAction=MTLLoadActionClear;ca.storeAction=MTLStoreActionStore;ca.clearColor=MTLClearColorMake(raster,raster,raster,.375);
  pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=z;
  auto clear=[cb renderCommandEncoderWithDescriptor:pass];[clear updateFence:fence afterStages:MTLRenderStageVertex|MTLRenderStageFragment];[clear endEncoding];p.dimensions[2]++;
  check(rt_encode_frame(ctx,(__bridge void*)cb,(__bridge void*)color,(__bridge void*)depth,(__bridge void*)fence,&p),"encode");
  auto output=[device newBufferWithLength:size*size*16 options:MTLResourceStorageModeShared];auto blit=[cb blitCommandEncoder];[blit waitForFence:fence];[blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(size,size,1) toBuffer:output destinationOffset:0 destinationBytesPerRow:size*16 destinationBytesPerImage:size*size*16];[blit endEncoding];[cb commit];[cb waitUntilCompleted];check(cb.status==MTLCommandBufferStatusCompleted,"GPU completion");
  std::array<double,4> mean{};auto values=(const float*)output.contents;memcpy(lastPixels.data(),values,lastPixels.size()*sizeof(float));for(unsigned y=size/2-8;y<size/2+8;y++)for(unsigned x=size/2-8;x<size/2+8;x++)for(unsigned k=0;k<4;k++)mean[k]+=values[(y*size+x)*4+k]/256.;return mean;
 };


 Mesh floor;floor.plane(2,0xffffffff);for(auto &m:floor.materials){m.surface[0]=.2;m.surface[1]=1;}check(floor.upload(ctx),"metal floor");
 auto view=matrix_identity_float4x4;view.columns[3]={-4,-4,-4,1};simd_float4x4 inverse;memcpy(&inverse,p.inverse_view_projection,64);auto projection=simd_inverse(inverse);
 check(rt_set_metalfx_camera(ctx,(float*)&view,(float*)&projection),"camera");
 p.dimensions[3]=32768u|1u|16u|64u|128u;p.controls[2]=0;p.controls[3]=1;p.sun[3]=0;p.sun[1]=-1;p.sun[2]=0;p.transport[0]=1;p.transport[2]=0;
 auto actor=[&](float x){
  RtVertex vertices[]={{x,6,5},{x+2,6,5},{x+2,8,5},{x,6,5},{x+2,8,5},{x,8,5}};
  RtMaterial m={};for(float &v:m.tint)v=1;m.surface[0]=1;m.surface[2]=2;m.optics[0]=1.5;m.optics[2]=1;m.image[1]=m.image[2]=1;RtMaterial materials[]={m,m};uint32_t white=0xffff0000;
  return rt_set_dynamic_mesh(ctx,vertices,6,materials,&white,1);
 };
 auto region=[&](float x,float y){
  // The inverse camera maps output UV directly onto the z=2 receiver plane.
  int px=int(x/8*size),py=int(y/8*size);double sum=0;
  for(int yy=py-3;yy<=py+3;yy++)for(int xx=px-3;xx<=px+3;xx++)sum+=lastPixels[(yy*size+xx)*4]/49.;return sum;
 };
 check(actor(1),"initial actor");std::array<double,4> values{};
 for(unsigned f=0;f<20;f++)values=frame(.9);
 double initialOld=region(3.2,5.2),initialNew=region(4.8,5.2);
 check(initialOld>1.5&&initialNew<.1,"offscreen actor casts correct geometric reflection");
 check(actor(5),"move actor");values=frame(.9);double movedOld=region(3.2,5.2),movedNew=region(4.8,5.2);
 check(movedOld<.1&&movedNew>1.5,"first moved frame clears old reflection and shades new position");
 for(unsigned f=0;f<40;f++){values=frame(.9);check(region(3.2,5.2)<.1&&region(4.8,5.2)>1.5,"no trail while moving reflection settles");}
 check(rt_set_dynamic_mesh(ctx,nullptr,0,nullptr,nullptr,0),"remove actor");values=frame(.9);double removedOld=region(3.2,5.2),removedNew=region(4.8,5.2);
 check(removedOld<.1&&removedNew<.1,"first removal frame clears stale reflection");
 for(unsigned f=0;f<40;f++){values=frame(.9);check(region(3.2,5.2)<.1&&region(4.8,5.2)<.1,"no reflection trail after removal interval expires");}
 RtMetalFxStatistics fx{};rt_metalfx_statistics(ctx,&fx);check(fx.history_resets==1&&fx.completed_frames==102,"moving and removed actors preserve global MetalFX history");
 check(std::abs(values[3]-.375)<.000001,"alpha unchanged");
 printf("{\"passed\":%s,\"failures\":%d,\"initialReflection\":%.8f,\"initialEmpty\":%.8f,\"movedOldLocation\":%.8f,\"movedNewReflection\":%.8f,\"removedOldLocation\":%.8f,\"removedNewLocation\":%.8f,\"completedFrames\":%llu,\"historyResets\":%llu}\n",failures?"false":"true",failures,initialOld,initialNew,movedOld,movedNew,removedOld,removedNew,(unsigned long long)fx.completed_frames,(unsigned long long)fx.history_resets);
 rt_destroy(ctx);return failures?1:0;
}}
