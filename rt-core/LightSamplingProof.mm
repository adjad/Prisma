// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#include "RtCore.h"
#include <vector>
#include <cmath>
#include <cstdio>
static double reference(double height){double sum=0;constexpr int n=128;for(int x=0;x<n;x++)for(int y=0;y<n;y++){double u=-1+(x+.5)*2/n,v=-1+(y+.5)*2/n,d2=u*u+v*v+height*height;sum+=height*height/(d2*d2);}return sum*16/(n*n);}
int main(){@autoreleasepool{
 auto shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];char error[4096];auto c=rt_create(nullptr,shader.UTF8String,error,sizeof(error));if(!c){fprintf(stderr,"%s\n",error);return 1;}
 RtVertex floor[]={{-30,0,-30},{-30,0,30},{30,0,30},{-30,0,-30},{30,0,30},{30,0,-30}};
 if(!rt_build_triangles(c,floor,6))return 1;
 std::vector<RtAreaLight> lights(128);for(unsigned i=0;i<lights.size();i++)lights[i]={{0,i?80.f:4.f,0,0},{1,0,0,0},{0,0,1,0},{4,2,1,0}};
 if(!rt_set_area_lights(c,lights.data(),unsigned(lights.size())))return 1;
 constexpr unsigned count=2048;std::vector<RtLightReceiver> receivers(count,{{0,0,0,0},{0,1,0,0}});std::vector<RtIrradiance> output(count);
 double means[2]={},variances[2]={};float origin[]={0,0,0};
 for(unsigned mode=0;mode<2;mode++){
  if(mode&&!rt_set_light_sampling_origin(c,origin))return 1;
  if(!rt_local_lighting(c,receivers.data(),output.data(),count,64,20260914,.001f)){fprintf(stderr,"%s\n",rt_error(c));return 1;}
  for(auto &v:output)means[mode]+=v.rgb[0]/count;
  for(auto &v:output)variances[mode]+=std::pow(v.rgb[0]-means[mode],2)/count;
 }
 double expected=reference(4)+127*reference(80),ratio=variances[1]/variances[0];RtLightStatistics stats{};rt_light_statistics(c,&stats);
 bool passed=std::abs(means[0]-expected)/expected<.06&&std::abs(means[1]-expected)/expected<.02&&ratio<.15&&stats.count==128;
 printf("{\"passed\":%s,\"retainedLights\":%llu,\"cpuReference\":%.9f,\"uniformMean\":%.9f,\"importanceMean\":%.9f,\"uniformVariance\":%.9f,\"importanceVariance\":%.9f,\"varianceRatio\":%.9f}\n",passed?"true":"false",(unsigned long long)stats.count,expected,means[0],means[1],variances[0],variances[1],ratio);
 rt_destroy(c);return passed?0:1;
}}
