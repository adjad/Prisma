// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "RtCore.h"
#include <vector>
#include <cmath>
#include <cstdio>
struct Fixture {
    std::vector<RtVertex> vertices;std::vector<RtMaterial> materials;std::vector<uint32_t> texels;
    void plane(float z,bool front,float transmission=0,float ior=1.5,uint32_t color=0x00ffffff,float emission=0,float xmin=-10,float xmax=10){
        RtMaterial m={};for(int i=0;i<4;i++)m.tint[i]=1;m.surface[0]=.001;m.surface[2]=emission;m.surface[3]=transmission;
        m.optics[0]=ior;m.optics[2]=1;m.image[0]=uint32_t(texels.size());m.image[1]=m.image[2]=1;
        texels.push_back(color);
        RtVertex a={xmin,-10,z},b={xmax,-10,z},c={xmax,10,z},d={xmin,10,z};
        if(front){for(auto p:{a,b,c,a,c,d})vertices.push_back(p);}else{for(auto p:{a,d,c,a,c,b})vertices.push_back(p);}
        materials.push_back(m);materials.push_back(m);
    }
    bool upload(RtContext*c){return rt_build_triangles(c,vertices.data(),uint32_t(vertices.size()))&&rt_set_materials(c,materials.data(),uint32_t(materials.size()),texels.data(),uint32_t(texels.size()));}
};
int main(){@autoreleasepool{
    auto device=MTLCreateSystemDefaultDevice();auto shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];
    char error[4096];auto c=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));if(!c){fprintf(stderr,"%s\n",error);return 1;}
    RtFrameParameters p={};p.sun[0]=1;p.controls[1]=.0005;p.transport[0]=1;p.transport[3]=32;p.dimensions[2]=37;
    RtRay ray={{0,0,2,.001},{0,0,-1,20}};RtTransport out={};int failures=0;
    auto run=[&](Fixture&f){bool ok=f.upload(c)&&rt_transport(c,&ray,&out,1,&p,1024);if(!ok)fprintf(stderr,"%s\n",rt_error(c));return ok;};
    Fixture glass;glass.plane(1,true,1);glass.plane(0,false,1);glass.plane(-1,true,0,1.5,0xffff0000,1);
    if(!run(glass))return 1;float normalRed=out.reflection[0];bool normal=std::abs(normalRed-.9216f)<.001&&out.reflection[1]<.0001;failures+=!normal;
    Fixture water=glass;for(int i=0;i<4;i++)water.materials[i].optics[0]=1.333;
    if(!run(water))return 1;float waterRed=out.reflection[0];float wf=std::pow((1.333f-1)/(1.333f+1),2);bool waterIndex=std::abs(waterRed-(1-wf)*(1-wf))<.001&&waterRed>normalRed;failures+=!waterIndex;
    Fixture tinted=glass;tinted.texels[0]=tinted.texels[1]=0xff0000ff;
    if(!run(tinted))return 1;float tintedRed=out.reflection[0];bool tint=std::abs(tintedRed-.9216f*.64f)<.001;failures+=!tint;
    Fixture volume=glass;volume.texels[0]=volume.texels[1]=0xff0000ff;for(int i=0;i<4;i++)volume.materials[i].optics[3]=.4;
    if(!run(volume))return 1;float depthOne=out.reflection[0];
    Fixture deep=volume;for(int i=6;i<12;i++)deep.vertices[i].z=-1;for(int i=12;i<18;i++)deep.vertices[i].z=-2;
    if(!run(deep))return 1;float depthTwo=out.reflection[0];
    bool absorption=std::abs(depthOne-.9216f*std::exp(-.4f))<.001&&std::abs(depthTwo/depthOne-std::exp(-.4f))<.001;failures+=!absorption;
    // Snell refraction shifts the emerging ray to x=1.9364 at z=-1; an unrefracted ray reaches x=2.25.
    Fixture angled;angled.plane(1,true,1);angled.plane(0,false,1);angled.plane(-1,true,0,1.5,0xffff0000,1,1.90,1.98);
    ray.direction[0]=.6;ray.direction[2]=-.8;
    if(!run(angled))return 1;float angledRed=out.reflection[0];bool snell=angledRed>.85&&out.reflection[1]<.0001;failures+=!snell;
    Fixture internal;internal.plane(1,true,1);internal.plane(0,false,1);internal.plane(.1,true,0,1.5,0xffff0000,1,1.2,2.5);
    ray.origin[2]=.5;ray.direction[0]=.8;ray.direction[2]=.6;
    if(!run(internal))return 1;float tirRed=out.reflection[0];bool tir=tirRed>.99;failures+=!tir;
    RtVisibilitySettings settings={{0,0,1,0},2,.0005,64,19};RtVisibility visibility={};
    ray={{0,0,.5,.001},{0,0,-1,20}};
    Fixture shade;shade.plane(0,true,0,1.5,0xffffffff);shade.plane(2,true,1);shade.plane(1,false,1);
    if(!shade.upload(c)||!rt_visibility(c,&ray,&visibility,1,&settings))return 1;
    float clearShadow=visibility.sun_visibility;bool shadows=std::abs(clearShadow-.9216f)<.001;failures+=!shadows;
    settings.sun_direction[0]=.8;settings.sun_direction[2]=.6;
    if(!rt_visibility(c,&ray,&visibility,1,&settings))return 1;
    float obliqueShadow=visibility.sun_visibility;
    float ci=.6f,ct=std::sqrt(1-(1-ci*ci)/2.25f);
    float rs=(ci-1.5f*ct)/(ci+1.5f*ct),rp=(1.5f*ci-ct)/(1.5f*ci+ct),fresnel=(rs*rs+rp*rp)*.5f;
    bool oblique=std::abs(obliqueShadow-(1-fresnel)*(1-fresnel))<.001f;failures+=!oblique;
    settings.sun_direction[0]=0;settings.sun_direction[2]=1;
    for(int i=2;i<6;i++)shade.materials[i].surface[3]=0;
    if(!shade.upload(c)||!rt_visibility(c,&ray,&visibility,1,&settings))return 1;
    bool opaque=visibility.sun_visibility==0;failures+=!opaque;
    for(int i=2;i<6;i++){shade.materials[i].image[3]=1;shade.materials[i].optics[1]=.5;}
    if(!shade.upload(c)||!rt_visibility(c,&ray,&visibility,1,&settings))return 1;
    bool cutout=visibility.sun_visibility==1;failures+=!cutout;
    for(int i=2;i<6;i++){shade.materials[i].image[3]=0;shade.materials[i].surface[3]=1;}
    shade.plane(3,true,0,1.5,0xffffffff);
    if(!shade.upload(c)||!rt_visibility(c,&ray,&visibility,1,&settings))return 1;
    bool behind=visibility.sun_visibility==0;failures+=!behind;
    Fixture layers;layers.plane(0,true,0,1.5,0xffffffff);for(int i=0;i<40;i++)layers.plane(1+i*.1,false,1,1);
    if(!layers.upload(c)||!rt_visibility(c,&ray,&visibility,1,&settings))return 1;
    bool bounded=visibility.sun_visibility==0;failures+=!bounded;
    NSDictionary *report=@{@"passed":@(failures==0),@"failures":@(failures),@"device":device.name,@"normalGlassRed":@(normalRed),@"normalFresnelTransmission":@(normal),@"waterIOR":@(waterIndex),@"waterRed":@(waterRed),@"tintedBoundaryFilter":@(tint),@"tintedRed":@(tintedRed),@"snellRefractionHitsDisplacedEmitter":@(snell),@"angledRed":@(angledRed),@"totalInternalReflection":@(tir),@"tirRed":@(tirRed),@"clearGlassSunVisibility":@(clearShadow),@"glassShadowTransmission":@(shadows),@"obliqueVisibilityAvoidsFalseTIR":@(oblique),@"obliqueSunVisibility":@(obliqueShadow),@"opaqueBlocksLight":@(opaque),@"alphaCutoutStillPasses":@(cutout),@"opaqueBehindGlassBlocksLight":@(behind),@"layerBudgetConservative":@(bounded),@"nestedMediaSupported":@NO,@"beerLambertDepthTest":@(absorption),@"depthOneRed":@(depthOne),@"depthTwoRed":@(depthTwo),@"volumeAbsorptionSupported":@YES};
    auto data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);puts("");rt_destroy(c);return failures?1:0;
}}
