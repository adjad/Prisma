// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "RtCore.h"
#include <vector>
#include <cstdio>
#include <cmath>
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
int main(){@autoreleasepool{
 auto device=MTLCreateSystemDefaultDevice();auto shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];char error[4096];
 auto c=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));if(!c){fprintf(stderr,"%s\n",error);return 1;}
 Fixture f;f.quad({-10,0,-10},{-10,0,10},{10,0,10},{10,0,-10},0xffffffff);
 f.quad({-10,2.5,-10},{-10,2.5,10},{10,2.5,10},{10,2.5,-10},0x00ffffff,.001);
 f.quad({-10,1.5,-10},{10,1.5,-10},{10,1.5,10},{-10,1.5,10},0x00ffffff,.001);
 for(int i=2;i<6;i++)f.materials[i].surface[3]=1;
 // This red emitter is invisible to the primary ray and below the glass slab.
 f.quad({1,0,-6},{1,1.4,-6},{1,1.4,6},{1,0,6},0xffff0000,.85,0,1);
 RtFrameParameters p={};p.sun[0]=1;p.controls[1]=.001;p.transport[0]=p.transport[1]=1;p.transport[3]=32;p.dimensions[2]=137;
 RtRay ray={{0,3,0,.001},{0,-1,0,20}};RtTransport before={},after={};
 if(!f.upload(c))return 1;p.dimensions[3]=4;
 if(!rt_transport(c,&ray,&before,1,&p,4096))return 1;p.dimensions[3]=0;
 if(!rt_transport(c,&ray,&after,1,&p,4096))return 1;
 bool red=before.reflection[0]<.0001&&after.reflection[0]>.1&&after.reflection[1]<.0001&&after.reflection[2]<.0001;
 float redGi=after.reflection[0];
 // Remove the wall; an unoccluded hemisphere receives environment light.
 f.vertices.resize(18);f.materials.resize(6);if(!f.upload(c))return 1;p.sun[0]=0;p.sun[1]=1;
 p.dimensions[3]=4;if(!rt_transport(c,&ray,&before,1,&p,4096))return 1;
 p.dimensions[3]=0;if(!rt_transport(c,&ray,&after,1,&p,4096))return 1;
 bool environment=after.reflection[2]>before.reflection[2]+.05&&after.reflection[0]>before.reflection[0]+.02;
 // A closed black room must not acquire an arbitrary ambient floor.
 // The primary ray retains a clear aperture to the white floor; only its indirect hemisphere is blocked.
 for(auto xs:{std::pair<float,float>{-10,-.05f},{.05f,10}})f.quad({xs.first,1.4,-10},{xs.second,1.4,-10},{xs.second,1.4,10},{xs.first,1.4,10},0xff000000);
 for(auto zs:{std::pair<float,float>{-10,-.05f},{.05f,10}})f.quad({-.05f,1.4,zs.first},{.05f,1.4,zs.first},{.05f,1.4,zs.second},{-.05f,1.4,zs.second},0xff000000);
 for(float x:{-10.f,10.f})f.quad({x,0,-10},{x,1.4,-10},{x,1.4,10},{x,0,10},0xff000000);
 for(float z:{-10.f,10.f})f.quad({-10,0,z},{10,0,z},{10,1.4,z},{-10,1.4,z},0xff000000);
 if(!f.upload(c)||!rt_transport(c,&ray,&after,1,&p,4096))return 1;
 bool occlusion=std::abs(after.reflection[0]-before.reflection[0])<.003&&std::abs(after.reflection[2]-before.reflection[2])<.003;
 auto report=@{@"passed":@(red&&environment&&occlusion),@"indirectRedThroughGlass":@(redGi),@"coloredBounceThroughGlass":@(red),@"visibleEnvironmentLighting":@(environment),@"blackOccluderPreventsAmbientLeak":@(occlusion)};
 auto data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);puts("");rt_destroy(c);return red&&environment&&occlusion?0:1;
}}
