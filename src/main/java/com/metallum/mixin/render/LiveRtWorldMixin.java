// SPDX-License-Identifier: MIT
package com.metallum.mixin.render;
import com.metallum.render.MetalRtIntegration;
import com.mojang.blaze3d.resource.GraphicsResourceAllocator;
import com.mojang.blaze3d.buffers.GpuBufferSlice;
import net.minecraft.client.DeltaTracker;
import net.minecraft.client.renderer.LevelRenderer;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import org.joml.Matrix4fc;
import org.joml.Vector4f;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
@Mixin(LevelRenderer.class)
public class LiveRtWorldMixin {
    @Inject(method="render",at=@At("TAIL"))
    private void metallum$liveRt(GraphicsResourceAllocator allocator,DeltaTracker delta,boolean outline,CameraRenderState camera,Matrix4fc projection,GpuBufferSlice fog,Vector4f fogColor,boolean sky,CallbackInfo ci){
        MetalRtIntegration.afterWorld(camera,projection);
    }
    @Inject(method="resetLevelRenderData",at=@At("HEAD"))
    private void metallum$invalidate(CallbackInfo ci){MetalRtIntegration.invalidate();}
}
