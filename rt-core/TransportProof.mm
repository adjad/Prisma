// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "RtCore.h"
#include <vector>
#include <cstdio>
#include <cmath>
#include <algorithm>
#include <limits>
#include <string>
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
int main(int argc,const char **argv){@autoreleasepool{
    auto device=MTLCreateSystemDefaultDevice();NSString *shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];
    char error[4096];auto ctx=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));
    if(!ctx){fprintf(stderr,"%s\n",error);return 1;}
    bool capture=argc==3&&std::string(argv[1])=="--capture";
    if(argc!=1&&!capture){fprintf(stderr,"Usage: transport-proof [--capture path]\n");return 1;}
    if(capture){
        auto desc=[MTLCaptureDescriptor new];desc.captureObject=device;desc.destination=MTLCaptureDestinationGPUTraceDocument;desc.outputURL=[NSURL fileURLWithPath:@(argv[2])];
        NSError *captureError=nil;if(![[MTLCaptureManager sharedCaptureManager] startCaptureWithDescriptor:desc error:&captureError]){fprintf(stderr,"%s\n",captureError.localizedDescription.UTF8String);return 1;}
    }
    RtFrameParameters p={};p.sun[0]=-.70710678;p.sun[1]=.70710678;p.controls[1]=.003;
    p.transport[0]=p.transport[1]=1;p.transport[2]=3.14159265;p.transport[3]=32;p.dimensions[2]=19;
    RtRay primary={{0,2,0,.001},{0,-1,0,20}};RtTransport output={};int errors=0;
    // The red emitter is behind the camera (y=3); a down-facing primary ray cannot see it.
    Fixture mirror;mirror.quad({-10,0,-10},{-10,0,10},{10,0,10},{10,0,-10},0xffffffff,.001,1);
    mirror.quad({-10,3,-10},{10,3,-10},{10,3,10},{-10,3,10},0xffff0000,.85,0,1);
    if(!mirror.upload(ctx)||!rt_transport(ctx,&primary,&output,1,&p,1024)){fprintf(stderr,"%s\n",rt_error(ctx));return 1;}
    float mirrorRed=output.reflection[0],mirrorGreen=output.reflection[1];
    bool offscreen=mirrorRed>.99&&mirrorGreen<.001&&output.reflection[2]<.001;errors+=!offscreen;
    // Barycentric UV interpolation must select different texels of the off-screen sprite.
    Fixture textured=mirror;textured.texels.push_back(0xff0000ff);
    for(int i=2;i<4;i++){auto &m=textured.materials[i];m.image[1]=2;m.uv01[0]=m.uv01[1]=0;m.uv01[2]=1;m.uv01[3]=i==2?0:1;m.uv2[0]=i==2?1:0;m.uv2[1]=1;}
    RtRay pair[2]={{{-4,2,0,.001},{0,-1,0,20}},{{4,2,0,.001},{0,-1,0,20}}};RtTransport pairOut[2];
    if(!textured.upload(ctx)||!rt_transport(ctx,pair,pairOut,2,&p,128))return 1;
    bool uv=pairOut[0].reflection[0]>.99&&pairOut[0].reflection[2]<.001&&pairOut[1].reflection[2]>.99&&pairOut[1].reflection[0]<.001;errors+=!uv;
    // Roughness broadens a tiny reflected emitter, reducing its peak at the mirror direction.
    Fixture gloss;gloss.quad({-10,0,-10},{-10,0,10},{10,0,10},{10,0,-10},0xffffffff,.001,1);
    gloss.quad({-.2f,3,-.2f},{.2f,3,-.2f},{.2f,3,.2f},{-.2f,3,.2f},0xffff0000,.85,0,1);
    if(!gloss.upload(ctx)||!rt_transport(ctx,&primary,&output,1,&p,4096))return 1;float sharp=output.reflection[0];
    gloss.materials[0].surface[0]=gloss.materials[1].surface[0]=.8;
    if(!gloss.upload(ctx)||!rt_transport(ctx,&primary,&output,1,&p,4096))return 1;float rough=output.reflection[0];
    bool roughness=sharp>.95&&rough<sharp*.25&&rough>=0;errors+=!roughness;
    // A fully transparent alpha-tested layer must not hide that emitter from secondary rays.
    mirror.quad({-10,2.5,-10},{10,2.5,-10},{10,2.5,10},{-10,2.5,10},0x0000ff00,.85,0,0,true);
    if(!mirror.upload(ctx)||!rt_transport(ctx,&primary,&output,1,&p,1024))return 1;
    bool alpha=std::abs(output.reflection[0]-mirrorRed)<.001&&output.reflection[1]<.001;errors+=!alpha;
    auto before=output;auto bad=mirror.materials;bad[0].image[0]=uint32_t(mirror.texels.size());
    auto epoch=rt_scene_epoch(ctx);bool rejected=!rt_set_materials(ctx,bad.data(),uint32_t(bad.size()),mirror.texels.data(),uint32_t(mirror.texels.size()));
    if(!rt_transport(ctx,&primary,&output,1,&p,1024))return 1;
    bool atomic=rejected&&epoch==rt_scene_epoch(ctx)&&std::abs(output.reflection[0]-before.reflection[0])<1e-6;errors+=!atomic;
    // A sunlit colored wall (no emission) changes the neutral floor's bounced color.
    float gi[2][3];
    for(int color=0;color<2;color++){
        Fixture room;room.quad({-10,0,-10},{-10,0,10},{10,0,10},{10,0,-10},0xffffffff);
        room.quad({1,0,-6},{1,6,-6},{1,6,6},{1,0,6},color?0xff0000ff:0xffff0000);
        if(!room.upload(ctx)||!rt_transport(ctx,&primary,&output,1,&p,4096))return 1;
        for(int k=0;k<3;k++)gi[color][k]=output.indirect[k];
    }
    bool bleeding=gi[0][0]>.1&&gi[0][1]<.0001&&gi[0][2]<.0001&&gi[1][2]>.1&&gi[1][0]<.0001&&std::abs(gi[0][0]-gi[1][2])<1e-5;errors+=!bleeding;
    // A second diffuse segment adds indirect light via the floor and colored wall.
    p.dimensions[3]=2u<<8;
    if(!rt_transport(ctx,&primary,&output,1,&p,4096))return 1;
    float twoBounceBlue=output.indirect[2];bool twoBounce=twoBounceBlue>gi[1][2]*1.05f&&output.indirect[0]<.0001f;
    errors+=!twoBounce;p.dimensions[3]=0;
    // Zero new-effect strengths produce no reflected or bounced radiance.
    p.transport[0]=p.transport[1]=0;if(!rt_transport(ctx,&primary,&output,1,&p,64))return 1;
    bool disabled=true;for(int i=0;i<3;i++)disabled&=output.reflection[i]==0&&output.indirect[i]==0;errors+=!disabled;
    if(capture)[[MTLCaptureManager sharedCaptureManager] stopCapture];
    NSDictionary *report=@{@"passed":@(errors==0),@"failures":@(errors),@"device":device.name,@"offscreenReflection":@(offscreen),@"mirrorRed":@(mirrorRed),@"mirrorGreen":@(mirrorGreen),@"alphaCutoutRejected":@(alpha),@"barycentricTextureSampling":@(uv),@"roughnessBroadensReflection":@(roughness),@"sharpReflectionRed":@(sharp),@"roughReflectionRed":@(rough),@"invalidMaterialsPreserveScene":@(atomic),@"sunlitWallColorBleeding":@(bleeding),@"redWallIndirectRGB":@[@(gi[0][0]),@(gi[0][1]),@(gi[0][2])],@"blueWallIndirectRGB":@[@(gi[1][0]),@(gi[1][1]),@(gi[1][2])],@"zeroStrengths":@(disabled),@"twoBounceTransport":@(twoBounce),@"twoBounceBlue":@(twoBounceBlue),@"minecraftIntegration":@NO,@"gpuCaptureWritten":@(capture)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");rt_destroy(ctx);return errors?1:0;
}}
