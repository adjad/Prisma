// SPDX-License-Identifier: MIT
#include "MetalFxFrame.h"
#include <cstring>
std::shared_ptr<MetalFxFrame> MetalFxFrame::create(id<MTLDevice> device,NSUInteger width,NSUInteger height,std::string &error) {
    if(![MTLFXTemporalDenoisedScalerDescriptor supportsDevice:device]){error="MetalFX denoised scaling unsupported";return {};}
    auto descriptor=[MTLFXTemporalDenoisedScalerDescriptor new];
    descriptor.inputWidth=descriptor.outputWidth=width;descriptor.inputHeight=descriptor.outputHeight=height;
    descriptor.colorTextureFormat=descriptor.outputTextureFormat=MTLPixelFormatRGBA32Float;
    descriptor.depthTextureFormat=MTLPixelFormatR32Float;descriptor.motionTextureFormat=MTLPixelFormatRG16Float;
    descriptor.diffuseAlbedoTextureFormat=descriptor.specularAlbedoTextureFormat=descriptor.normalTextureFormat=MTLPixelFormatRGBA16Float;
    descriptor.roughnessTextureFormat=MTLPixelFormatR16Float;
    descriptor.denoiseStrengthMaskTextureEnabled=YES;descriptor.denoiseStrengthMaskTextureFormat=MTLPixelFormatR8Unorm;
    descriptor.reactiveMaskTextureEnabled=YES;descriptor.reactiveMaskTextureFormat=MTLPixelFormatR8Unorm;
    descriptor.autoExposureEnabled=NO;descriptor.requiresSynchronousInitialization=YES;
    auto frame=std::make_shared<MetalFxFrame>();auto s=[descriptor newTemporalDenoisedScalerWithDevice:device];
    if(!s){error="MetalFX denoised scaler creation failed";return {};}
    frame->scaler=s;
    auto texture=[&](MTLPixelFormat format,MTLTextureUsage usage,NSString *label){
        auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
        desc.storageMode=MTLStorageModePrivate;desc.usage=usage|MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
        auto value=[device newTextureWithDescriptor:desc];value.label=label;return value;
    };
    frame->color=texture(descriptor.colorTextureFormat,s.colorTextureUsage|MTLTextureUsageRenderTarget,@"MetalFX linear noisy lighting");
    frame->depth=texture(descriptor.depthTextureFormat,s.depthTextureUsage,@"MetalFX interface depth");
    frame->motion=texture(descriptor.motionTextureFormat,s.motionTextureUsage,@"MetalFX previous-minus-current pixel motion");
    frame->diffuse=texture(descriptor.diffuseAlbedoTextureFormat,s.diffuseAlbedoTextureUsage,@"MetalFX diffuse albedo");
    frame->specular=texture(descriptor.specularAlbedoTextureFormat,s.specularAlbedoTextureUsage,@"MetalFX Fresnel specular albedo");
    frame->normal=texture(descriptor.normalTextureFormat,s.normalTextureUsage,@"MetalFX signed world normal");
    frame->roughness=texture(descriptor.roughnessTextureFormat,s.roughnessTextureUsage,@"MetalFX linear roughness");
    frame->mask=texture(descriptor.denoiseStrengthMaskTextureFormat,s.denoiseStrengthMaskTextureUsage,@"MetalFX unsupported geometry bypass");
    frame->reactive=texture(descriptor.reactiveMaskTextureFormat,s.reactiveTextureUsage,@"MetalFX invalid history mask");
    frame->output=texture(descriptor.outputTextureFormat,s.outputTextureUsage,@"MetalFX denoised lighting");
    for(auto value:{frame->color,frame->depth,frame->motion,frame->diffuse,frame->specular,frame->normal,frame->roughness,frame->mask,frame->reactive,frame->output})
        if(!value){error="MetalFX texture allocation failed";return {};}
    s.colorTexture=frame->color;s.depthTexture=frame->depth;s.motionTexture=frame->motion;
    s.diffuseAlbedoTexture=frame->diffuse;s.specularAlbedoTexture=frame->specular;s.normalTexture=frame->normal;
    s.roughnessTexture=frame->roughness;s.denoiseStrengthMaskTexture=frame->mask;s.reactiveMaskTexture=frame->reactive;s.outputTexture=frame->output;
    s.preExposure=1;s.motionVectorScaleX=1;s.motionVectorScaleY=1;s.jitterOffsetX=0;s.jitterOffsetY=0;s.depthReversed=YES;
    return frame;
}
void MetalFxFrame::encode(id<MTLCommandBuffer> command,id<MTLFence> fence,const float *worldToView,const float *viewToClip,bool reset) {
    simd_float4x4 view,projection;memcpy(&view,worldToView,64);memcpy(&projection,viewToClip,64);
    scaler.worldToViewMatrix=view;scaler.viewToClipMatrix=projection;
    scaler.shouldResetHistory=reset||!valid;scaler.fence=fence;
    [scaler encodeToCommandBuffer:command];valid=true;
}
