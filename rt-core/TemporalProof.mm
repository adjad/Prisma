// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "RtCore.h"
#include <array>
#include <vector>
#include <random>
#include <cmath>
#include <cstdio>
struct TemporalParameters {RtFrameParameters current;float previous_view_projection[16];float previous_camera[4];uint32_t history[4];uint32_t dynamic[4];};
using Pixel=std::array<float,4>;
constexpr int W=32,H=24;
static std::vector<Pixel> read(id<MTLTexture> texture){std::vector<Pixel> data(W*H);[texture getBytes:data.data() bytesPerRow:W*sizeof(Pixel) fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];return data;}
static void write(id<MTLTexture> texture,const std::vector<Pixel>&data){[texture replaceRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0 withBytes:data.data() bytesPerRow:W*sizeof(Pixel)];}
static double variance(const std::vector<Pixel>&values,int channel){double mean=0,total=0;for(auto p:values)mean+=p[channel];mean/=values.size();for(auto p:values)total+=(p[channel]-mean)*(p[channel]-mean);return total/values.size();}
int main(){@autoreleasepool{
    auto device=MTLCreateSystemDefaultDevice();NSError *error=nil;
    auto shader=[NSString stringWithContentsOfFile:@"trace.metal" encoding:NSUTF8StringEncoding error:&error];auto options=[MTLCompileOptions new];options.languageVersion=MTLLanguageVersion3_1;
    auto library=[device newLibraryWithSource:shader options:options error:&error];auto function=[library newFunctionWithName:@"resolve_temporal"];
    auto pipeline=[device newComputePipelineStateWithFunction:function error:&error];if(!pipeline){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 1;}
    auto descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:W height:H mipmapped:NO];descriptor.storageMode=MTLStorageModeShared;descriptor.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
    id<MTLTexture> raw[5],history[2][5],motion,rejection,local,localHistory[2],rawNoise[3],varianceHistory[2][3];
    for(int k=0;k<5;k++){raw[k]=[device newTextureWithDescriptor:descriptor];for(int slot=0;slot<2;slot++)history[slot][k]=[device newTextureWithDescriptor:descriptor];}
    motion=[device newTextureWithDescriptor:descriptor];rejection=[device newTextureWithDescriptor:descriptor];
    std::vector<Pixel> zero(W*H);
    local=[device newTextureWithDescriptor:descriptor];write(local,zero);
    for(int slot=0;slot<2;slot++){localHistory[slot]=[device newTextureWithDescriptor:descriptor];write(localHistory[slot],zero);}
    for(int k=0;k<3;k++){rawNoise[k]=[device newTextureWithDescriptor:descriptor];write(rawNoise[k],zero);for(int slot=0;slot<2;slot++){varianceHistory[slot][k]=[device newTextureWithDescriptor:descriptor];write(varianceHistory[slot][k],zero);}}
    auto queue=[device newCommandQueue];
    TemporalParameters parameters={};parameters.current.dimensions[0]=W;parameters.current.dimensions[1]=H;parameters.current.camera[2]=1;
    parameters.previous_camera[2]=1;parameters.history[1]=32;parameters.history[2]=W*2;parameters.history[3]=H*2;
    for(int i=0;i<4;i++)parameters.previous_view_projection[i*5]=1;
    int current=0;
    auto dispatch=[&](){
        auto command=[queue commandBuffer];auto encoder=[command computeCommandEncoder];[encoder setComputePipelineState:pipeline];[encoder setBytes:&parameters length:sizeof(parameters) atIndex:0];
        for(int k=0;k<5;k++){[encoder setTexture:raw[k] atIndex:k];[encoder setTexture:history[current][k] atIndex:k+5];[encoder setTexture:history[1-current][k] atIndex:k+10];}
        [encoder setTexture:motion atIndex:15];[encoder setTexture:rejection atIndex:28];
        [encoder setTexture:local atIndex:16];[encoder setTexture:localHistory[current] atIndex:17];[encoder setTexture:localHistory[1-current] atIndex:18];
        for(int k=0;k<3;k++){[encoder setTexture:rawNoise[k] atIndex:19+k];[encoder setTexture:varianceHistory[current][k] atIndex:22+k];[encoder setTexture:varianceHistory[1-current][k] atIndex:25+k];}[encoder dispatchThreads:MTLSizeMake(W,H,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[encoder endEncoding];[command commit];[command waitUntilCompleted];
        if(command.status!=MTLCommandBufferStatusCompleted){fprintf(stderr,"%s\n",command.error.localizedDescription.UTF8String);return false;}current=1-current;return true;
    };
    std::array<std::vector<Pixel>,5> input;for(auto &a:input)a.resize(W*H);
    std::mt19937 random(426);std::uniform_real_distribution<float> uniform(0,1);
    auto geometry=[&](float xShift,float zShift,float primitive,float nz){for(int y=0;y<H;y++)for(int x=0;x<W;x++){int at=y*W+x;input[3][at]={0,0,nz,.85};input[4][at]={2*(std::min(2*x+1,int(parameters.history[2])-1)+.5f)/parameters.history[2]-1+xShift,2*(std::min(2*y+1,int(parameters.history[3])-1)+.5f)/parameters.history[3]-1,zShift,primitive};}};
    geometry(0,0,1,1);double rawVariance=0,filteredVariance=0,reflectionRaw=0,reflectionFiltered=0;
    for(int frame=0;frame<64;frame++){
        parameters.history[0]=frame>0;
        for(int i=0;i<W*H;i++){input[0][i]={uniform(random)>.5?1.f:0.f,1,1,1};input[1][i]={uniform(random),.2f,.1f,.04f};input[2][i]={uniform(random),.1f,.2f,1};}
        for(int k=0;k<5;k++)write(raw[k],input[k]);if(!dispatch())return 1;
        if(frame>=44){rawVariance+=variance(input[0],0);filteredVariance+=variance(read(history[current][0]),0);reflectionRaw+=variance(input[1],0);reflectionFiltered+=variance(read(history[current][1]),0);}
    }
    float count=read(history[current][2])[10*W+10][3];double aoRatio=filteredVariance/rawVariance,reflRatio=reflectionFiltered/reflectionRaw;
    bool noise=aoRatio<.08&&reflRatio<.08&&count==32;
    // Exact one-pixel reprojection: a gradient in the old frame must shift by one half-res pixel.
    for(int y=0;y<H;y++)for(int x=0;x<W;x++){int i=y*W+x;input[0][i]={.25,1,1,1};input[1][i]={0,0,0,.04};input[2][i]={float(x)/W,0,0,16};}
    geometry(0,0,1,1);for(int k=0;k<5;k++)write(history[current][k],input[k]);
    geometry(2.f/W,0,1,1);for(auto &p:input[2])p={0,0,0,1};parameters.current.camera[0]=2.f/W;parameters.history[0]=1;
    for(int k=0;k<5;k++)write(raw[k],input[k]);if(!dispatch())return 1;
    auto translated=read(history[current][2]);auto vectors=read(motion);int sample=8*W+10;
    float expected=(11.f/W)*16.f/17.f;
    bool reprojection=std::abs(translated[sample][0]-expected)<1e-5&&translated[sample][3]==17&&std::abs(vectors[sample][0]-2)<1e-4&&vectors[sample][2]==1;
    // Mismatching primitive, normal, position, off-screen projection and explicit reset reject history.
    int rejected=0;
    for(int kind=0;kind<5;kind++){
        parameters.current.camera[0]=0;parameters.history[0]=kind!=4;
        geometry(0,0,1,1);for(auto &p:input[2])p={.8f,.2f,.1f,16};for(int k=0;k<5;k++)write(history[current][k],input[k]);
        geometry(kind==3?3.f:0,kind==2?.5f:0,kind==0?2.f:1.f,kind==1?-1.f:1.f);for(auto &p:input[2])p={.2f,.3f,.4f,1};
        for(int k=0;k<5;k++)write(raw[k],input[k]);if(!dispatch())return 1;
        auto pixel=read(history[current][2])[sample];if(std::abs(pixel[0]-.2f)<1e-6&&pixel[3]==1&&read(motion)[sample][2]==0)rejected++;
    }
    parameters.history[0]=1;parameters.history[2]=W*2-1;parameters.history[3]=H*2-1;
    geometry(0,0,1,1);for(auto &p:input[2])p={.8f,0,0,16};for(int k=0;k<5;k++)write(history[current][k],input[k]);
    for(auto &p:input[2])p={.2f,0,0,1};for(int k=0;k<5;k++)write(raw[k],input[k]);if(!dispatch())return 1;
    bool oddSize=true;for(auto p:read(history[current][2]))oddSize&=p[3]==17&&std::abs(p[0]-(.8f*16+.2f)/17)<1e-5;
    // Moving secondary-light rectangle on an unchanged primary plane. Stable
    // surroundings retain accumulation; newly uncovered hard shadows must not trail.
    parameters.current.camera[0]=0;parameters.history[2]=W*2;parameters.history[3]=H*2;
    parameters.dynamic[0]=1;parameters.dynamic[1]=2;parameters.dynamic[2]=1;
    geometry(0,0,1,1);double dynamicRaw=0,dynamicFiltered=0,shadowError=0,removedReflectionError=0;
    for(int frame=0;frame<80;frame++){
        parameters.history[0]=frame>0;int left=2+(frame/3)%10;
        for(int y=0;y<H;y++)for(int x=0;x<W;x++){
            int i=y*W+x;bool patch=frame<72&&x>=left&&x<left+5&&y>=5&&y<15;
            float ao=0;for(int n=0;n<4;n++)ao+=uniform(random)>.5f?.25f:0.f;
            input[0][i]={ao,patch?0.f:1.f,1,1};
            input[1][i]={patch?.9f:.4f,.2f+(uniform(random)-.5f)*.4f,.1f,.04f};
            input[2][i]={patch?.8f:.3f,0,0,1};
        }
        for(int k=0;k<5;k++)write(raw[k],input[k]);if(!dispatch())return 1;
        auto visibility=read(history[current][0]),reflection=read(history[current][1]);
        if(frame>24)for(int y=3;y<H-3;y++)for(int x=22;x<W-2;x++){
            int i=y*W+x;dynamicRaw+=std::pow(input[0][i][0]-.5f,2);dynamicFiltered+=std::pow(visibility[i][0]-.5f,2);
        }
        if(frame>0)for(int y=4;y<16;y++)for(int x=1;x<18;x++)shadowError=std::max(shadowError,double(std::abs(visibility[y*W+x][1]-input[0][y*W+x][1])));
        if(frame>=72)for(auto pixel:reflection)removedReflectionError=std::max(removedReflectionError,double(std::abs(pixel[0]-.4f)));
    }
    double dynamicRatio=dynamicFiltered/dynamicRaw;
    bool dynamicPassed=dynamicRatio<.3&&shadowError<.001&&removedReflectionError<.001;
    fprintf(stderr,"Dynamic temporal: variance ratio %.6f, hard shadow error %.6f, removed reflection error %.6f\n",dynamicRatio,shadowError,removedReflectionError);
    // Independent rare-event sampling: three Bernoulli rays per frame, with
    // the unbiased sample-mean variance passed separately from the radiance.
    // Mean must survive reconstruction; rare events must not bypass smoothing.
    geometry(0,0,1,1);double sparseRaw=0,sparseFiltered=0,sparseInputEnergy=0,sparseOutputEnergy=0;double removal=0;
    std::vector<Pixel> radianceVariance(W*H),localValues(W*H);
    for(int frame=0;frame<256;frame++){
        parameters.history[0]=frame>0;
        for(int i=0;i<W*H;i++){
            float sum=0;for(int ray=0;ray<3;ray++)sum+=frame<224&&uniform(random)<.03f?1.f:0.f;
            float mean=sum/3,meanVariance=(sum-sum*sum/3)/6;
            input[0][i]={1,1,1,1};input[1][i]={mean,mean*.5f,mean*.25f,.04f};input[2][i]={mean,mean*.5f,mean*.25f,1};
            localValues[i]={mean,mean*.5f,mean*.25f,0};radianceVariance[i]={meanVariance,meanVariance*.25f,meanVariance*.0625f,0};
        }
        for(int k=0;k<5;k++)write(raw[k],input[k]);write(local,localValues);for(int k=0;k<3;k++)write(rawNoise[k],radianceVariance);
        if(!dispatch())return 1;
        auto r=read(history[current][1]),g=read(history[current][2]),l=read(localHistory[current]);
        if(frame>=64&&frame<224)for(int i=0;i<W*H;i++){
            sparseRaw+=3*std::pow(input[1][i][0]-.03f,2);sparseInputEnergy+=3*input[1][i][0];
            for(auto value:{r[i],g[i],l[i]}){sparseFiltered+=std::pow(value[0]-.03f,2);sparseOutputEnergy+=value[0];}
        }
        if(frame==255)for(int i=0;i<W*H;i++)for(auto value:{r[i],g[i],l[i]})removal+=value[0]/(3*W*H);
    }
    double sparseRatio=sparseFiltered/sparseRaw,energyRatio=sparseOutputEnergy/sparseInputEnergy;
    bool sparsePassed=sparseRatio<.3&&std::abs(energyRatio-1)<.05&&removal<.0005;
    fprintf(stderr,"Sparse radiance: MSE ratio %.6f, energy ratio %.6f, removed mean %.8f\n",sparseRatio,energyRatio,removal);
    // Validate the mask consumed by MetalFX independently of the reconstructed RGB.
    // A moving shadow, reflection, local light and GI change must reject history;
    // unrelated static samples must keep it. Dynamic and disoccluded surfaces reject.
    int maskCases=0;parameters.history[0]=1;parameters.dynamic[0]=parameters.dynamic[2]=1;
    parameters.current.controls[2]=parameters.current.controls[3]=1;
    parameters.current.transport[0]=parameters.current.transport[1]=1;
    for(int test=0;test<7;test++) {
        geometry(0,0,1,1);for(int i=0;i<W*H;i++){input[0][i]={1,1,1,1};input[1][i]={0,0,0,0};input[2][i]={0,0,0,16};}
        for(int k=0;k<5;k++)write(history[current][k],input[k]);write(localHistory[current],zero);
        for(int k=0;k<3;k++){write(varianceHistory[current][k],zero);write(rawNoise[k],zero);}
        for(auto &v:input[2])v[3]=1;localValues=zero;
        if(test==1)for(auto &v:input[0])v[1]=0;
        if(test==2)for(auto &v:input[1])v[0]=1;
        if(test==3)for(auto &v:input[2])v[2]=1;
        if(test==4)for(auto &v:localValues)v[1]=1;
        if(test==5)geometry(0,0,3,1);
        if(test==6)geometry(0,.5,1,1);
        for(int k=0;k<5;k++)write(raw[k],input[k]);write(local,localValues);if(!dispatch())return 1;
        auto mask=read(rejection);float expectedMask=test==0?0:1;
        if(std::abs(mask[sample][0]-expectedMask)<1e-6)maskCases++;
    }
    fprintf(stderr,"MetalFX rejection-mask cases: %d/7\n",maskCases);
    bool passed=noise&&reprojection&&rejected==5&&oddSize&&dynamicPassed&&sparsePassed&&maskCases==7;
    printf("{\"passed\":%s,\"aoVarianceRatio\":%.8f,\"reflectionVarianceRatio\":%.8f,\"historyLength\":%.0f,\"onePixelReprojection\":%s,\"historyRejectionCasesPassed\":%d,\"oddFramebufferSize\":%s,\"dynamicVarianceRatio\":%.8f,\"movingShadowMaxError\":%.8f,\"removedReflectionMaxError\":%.8f,\"sparseRadianceMseRatio\":%.8f,\"sparseRadianceEnergyRatio\":%.8f,\"sparseRadianceRemovedMean\":%.8f,\"metalfxRejectionMaskCases\":%d,\"minecraftIntegration\":false}\n",passed?"true":"false",aoRatio,reflRatio,count,reprojection?"true":"false",rejected,oddSize?"true":"false",dynamicRatio,shadowError,removedReflectionError,sparseRatio,energyRatio,removal,maskCases);
    return passed?0:1;
}}
