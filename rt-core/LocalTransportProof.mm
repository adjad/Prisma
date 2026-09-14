// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "RtCore.h"
#include <vector>
#include <cmath>
#include <cstdio>
#include <cstring>
struct Fixture {
    std::vector<RtVertex> vertices;std::vector<RtMaterial> materials;std::vector<uint32_t> texels;
    void quad(RtVertex a,RtVertex b,RtVertex c,RtVertex d,uint32_t color,float roughness=.85,float metallic=0,float emission=0,bool cutout=false){
        RtMaterial m={};m.tint[0]=m.tint[1]=m.tint[2]=m.tint[3]=1;m.surface[0]=roughness;m.surface[1]=metallic;m.surface[2]=emission;
        m.optics[0]=1.5;m.optics[1]=.5;m.optics[2]=1;m.image[0]=uint32_t(texels.size());m.image[1]=m.image[2]=1;m.image[3]=cutout?1:0;
        texels.push_back(color);
        for(auto p:{a,b,c,a,c,d})vertices.push_back(p);
        materials.push_back(m);materials.push_back(m);
    }
    bool upload(RtContext *ctx){return rt_build_triangles(ctx,vertices.data(),uint32_t(vertices.size()))&&rt_set_materials(ctx,materials.data(),uint32_t(materials.size()),texels.data(),uint32_t(texels.size()));}
};
int main(int argc,char **argv){@autoreleasepool{
 auto device=MTLCreateSystemDefaultDevice();auto manager=[MTLCaptureManager sharedCaptureManager];bool capture=argc==3&&strcmp(argv[1],"--capture")==0;
 if(capture){auto request=[MTLCaptureDescriptor new];request.captureObject=device;request.destination=MTLCaptureDestinationGPUTraceDocument;request.outputURL=[NSURL fileURLWithPath:@(argv[2])];NSError *error=nil;if(![manager startCaptureWithDescriptor:request error:&error]){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 1;}}
 auto shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];char error[4096];auto ctx=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));if(!ctx){fprintf(stderr,"%s\n",error);return 1;}
 RtFrameParameters p={};p.sun[0]=1;p.controls[1]=.001;p.transport[0]=p.transport[1]=1;p.transport[3]=40;p.dimensions[2]=19;
 RtRay primary={{0,2,0,.001},{0,-1,0,20}};RtTransport out{};int failures=0;
 auto must=[&](bool v){if(!v){failures++;fprintf(stderr,"check failed: %s\n",rt_error(ctx));}return v;};
 auto trace=[&](){return must(rt_transport(ctx,&primary,&out,1,&p,4096));};
 Fixture room;room.quad({-10,0,-10},{-10,0,10},{10,0,10},{10,0,-10},0xffffffff,.001,1);
 room.quad({-10,3,-10},{10,3,-10},{10,3,10},{-10,3,10},0xffff0000);
 must(room.upload(ctx));trace();float dark=out.reflection[0];
 RtAreaLight lamp={{2,1.5,0,0},{.5,0,0,0},{0,0,-.5,0},{8,8,8,0}};
 must(rt_set_area_lights(ctx,&lamp,1));trace();float reflected=out.reflection[0];
 RtLightReceiver wall={{0,3,0,0},{0,-1,0,0}};RtIrradiance irradiance{};must(rt_local_lighting(ctx,&wall,&irradiance,1,4096,19,.001));
 double expected=irradiance.rgb[0]/3.141592653589793;bool reflection=dark==0&&reflected>.01&&std::abs(reflected-expected)/expected<.025&&out.reflection[1]==0&&out.reflection[2]==0;must(reflection);
 Fixture blocked=room;blocked.quad({.5,2.25,-1},{1.5,2.25,-1},{1.5,2.25,1},{.5,2.25,1},0xff000000);
 must(blocked.upload(ctx));trace();float shadow=out.reflection[0];must(shadow<reflected*.01);
 float gi[2];
 for(int color=0;color<2;color++){
  Fixture bounce;bounce.quad({-10,0,-10},{-10,0,10},{10,0,10},{10,0,-10},0xffffffff);
  bounce.quad({-10,3,-10},{10,3,-10},{10,3,10},{-10,3,10},color?0xff0000ff:0xffff0000);
  must(bounce.upload(ctx));p.transport[0]=0;trace();gi[color]=out.indirect[color?2:0];must(gi[color]>.005&&out.indirect[color?0:2]==0&&out.indirect[1]==0);
 }
 must(rt_set_area_lights(ctx,nullptr,0));trace();bool lampOff=out.indirect[0]==0&&out.indirect[1]==0&&out.indirect[2]==0;must(lampOff);
 // The emitter exists both as geometry and an explicit light. Direct diffuse
 // emission belongs to NEE, while mirror paths must retain visible emission.
 Fixture emitter;emitter.quad({-10,0,-10},{-10,0,10},{10,0,10},{10,0,-10},0xffffffff);
 emitter.quad({-10,3,-10},{10,3,-10},{10,3,10},{-10,3,10},0xffffffff,.001,1,1);
 RtAreaLight ceiling={{0,3,0,0},{10,0,0,0},{0,0,10,0},{1,1,1,0}};
 must(emitter.upload(ctx));trace();float bsdfEmission=out.indirect[0];must(bsdfEmission>.9);
 must(rt_set_area_lights(ctx,&ceiling,1));trace();float partitioned=out.indirect[0];bool partition=partitioned==0;must(partition);
 p.dimensions[3]=2u<<8;trace();bool twoPartition=out.indirect[0]==0;must(twoPartition);p.dimensions[3]=0;
 for(int i=0;i<2;i++)emitter.materials[i].surface[0]=.001,emitter.materials[i].surface[1]=1;
 must(emitter.upload(ctx));p.transport[0]=1;trace();bool mirrorEmission=out.reflection[0]>.99;must(mirrorEmission);
 // Transmission must show lamp-lit diffuse surfaces with GI disabled.
 Fixture glass;glass.quad({-10,0,-10},{-10,0,10},{10,0,10},{10,0,-10},0xffff0000);
 glass.quad({-10,1,-10},{-10,1,10},{10,1,10},{10,1,-10},0xffffffff,.001);
 for(int i=2;i<4;i++)glass.materials[i].surface[3]=.98;
 RtAreaLight down={{2,.5,0,0},{.5,0,0,0},{0,0,.5,0},{8,8,8,0}};
 must(glass.upload(ctx));must(rt_set_area_lights(ctx,&down,1));p.transport[1]=0;trace();float transmitted=out.reflection[0];bool transmission=transmitted>.005&&out.reflection[1]==0&&out.reflection[2]==0;must(transmission);
 must(rt_set_area_lights(ctx,nullptr,0));trace();bool transmissionOff=out.reflection[0]==0;must(transmissionOff);
 if(capture)[manager stopCapture];
 auto report=@{@"gpuCaptureWritten":@(capture),@"passed":@(failures==0),@"failures":@(failures),@"lampLitWallReflection":@(reflection),@"reflectedRed":@(reflected),@"irradianceOverPiReference":@(expected),@"blockedReflection":@(shadow),@"redWallIndirect":@(gi[0]),@"blueWallIndirect":@(gi[1]),@"lampRemovalClearsIndirect":@(lampOff),@"unpartitionedBsdfEmission":@(bsdfEmission),@"partitionedImmediateEmission":@(partitioned),@"twoBounceEmissionPartition":@(twoPartition),@"mirrorEmitterRetained":@(mirrorEmission),@"transmittedLocalLightWithGiOff":@(transmitted),@"transmissionLampRemoval":@(transmissionOff)};
 auto json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");rt_destroy(ctx);return failures?1:0;
}}
