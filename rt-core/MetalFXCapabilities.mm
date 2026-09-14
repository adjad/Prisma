// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include <cstdio>
int main(){@autoreleasepool{
    auto device=MTLCreateSystemDefaultDevice();
    if(!device)return 1;
    if(@available(macOS 26.0,*)){
        NSDictionary *report=@{@"device":device.name,@"hardwareRayTracing":@(device.supportsRaytracing),@"temporalDenoisedScalerSupported":@([MTLFXTemporalDenoisedScalerDescriptor supportsDevice:device]),@"metal4TemporalDenoisedScalerSupported":@([MTLFXTemporalDenoisedScalerDescriptor supportsMetal4FX:device]),@"minimumScale":@([MTLFXTemporalDenoisedScalerDescriptor supportedInputContentMinScaleForDevice:device]),@"maximumScale":@([MTLFXTemporalDenoisedScalerDescriptor supportedInputContentMaxScaleForDevice:device]),@"denoiserExecuted":@NO,@"minecraftIntegration":@NO};
        auto data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);puts("");return 0;
    }
    fprintf(stderr,"MetalFX denoised scaling requires macOS 26 or later\n");return 1;
}}
