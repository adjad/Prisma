// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include "RtCore.h"
#include <vector>
#include <cmath>
#include <cstdio>

static void quad(std::vector<RtVertex>&v,RtVertex a,RtVertex b,RtVertex c,RtVertex d){for(auto p:{a,b,c,a,c,d})v.push_back(p);}
static bool png(const char *path,const std::vector<RtVisibility>&values,int width,int height,bool ao) {
    std::vector<unsigned char> pixels(width*height*4);
    for(size_t i=0;i<values.size();i++) {
        unsigned char shade=(unsigned char)(255*std::max(0.f,std::min(1.f,ao?values[i].ambient_visibility:values[i].sun_visibility)));
        pixels[i*4]=pixels[i*4+1]=pixels[i*4+2]=shade;pixels[i*4+3]=255;
    }
    auto space=CGColorSpaceCreateDeviceRGB();
    auto provider=CGDataProviderCreateWithData(nullptr,pixels.data(),pixels.size(),nullptr);
    auto image=CGImageCreate(width,height,8,32,width*4,space,kCGImageAlphaLast,provider,nullptr,false,kCGRenderingIntentDefault);
    auto destination=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path)],CFSTR("public.png"),1,nullptr);
    bool ok=false;if(destination){CGImageDestinationAddImage(destination,image,nullptr);ok=CGImageDestinationFinalize(destination);CFRelease(destination);}
    CGImageRelease(image);CGDataProviderRelease(provider);CGColorSpaceRelease(space);return ok;
}
int main(){@autoreleasepool{
    NSString *shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];
    char error[4096];auto ctx=rt_create(nullptr,shader.UTF8String,error,sizeof(error));
    if(!ctx){fprintf(stderr,"%s\n",error);return 1;}
    std::vector<RtVertex> v;
    quad(v,{-4,0,-4},{-4,0,4},{4,0,4},{4,0,-4});
    // One opaque box; true side and top triangles, no analytical shadow approximation.
    quad(v,{-.5f,0,-.5f},{.5f,0,-.5f},{.5f,1,-.5f},{-.5f,1,-.5f});
    quad(v,{.5f,0,.5f},{-.5f,0,.5f},{-.5f,1,.5f},{.5f,1,.5f});
    quad(v,{-.5f,0,.5f},{-.5f,0,-.5f},{-.5f,1,-.5f},{-.5f,1,.5f});
    quad(v,{.5f,0,-.5f},{.5f,0,.5f},{.5f,1,.5f},{.5f,1,-.5f});
    quad(v,{-.5f,1,-.5f},{.5f,1,-.5f},{.5f,1,.5f},{-.5f,1,.5f});
    if(!rt_build_triangles(ctx,v.data(),uint32_t(v.size()))){fprintf(stderr,"%s\n",rt_error(ctx));return 1;}
    constexpr int width=256,height=256;
    std::vector<RtRay> rays;
    for(int y=0;y<height;y++)for(int x=0;x<width;x++)rays.push_back({{float(-3+(x+.5)*6/width),6,float(-3+(y+.5)*6/height),.001f},{0,-1,0,10}});
    RtVisibilitySettings settings={{-.6f,.8f,0,.04f},1.5f,.001f,64,20260914};
    std::vector<RtVisibility> values(rays.size());
    if(!rt_visibility(ctx,rays.data(),values.data(),uint32_t(rays.size()),&settings)){fprintf(stderr,"%s\n",rt_error(ctx));return 1;}
    double gpuMs=rt_last_gpu_ms(ctx);unsigned invalid=0;
    for(auto value:values)if(!std::isfinite(value.ambient_visibility)||!std::isfinite(value.sun_visibility)||value.ambient_visibility<0||value.ambient_visibility>1||value.sun_visibility<0||value.sun_visibility>1)invalid++;
    auto sample=[&](float x,float z){int px=int((x+3)*width/6),py=int((z+3)*height/6);return values[py*width+px];};
    auto near=sample(.65f,0),far=sample(2.8f,0),blocked=sample(1,0),lit=sample(-1,0);
    bool contrast=near.ambient_visibility<far.ambient_visibility-.1f && blocked.sun_visibility<.1f && lit.sun_visibility>.9f;
    bool images=png("results/ambient-occlusion.png",values,width,height,true)&&png("results/sun-shadows.png",values,width,height,false);
    auto report=@{@"passed":@(invalid==0&&contrast&&images),@"invalidValues":@(invalid),@"pixels":@(rays.size()),@"samplesPerEffect":@(settings.samples),
       @"nearAmbientVisibility":@(near.ambient_visibility),@"farAmbientVisibility":@(far.ambient_visibility),@"blockedSunVisibility":@(blocked.sun_visibility),@"litSunVisibility":@(lit.sun_visibility),@"gpuMs":@(gpuMs),@"gameplayIntegration":@NO};
    auto json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];puts([[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    rt_destroy(ctx);return invalid||!contrast||!images?1:0;
}}
