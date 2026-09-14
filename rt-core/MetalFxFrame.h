// SPDX-License-Identifier: MIT
#pragma once
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include <string>
#include <memory>

// Reused across frames and identical scene rebuilds; all resources are private.
struct MetalFxFrame {
    id<MTLFXTemporalDenoisedScaler> scaler;
    id<MTLTexture> color, depth, motion, diffuse, specular, normal, roughness, mask, reactive, output;
    bool valid=false;
    static std::shared_ptr<MetalFxFrame> create(id<MTLDevice> device,NSUInteger width,NSUInteger height,std::string &error);
    void encode(id<MTLCommandBuffer> command,id<MTLFence> fence,const float *worldToView,const float *viewToClip,bool reset);
};
