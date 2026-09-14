// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
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
 constexpr unsigned size=64;auto device=MTLCreateSystemDefaultDevice();if(!device)return 1;auto queue=[device newCommandQueue];auto fence=[device newFence];
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
  std::array<double,4> mean{};auto values=(const float*)output.contents;for(unsigned y=24;y<40;y++)for(unsigned x=24;x<40;x++)for(unsigned k=0;k<4;k++)mean[k]+=values[(y*size+x)*4+k]/256.;return mean;
 };
 auto linear=[](double v){return v<=.04045?v/12.92:pow((v+.055)/1.055,2.4);};auto srgb=[](double v){return v<=.0031308?v*12.92:1.055*pow(v,1/2.4)-.055;};
 Mesh gray;gray.plane(2,0xff808080);check(gray.upload(ctx),"gray mesh");auto sunDark=frame(.05),sunBright=frame(.95);double expected=srgb(linear(128./255)*.8);
 check(std::abs(sunDark[0]-expected)<.0005,"Lambertian direct sun reference");check(std::abs(sunDark[0]-sunBright[0])<.000001,"covered surface independent of baked color");check(std::abs(sunDark[3]-.375)<.000001,"alpha preserved");
 auto outside=frame(.7,0);check(std::abs(outside[0]-.7)<.000001,"unmatched depth retains raster");
 p.sun[1]=-1;p.sun[2]=0;auto night=frame(.95);check(night[0]==0&&night[1]==0&&night[2]==0,"no baked ambient leakage at night");
 Mesh emissive;emissive.plane(2,0xffff0000,.25);check(emissive.upload(ctx),"emissive mesh");auto emission=frame(.95);check(std::abs(emission[0]-srgb(.25))<.0005&&emission[1]==0&&emission[2]==0,"primary emission with all effects off");
 Mesh white;white.plane(2,0xffffffff);check(white.upload(ctx),"white mesh");p.sun[1]=1;p.sun[2]=0;p.transport[2]=0;p.transport[1]=1;
 // Vertical surface: cosine-weighted hemisphere integration of max(worldY,0) = 2/(3*pi).
 std::array<double,3> sky{};for(unsigned f=0;f<64;f++){auto v=frame(.95);for(unsigned c=0;c<3;c++)sky[c]+=linear(v[c])/64.;}
 double low[3]={.035,.045,.065},high[3]={.16,.25,.4};bool skyMatches=true;for(unsigned c=0;c<3;c++){double reference=low[c]+(high[c]-low[c])*2/(3*3.141592653589793);skyMatches&=std::abs(sky[c]-reference)<.002;}check(skyMatches,"analytic cosine-weighted sky reference");
 p.sun[1]=-1;p.transport[2]=0;RtAreaLight lamp={{5.5,4,4,0},{.4,0,0,0},{0,.4,0,0},{8,8,8,0}};check(rt_set_area_lights(ctx,&lamp,1),"bounce lamp");std::array<double,3> bounced[2];
 for(unsigned variant=0;variant<2;variant++){
  Mesh room;room.plane(2,0xffffffff);room.plane(5,variant?0xff0000ff:0xffff0000);check(room.upload(ctx),"colored bounce room");p.dimensions[2]=99;
  bounced[variant]={};for(unsigned f=0;f<64;f++){auto v=frame(.9);for(unsigned c=0;c<3;c++)bounced[variant][c]+=linear(v[c])/64.;}
 }
 check(bounced[0][0]>.005&&bounced[0][1]==0&&bounced[0][2]==0,"red indirect light reaches neutral receiver");check(bounced[1][2]>.005&&bounced[1][0]==0&&bounced[1][1]==0,"blue indirect light reaches neutral receiver");
 p.transport[1]=0;auto giOff=frame(.9);check(giOff[0]==0&&giOff[1]==0&&giOff[2]==0,"receiver unlit without indirect transport");
 // A distinct legacy branch must continue using the baked surface image.
 check(rt_set_area_lights(ctx,nullptr,0),"lights removed");p.dimensions[3]&=~32768u;p.controls[2]=p.controls[3]=0;auto legacy=frame(.7);check(std::abs(legacy[0]-.7)<.000001,"hybrid appearance retained");
 printf("{\"passed\":%s,\"failures\":%d,\"sunSrgb\":%.8f,\"sunReference\":%.8f,\"bakedColorDifference\":%.8f,\"nightRadiance\":%.8f,\"emissionSrgb\":%.8f,\"skyLinear\":[%.8f,%.8f,%.8f],\"redBounceLinear\":%.8f,\"blueBounceLinear\":%.8f,\"giOff\":%.8f,\"hybridSrgb\":%.8f}\n",failures?"false":"true",failures,sunDark[0],expected,std::abs(sunDark[0]-sunBright[0]),night[0],emission[0],sky[0],sky[1],sky[2],bounced[0][0],bounced[1][2],giOff[0],legacy[0]);rt_destroy(ctx);return failures?1:0;
}}
