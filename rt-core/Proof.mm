// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "RtCore.h"
#include <vector>
#include <random>
#include <cmath>
#include <cstdio>
#include <algorithm>

struct V { double x,y,z; };
static V sub(V a,V b) { return {a.x-b.x,a.y-b.y,a.z-b.z}; }
static V cross(V a,V b) { return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}; }
static double dot(V a,V b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
static V vec(const RtVertex &v) { return {v.x,v.y,v.z}; }
static double reference(const RtRay &r,const RtVertex *v) {
    V o{r.origin[0],r.origin[1],r.origin[2]}, d{r.direction[0],r.direction[1],r.direction[2]};
    V a=vec(v[0]), e1=sub(vec(v[1]),a), e2=sub(vec(v[2]),a), p=cross(d,e2);
    double det=dot(e1,p); if(std::abs(det)<1e-10) return -1;
    V t=sub(o,a); double u=dot(t,p)/det; if(u < -1e-7 || u > 1+1e-7) return -1;
    V q=cross(t,e1); double w=dot(d,q)/det; if(w < -1e-7 || u+w > 1+1e-7) return -1;
    double distance=dot(e2,q)/det;
    return distance>=r.origin[3] && distance<=r.direction[3] ? distance : -1;
}
int main(int argc,char **argv) { @autoreleasepool {
    bool disabled=false;
    NSString *capturePath=nil;
    for(int i=1;i<argc;++i) {
        if(!strcmp(argv[i],"--disable-rt")) disabled=true;
        else if(!strcmp(argv[i],"--capture") && i+1<argc) capturePath=@(argv[++i]);
        else { fprintf(stderr,"usage: rt-proof [--disable-rt] [--capture path.gputrace]\n"); return 2; }
    }
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if(disabled || !device.supportsRaytracing) {
        printf("{\"status\":\"fallback-required\",\"reason\":\"%s\",\"hardwareRtActive\":false}\n",disabled?"disabled-by-setting":"unsupported-device");
        return 0;
    }
    NSError *error=nil;
    NSString *shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:&error];
    char message[4096]={0};
    RtContext *ctx=rt_create((__bridge void *)device,shader.UTF8String,message,sizeof(message));
    if(!ctx) { fprintf(stderr,"%s\n",message); return 1; }
    MTLCaptureManager *capture=[MTLCaptureManager sharedCaptureManager];
    bool capturing=false;
    if(capturePath) {
        MTLCaptureDescriptor *desc=[MTLCaptureDescriptor new];
        desc.captureObject=device; desc.destination=MTLCaptureDestinationGPUTraceDocument;
        desc.outputURL=[NSURL fileURLWithPath:capturePath];
        capturing=[capture startCaptureWithDescriptor:desc error:&error];
        if(!capturing) { fprintf(stderr,"Capture failed: %s\n",error.localizedDescription.UTF8String); rt_destroy(ctx); return 1; }
    }
    RtVertex vertices[]={{-1,-1,0},{1,-1,0},{1,1,0}, {-1,-1,0},{1,1,0},{-1,1,0}};
    if(!rt_build_triangles(ctx,vertices,6)) { fprintf(stderr,"%s\n",rt_error(ctx)); rt_destroy(ctx); return 1; }
    const double buildMs=rt_last_gpu_ms(ctx);
    std::vector<RtRay> rays={
        {{.5f,-.5f,2,0},{0,0,-1,10}}, // triangle 0
        {{-.5f,.5f,2,0},{0,0,-1,10}}, // triangle 1
        {{2,0,2,0},{0,0,-1,10}}, // miss
        {{0,0,2,0},{0,0,-1,10}}, // shared edge, either primitive
        {{.5f,-.5f,2,0},{0,0,-1,1.9f}}, // light in front of blocker
        {{.5f,-.5f,2,2.1f},{0,0,-1,10}}, // near interval excludes blocker
        {{0,0,2,0},{1,0,0,10}}, // parallel
        {{.5f,-.5f,-2,0},{0,0,1,10}} // two-sided back face
    };
    std::mt19937 rng(20260914);
    std::uniform_real_distribution<float> xy(-2,2), tilt(-.35f,.35f), height(.2f,5);
    for(int i=0;i<4096;++i) {
        float dx=tilt(rng),dy=tilt(rng),dz=-1, n=std::sqrt(dx*dx+dy*dy+dz*dz);
        rays.push_back({{xy(rng),xy(rng),height(rng),0},{dx/n,dy/n,dz/n,i%3==0?1.0f:10.0f}});
    }
    std::vector<RtHit> hits(rays.size());
    if(!rt_trace(ctx,rays.data(),hits.data(),uint32_t(rays.size()))) { fprintf(stderr,"%s\n",rt_error(ctx)); rt_destroy(ctx); return 1; }
    double traceMs=rt_last_gpu_ms(ctx), maxError=0;
    unsigned failures=0,expectedHits=0;
    for(size_t i=0;i<rays.size();++i) {
        double a=reference(rays[i],vertices),b=reference(rays[i],vertices+3);
        bool found=a>=0 || b>=0; expectedHits+=found;
        double t=a<0?b:(b<0?a:std::min(a,b));
        bool primitiveOK=hits[i].primitive<2 && (hits[i].primitive==0?a:b)>=0;
        if(found) maxError=std::max(maxError,std::abs(t-hits[i].distance));
        if(bool(hits[i].hit)!=found || (found && (!primitiveOK || std::abs(t-hits[i].distance)>2e-5)) || (!found && hits[i].primitive!=UINT32_MAX)) {
            if(failures<10) fprintf(stderr,"Ray %zu mismatch expected t=%g; hit=%u primitive=%u distance=%g\n",i,t,hits[i].hit,hits[i].primitive,hits[i].distance);
            ++failures;
        }
    }
    // Invalid updates cannot destroy the previously usable scene.
    uint64_t epoch=rt_scene_epoch(ctx);
    bool rejected=!rt_build_triangles(ctx,vertices,5) && rt_scene_epoch(ctx)==epoch;
    RtHit retry{};
    bool oldScene=rt_trace(ctx,rays.data(),&retry,1) && retry.hit && std::abs(retry.distance-2)<2e-5;
    RtRay invalid={ {0,0,2,0},{0,0,0,10} };
    bool invalidRayRejected=!rt_trace(ctx,&invalid,&retry,1);
    if(!rejected || !oldScene || !invalidRayRejected) ++failures;
    if(capturing) [capture stopCapture];
    NSDictionary *report=@{@"device":device.name,@"status":failures?@"failed":@"passed",@"rays":@(rays.size()),@"expectedHits":@(expectedHits),@"failures":@(failures),@"maxDistanceError":@(maxError),@"buildGpuMs":@(buildMs),@"traceGpuMs":@(traceMs),@"sceneEpoch":@(epoch),@"invalidUpdatePreservedScene":@(rejected&&oldScene),@"invalidRayRejected":@(invalidRayRejected),@"captureWritten":@(capturing),@"metalIntersectorExecuted":@YES,@"minecraftIntegration":@NO};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    rt_destroy(ctx);
    return failures?1:0;
} }
