// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "RtCore.h"
#include <vector>
#include <cmath>
#include <cstdio>
#include <algorithm>
#include <limits>
#include <cstring>
static void quad(std::vector<RtVertex>&v,RtVertex a,RtVertex b,RtVertex c,RtVertex d){for(auto p:{a,b,c,a,c,d})v.push_back(p);}
static bool scene(RtContext *c,float blockerY,bool behind=false){
    std::vector<RtVertex> v;quad(v,{-30,0,-30},{-30,0,30},{30,0,30},{30,0,-30});
    if(blockerY>0)quad(v,{-20,blockerY,-20},{0,blockerY,-20},{0,blockerY,20},{-20,blockerY,20});
    if(behind)quad(v,{-20,9,-20},{20,9,-20},{20,9,20},{-20,9,20});
    return rt_build_triangles(c,v.data(),uint32_t(v.size()));
}
static RtAreaLight light(float height=8,float halfWidth=1){return {{0,height,0,0},{halfWidth,0,0,0},{0,0,halfWidth,0},{4,2,1,0}};}
// Independent deterministic area quadrature with an analytic half-plane blocker.
static double reference(double x,double height,double a,double blocker){
    constexpr int n=128;double sum=0;
    for(int u=0;u<n;u++)for(int v=0;v<n;v++){
        double lx=-a+(u+.5)*2*a/n,lz=-a+(v+.5)*2*a/n;
        if(blocker>0&&x+(lx-x)*blocker/height<0)continue;
        double d2=(lx-x)*(lx-x)+height*height+lz*lz;
        sum+=height*height/(d2*d2);
    }
    return sum*4*a*a/(n*n); // Unit emitted radiance.
}
static double width(const std::vector<double>&visibility){
    double low=0,high=0;bool l=false,h=false;
    for(size_t i=1;i<visibility.size();i++){
        double x=-2+4.*i/(visibility.size()-1),previous=x-4./(visibility.size()-1);
        auto crossing=[&](double threshold){return previous+(x-previous)*(threshold-visibility[i-1])/(visibility[i]-visibility[i-1]);};
        if(!l&&visibility[i]>=.1&&visibility[i-1]<.1){low=crossing(.1);l=true;}
        if(!h&&visibility[i]>=.9&&visibility[i-1]<.9){high=crossing(.9);h=true;}
    }
    return l&&h?high-low:-1;
}
int main(int argc,char **argv){@autoreleasepool{
    auto device=MTLCreateSystemDefaultDevice();auto manager=[MTLCaptureManager sharedCaptureManager];bool capture=argc==3&&strcmp(argv[1],"--capture")==0;
    if(capture){auto request=[MTLCaptureDescriptor new];request.captureObject=device;request.destination=MTLCaptureDestinationGPUTraceDocument;request.outputURL=[NSURL fileURLWithPath:@(argv[2])];NSError *failure=nil;if(![manager startCaptureWithDescriptor:request error:&failure]){fprintf(stderr,"%s\n",failure.localizedDescription.UTF8String);return 1;}}
    auto source=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];char error[4096];
    auto c=rt_create((__bridge void*)device,source.UTF8String,error,sizeof(error));if(!c){fprintf(stderr,"%s\n",error);return 1;}
    unsigned failures=0;auto must=[&](bool ok){if(!ok){fprintf(stderr,"%s\n",rt_error(c));failures++;}return ok;};
    must(scene(c,0));auto l=light();must(rt_set_area_lights(c,&l,1));
    RtLightStatistics before{},after{};rt_light_statistics(c,&before);auto epoch=rt_scene_epoch(c);
    must(rt_set_area_lights(c,&l,1));rt_light_statistics(c,&after);bool unchanged=after.revision==before.revision;must(unchanged);
    RtLightReceiver center={{0,0,0,0},{0,1,0,0}};RtIrradiance out{};
    must(rt_local_lighting(c,&center,&out,1,4096,217,.001f));double expected=reference(0,8,1,0)*4;
    double relativeError=std::abs(out.rgb[0]-expected)/expected;
    bool color=std::abs(out.rgb[0]-2*out.rgb[1])<1e-6&&std::abs(out.rgb[1]-2*out.rgb[2])<1e-6;
    must(relativeError<.015&&color);
    bool invalidPreserved=true;
    for(int kind=0;kind<6;kind++){
        auto bad=l;if(kind==0)bad.center[0]=std::numeric_limits<float>::quiet_NaN();if(kind==1)bad.radiance[0]=-1;
        if(kind==2)bad.half_u[0]=0;if(kind==3)bad.half_v[0]=.5f;if(kind==4)bad.half_v[3]=2;if(kind==5)bad.radiance[3]=1;
        invalidPreserved&=!rt_set_area_lights(c,&bad,1);rt_light_statistics(c,&after);invalidPreserved&=after.revision==before.revision&&after.count==1;
    }
    invalidPreserved&=!rt_set_area_lights(c,nullptr,1)&&!rt_set_area_lights(c,&l,8193);must(invalidPreserved);
    RtIrradiance afterInvalid{};must(rt_local_lighting(c,&center,&afterInvalid,1,4096,217,.001f));must(afterInvalid.rgb[0]==out.rgb[0]);
    // Far-field energy, with fixed physical area and radiance.
    double farValues[2];for(int i=0;i<2;i++){auto far=light(float(16*(i+1)));must(rt_set_area_lights(c,&far,1));must(rt_local_lighting(c,&center,&out,1,4096,217,.001f));farValues[i]=out.rgb[0];}
    double falloff=farValues[0]/farValues[1];must(falloff>3.95&&falloff<4.01);
    // The back of a one-sided emitter is black; two-sided emits equally there.
    must(rt_set_area_lights(c,&l,1));RtLightReceiver back={{0,16,0,0},{0,-1,0,0}};
    must(rt_local_lighting(c,&back,&out,1,4096,217,.001f));bool sided=out.rgb[0]==0;
    auto two=l;two.half_v[3]=1;must(rt_set_area_lights(c,&two,1));must(rt_local_lighting(c,&back,&out,1,4096,217,.001f));sided&=std::abs(out.rgb[0]-expected)/expected<.015;must(sided);
    // Two identical emitters must sum, including the discrete light-selection PDF.
    RtAreaLight pair[]={l,l};must(rt_set_area_lights(c,pair,2));must(rt_local_lighting(c,&center,&out,1,4096,217,.001f));bool selection=std::abs(out.rgb[0]/expected-2)<.03;must(selection);
    bool noGeometryUpdate=rt_scene_epoch(c)==epoch;must(noGeometryUpdate);
    must(rt_set_area_lights(c,&l,1));must(scene(c,0,true));must(rt_local_lighting(c,&center,&out,1,4096,217,.001f));bool finiteSegment=std::abs(out.rgb[0]-expected)/expected<.015;must(finiteSegment);
    // The local-light visibility path shares alpha rejection and dielectric filtering.
    std::vector<RtVertex> filteredGeometry;
    quad(filteredGeometry,{-30,0,-30},{-30,0,30},{30,0,30},{30,0,-30});
    quad(filteredGeometry,{-20,4,-20},{20,4,-20},{20,4,20},{-20,4,20});
    must(rt_build_triangles(c,filteredGeometry.data(),unsigned(filteredGeometry.size())));
    std::vector<RtMaterial> filterMaterials(4);
    for(auto &m:filterMaterials){for(float &t:m.tint)t=1;m.surface[0]=.85;m.optics[0]=1.5;m.optics[2]=1;m.image[1]=m.image[2]=1;}
    uint32_t filterTexels[]={0xffffffff,0x00ffffff};
    for(int i=2;i<4;i++){filterMaterials[i].image[0]=1;filterMaterials[i].image[3]=1;filterMaterials[i].optics[1]=.5;}
    must(rt_set_materials(c,filterMaterials.data(),4,filterTexels,2));must(rt_local_lighting(c,&center,&out,1,4096,217,.001f));
    bool cutout=std::abs(out.rgb[0]-expected)/expected<.015;must(cutout);
    for(int i=2;i<4;i++){filterMaterials[i].image[3]=0;filterMaterials[i].image[0]=0;filterMaterials[i].surface[3]=.98;}
    must(rt_set_materials(c,filterMaterials.data(),4,filterTexels,2));must(rt_local_lighting(c,&center,&out,1,4096,217,.001f));
    double dielectricRatio=out.rgb[0]/expected;bool dielectric=dielectricRatio>.90&&dielectricRatio<.97;must(dielectric);
    for(int i=2;i<4;i++)filterMaterials[i].surface[3]=0;
    must(rt_set_materials(c,filterMaterials.data(),4,filterTexels,2));must(rt_local_lighting(c,&center,&out,1,4096,217,.001f));
    bool opaque=out.rgb[0]==0;must(opaque);
    // Quantitative penumbrae across independent blocker distances and emitter size.
    NSMutableArray *profiles=[NSMutableArray array];double gpuWidths[3]={};
    for(int trial=0;trial<3;trial++){
        float blocker=trial==0?1:3,a=trial==2?.5f:1;
        must(scene(c,blocker));auto emitter=light(8,a);must(rt_set_area_lights(c,&emitter,1));
        constexpr int count=201;std::vector<RtLightReceiver> receivers(count);std::vector<RtIrradiance> output(count);std::vector<double> gpu(count),cpu(count);double maximumError=0;
        for(int i=0;i<count;i++)receivers[i]={{float(-2+4.*i/(count-1)),0,0,0},{0,1,0,0}};
        must(rt_local_lighting(c,receivers.data(),output.data(),count,4096,20260914,.001f));
        for(int i=0;i<count;i++){
            double x=receivers[i].position[0],unblocked=reference(x,8,a,0);
            gpu[i]=output[i].rgb[0]/(4*unblocked);cpu[i]=reference(x,8,a,blocker)/unblocked;
            maximumError=std::max(maximumError,std::abs(gpu[i]-cpu[i]));
        }
        gpuWidths[trial]=width(gpu);double cpuWidth=width(cpu);
        bool valid=maximumError<.04&&gpuWidths[trial]>0&&std::abs(gpuWidths[trial]-cpuWidth)<.04;
        must(valid);
        NSMutableArray *points=[NSMutableArray array];for(int i=0;i<count;i++)[points addObject:@[@(receivers[i].position[0]),@(gpu[i]),@(cpu[i])]];
        [profiles addObject:@{@"points":points,@"blockerHeight":@(blocker),@"emitterHalfWidth":@(a),@"gpuPenumbra10To90":@(gpuWidths[trial]),@"cpuPenumbra10To90":@(cpuWidth),@"maxNormalizedIrradianceError":@(maximumError),@"passed":@(valid)}];
    }
    bool scaling=gpuWidths[1]>gpuWidths[0]*3&&gpuWidths[2]<gpuWidths[1]*.6&&gpuWidths[2]>gpuWidths[1]*.4;must(scaling);
    must(rt_set_area_lights(c,nullptr,0));must(rt_local_lighting(c,&center,&out,1,1,0,.001f));bool removed=out.rgb[0]==0&&out.rgb[1]==0&&out.rgb[2]==0;must(removed);
    if(capture)[manager stopCapture];
    NSDictionary *report=@{@"passed":@(failures==0),@"failures":@(failures),@"unoccludedRelativeError":@(relativeError),@"radianceColorPreserved":@(color),@"unchangedPublicationReused":@(unchanged),@"invalidLightsPreserveState":@(invalidPreserved),@"initialGeometryEpoch":@(epoch),@"lightChangesPreserveGeometryEpoch":@(noGeometryUpdate),@"gpuCaptureWritten":@(capture),@"farFieldFalloffRatio":@(falloff),@"oneAndTwoSidedEmission":@(sided),@"multipleLightsSum":@(selection),@"finiteVisibilitySegment":@(finiteSegment),@"cutoutVisibility":@(cutout),@"opaqueVisibility":@(opaque),@"dielectricVisibility":@(dielectric),@"dielectricTransmissionRatio":@(dielectricRatio),@"penumbraProfiles":profiles,@"contactHardeningAndEmitterSize":@(scaling),@"removal":@(removed),@"minecraftIntegration":@NO};
    auto data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);puts("");rt_destroy(c);return failures?1:0;
}}
