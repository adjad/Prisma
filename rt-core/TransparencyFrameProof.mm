// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "RtCore.h"
#include <vector>
#include <cstdio>
int main(){@autoreleasepool{
 auto device=MTLCreateSystemDefaultDevice();auto shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];char error[4096];
 auto c=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));if(!c){fprintf(stderr,"%s\n",error);return 1;}
 std::vector<RtVertex> vertices;for(float z:{3.f,2.f})for(auto v:{RtVertex{0,0,z},RtVertex{8,0,z},RtVertex{8,8,z},RtVertex{0,0,z},RtVertex{8,8,z},RtVertex{0,8,z}})vertices.push_back(v);
 RtMaterial materials[4]={};for(int i=0;i<4;i++){auto&m=materials[i];for(int j=0;j<4;j++)m.tint[j]=1;m.surface[0]=.001;m.surface[2]=i>=2?1:0;m.surface[3]=i<2?1:0;m.optics[0]=1.5;m.optics[2]=1;m.image[0]=i<2?0:1;m.image[1]=m.image[2]=1;}
 uint32_t texels[]={0x00ffffff,0xffff0000};
 if(!rt_build_triangles(c,vertices.data(),uint32_t(vertices.size()))||!rt_set_materials(c,materials,4,texels,2)){fprintf(stderr,"%s\n",rt_error(c));return 1;}
 auto cd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];cd.storageMode=MTLStorageModePrivate;cd.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
 auto dd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:64 height:64 mipmapped:NO];dd.storageMode=MTLStorageModePrivate;dd.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
 auto color=[device newTextureWithDescriptor:cd],depth=[device newTextureWithDescriptor:dd];auto queue=[device newCommandQueue];auto fence=[device newFence];
 RtFrameParameters p={};p.inverse_view_projection[0]=4;p.inverse_view_projection[5]=4;p.inverse_view_projection[10]=-4;p.inverse_view_projection[15]=1;
 p.camera[0]=p.camera[1]=p.camera[2]=4;p.camera[3]=8;p.sun[0]=1;p.controls[1]=.003;p.dimensions[0]=p.dimensions[1]=32;p.transport[0]=1;p.transport[3]=32;
 auto reports=[NSMutableArray new];int failures=0;
 for(float rasterDepth:{.5f,0.f,.125f}){
  auto cb=[queue commandBuffer];auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture=color;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,1,.5);
  pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=rasterDepth;
  auto clear=[cb renderCommandEncoderWithDescriptor:pass];[clear updateFence:fence afterStages:MTLRenderStageVertex|MTLRenderStageFragment];[clear endEncoding];
  p.dimensions[2]++;if(!rt_encode_frame(c,(__bridge void*)cb,(__bridge void*)color,(__bridge void*)depth,(__bridge void*)fence,&p)){fprintf(stderr,"%s\n",rt_error(c));return 1;}
  auto out=[device newBufferWithLength:64*64*4 options:MTLResourceStorageModeShared];auto blit=[cb blitCommandEncoder];[blit waitForFence:fence];
  [blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(64,64,1) toBuffer:out destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:64*256];[blit endEncoding];[cb commit];[cb waitUntilCompleted];
  if(cb.status!=MTLCommandBufferStatusCompleted){fprintf(stderr,"%s\n",cb.error.localizedDescription.UTF8String);return 1;}
  auto pixel=(const unsigned char*)out.contents+(32*64+32)*4;
  bool expected=rasterDepth==.125f?(pixel[0]==0&&pixel[2]==255):(pixel[0]>240&&pixel[2]<20);expected&=pixel[3]==128;failures+=!expected;
  [reports addObject:@{@"rasterDepth":@(rasterDepth),@"rgba":@[@(pixel[0]),@(pixel[1]),@(pixel[2]),@(pixel[3])],@"passed":@(expected)}];
 }
 auto json=[NSJSONSerialization dataWithJSONObject:@{@"passed":@(failures==0),@"failures":@(failures),@"cases":reports,@"covers":@[@"transparent surface before opaque depth",@"transparent surface before sky",@"opaque foreground blocks transparent surface",@"raster alpha preserved"]} options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");rt_destroy(c);return failures?1:0;
}}
