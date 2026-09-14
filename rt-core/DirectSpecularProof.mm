// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "RtCore.h"
#include <vector>
#include <array>
#include <cmath>
#include <cstdio>
struct Mesh {
 std::vector<RtVertex> vertices;std::vector<RtMaterial> materials;std::vector<uint32_t> texels;
 void quad(RtVertex a,RtVertex b,RtVertex c,RtVertex d,uint32_t color,float roughness,float metallic,float emission=0){
  RtMaterial m={};for(float &v:m.tint)v=1;m.surface[0]=roughness;m.surface[1]=metallic;m.surface[2]=emission;m.optics[0]=1.5;m.optics[1]=.5;m.optics[2]=1;m.image[0]=uint32_t(texels.size());m.image[1]=m.image[2]=1;texels.push_back(color);
  for(auto v:{a,b,c,a,c,d})vertices.push_back(v);
  m.uv01[2]=1;m.uv2[0]=m.uv2[1]=1;materials.push_back(m);m.uv01[3]=1;m.uv2[0]=0;materials.push_back(m);
 }
 bool upload(RtContext *ctx){return rt_build_triangles(ctx,vertices.data(),uint32_t(vertices.size()))&&rt_set_materials(ctx,materials.data(),uint32_t(materials.size()),texels.data(),uint32_t(texels.size()));}
};
static double reference(double half,double roughness){
 constexpr unsigned n=768;double sum=0,alpha=std::max(.001,roughness*roughness),a2=alpha*alpha;
 for(unsigned z=0;z<n;z++)for(unsigned x=0;x<n;x++){
  double u=(2*(x+.5)/n-1)*half,v=(2*(z+.5)/n-1)*half,d2=u*u+9+v*v,noL=3/sqrt(d2),noH=sqrt((1+noL)*.5);
  double term=noH*noH*(a2-1)+1,D=a2/(M_PI*term*term),G=2*noL/(noL+sqrt(a2+(1-a2)*noL*noL));
  double brdf=D*G/(4*noL);sum+=8*brdf*noL*noL/d2;
 }
 return sum*4*half*half/(n*n);
}
int main(){@autoreleasepool{
 auto device=MTLCreateSystemDefaultDevice();if(!device)return 1;NSString *shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:nil];char error[4096];auto ctx=rt_create((__bridge void*)device,shader.UTF8String,error,sizeof(error));if(!ctx){fprintf(stderr,"%s\n",error);return 1;}
 RtFrameParameters p={};p.sun[1]=-1;p.controls[1]=.001;p.controls[3]=1;p.transport[0]=1;p.transport[3]=20;p.dimensions[3]=32768;
 int failures=0;auto check=[&](bool condition,const char *name){if(!condition){failures++;fprintf(stderr,"FAIL %s: %s\n",name,rt_error(ctx));}};
 std::vector<RtRay> rays(256,RtRay{{0,1,0,.001},{0,-1,0,20}});std::vector<RtTransport> out(rays.size());
 auto trace=[&](unsigned samples=512){p.dimensions[2]+=19;check(rt_transport(ctx,rays.data(),out.data(),unsigned(rays.size()),&p,samples),"transport");std::array<double,3> mean{};for(const auto &r:out)for(unsigned i=0;i<3;i++)mean[i]+=r.reflection[i]/rays.size();return mean;};
 double gpu[3]={},cpu[3]={};unsigned at=0;
 for(float roughness:{.2f,.6f,.95f}){
  float half=roughness<.3f?.3f:1.f;Mesh mesh;mesh.quad({-10,0,-10},{-10,0,10},{10,0,10},{10,0,-10},0xffffffff,roughness,1);
  check(mesh.upload(ctx),"receiver");RtAreaLight light={{0,3,0,0},{half,0,0,0},{0,0,half,0},{8,8,8,0}};check(rt_set_area_lights(ctx,&light,1),"analytical light");
  auto analytic=trace();double expected=reference(half,roughness);check(std::abs(analytic[0]-expected)/expected<.025,"analytical light matches independent quadrature");
  mesh.quad({-half,3,-half},{half,3,-half},{half,3,half},{-half,3,half},0xffffffff,.85,0,8);check(mesh.upload(ctx),"emitter geometry");auto combined=trace();
  gpu[at]=combined[0];cpu[at]=expected;at++;check(std::abs(combined[0]-expected)/expected<.025,"MIS geometry plus light does not double energy");
  if(roughness>.5f){check(rt_set_area_lights(ctx,nullptr,0),"BSDF-only source");auto only=trace(4096);check(std::abs(only[0]-expected)/expected<.06,"BSDF-only reference energy");}
 }
 // Textured emitter: average light RGB is deliberately inconsistent with its two texels.
 // Both MIS techniques must evaluate the same local emission, not that average.
 Mesh textured;textured.quad({-10,0,-10},{-10,0,10},{10,0,10},{10,0,-10},0xffffffff,.6,1);textured.quad({-1,3,-1},{1,3,-1},{1,3,1},{-1,3,1},0xffff0000,.85,0,8);
 textured.texels.push_back(0xff0000ff);for(unsigned i=2;i<4;i++)textured.materials[i].image[1]=2;
 check(textured.upload(ctx),"textured emitter");RtAreaLight texturedLight={{0,3,0,0},{1,0,0,0},{0,0,1,0},{.01,100,.01,0}};check(rt_set_area_lights(ctx,&texturedLight,1),"textured source distribution");auto texture=trace();double expected=reference(1,.6);
 check(std::abs(texture[0]-expected*.5)/(expected*.5)<.03&&std::abs(texture[2]-expected*.5)/(expected*.5)<.03&&texture[1]==0,"matching textured emission in both estimators");
 // Alpha-cutout holes emit no light in either estimator.
 Mesh cutout=textured;cutout.texels[1]=0x00ff0000;for(unsigned i=2;i<4;i++)cutout.materials[i].image[3]=1;
 check(cutout.upload(ctx),"cutout source");auto holes=trace();check(holes[0]==0&&holes[1]==0&&std::abs(holes[2]-expected*.5)/(expected*.5)<.03,"alpha holes are not emissive");
 // Refraction is owned by the BSDF path; a straight NEE segment must not duplicate it.
 Mesh window=textured;window.quad({-5,1.5,-5},{-5,1.5,5},{5,1.5,5},{5,1.5,-5},0xffffffff,.001,0);
 for(unsigned i=4;i<6;i++)window.materials[i].surface[3]=.98;
 check(window.upload(ctx),"refractive light path");p.dimensions[3]|=65536;auto glassBefore=trace(4096);p.dimensions[3]&=~65536u;auto glassAfter=trace(4096);
 check(glassBefore[0]>.1&&std::abs(glassBefore[0]-glassAfter[0])/glassBefore[0]<.025&&std::abs(glassBefore[2]-glassAfter[2])/glassBefore[2]<.025,"refracted path energy is not counted twice");
 // An opaque black blocker lies between the receiver and emitter, beyond the camera.
 Mesh blocked=textured;blocked.quad({-2,1.5,-2},{2,1.5,-2},{2,1.5,2},{-2,1.5,2},0xff000000,.85,0);check(blocked.upload(ctx),"blocker");auto dark=trace();check(dark[0]==0&&dark[1]==0&&dark[2]==0,"blocked specular light vanishes");
 check(textured.upload(ctx),"restore unblocked source");check(rt_set_area_lights(ctx,nullptr,0),"remove light sampling");auto visible=trace(4096);check(visible[0]>0&&visible[2]>0,"visible mesh emission remains without explicit light");
 Mesh floor;floor.quad({-10,0,-10},{-10,0,10},{10,0,10},{10,0,-10},0xffffffff,.6,1);check(floor.upload(ctx),"sun receiver");p.sun[1]=1;p.sun[3]=0;p.transport[2]=1;p.dimensions[3]|=65536;auto noDirect=trace();p.dimensions[3]&=~65536u;auto withDirect=trace();double sunDelta=withDirect[0]-noDirect[0];double alpha=.6*.6;double sunExpected=1/(4*M_PI*alpha*alpha);
 check(std::abs(sunDelta-sunExpected)/sunExpected<.003,"directional sun highlight matches analytic GGX");
 p.sun[3]=.2;auto disk=trace();check(disk[0]-noDirect[0]<sunDelta&&disk[0]>noDirect[0],"finite sun broadens and lowers centered peak");
 p.sun[3]=0;Mesh sunBlock=floor;sunBlock.quad({-2,1.5,-2},{2,1.5,-2},{2,1.5,2},{-2,1.5,2},0xff000000,.85,0);check(sunBlock.upload(ctx),"sun blocker");p.dimensions[3]|=65536;auto blockedBefore=trace();p.dimensions[3]&=~65536u;auto blockedAfter=trace();check(std::abs(blockedAfter[0]-blockedBefore[0])<.002,"sun blocker removes direct highlight");
 printf("{\"passed\":%s,\"failures\":%d,\"gpuAreaRadiance\":[%.8f,%.8f,%.8f],\"cpuQuadrature\":[%.8f,%.8f,%.8f],\"texturedRgb\":[%.8f,%.8f,%.8f],\"cutoutRgb\":[%.8f,%.8f,%.8f],\"glassBefore\":[%.8f,%.8f],\"glassAfter\":[%.8f,%.8f],\"blockedRgb\":[%.8f,%.8f,%.8f],\"sunDelta\":%.8f,\"sunReference\":%.8f,\"finiteDiskDelta\":%.8f}\n",failures?"false":"true",failures,gpu[0],gpu[1],gpu[2],cpu[0],cpu[1],cpu[2],texture[0],texture[1],texture[2],holes[0],holes[1],holes[2],glassBefore[0],glassBefore[2],glassAfter[0],glassAfter[2],dark[0],dark[1],dark[2],sunDelta,sunExpected,disk[0]-noDirect[0]);rt_destroy(ctx);return failures?1:0;
}}
