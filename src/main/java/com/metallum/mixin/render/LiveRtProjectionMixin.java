// SPDX-License-Identifier: MIT
package com.metallum.mixin.render;
import com.metallum.render.MetalRtIntegration;
import net.minecraft.client.renderer.GameRenderer;
import org.joml.Matrix4f;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.ModifyArg;
@Mixin(GameRenderer.class)
public class LiveRtProjectionMixin {
    @ModifyArg(method="renderLevel",at=@At(value="INVOKE",target="Lnet/minecraft/client/renderer/ProjectionMatrixBuffer;getBuffer(Lorg/joml/Matrix4f;)Lcom/mojang/blaze3d/buffers/GpuBufferSlice;"),index=0)
    private Matrix4f metallum$captureProjection(Matrix4f projection){MetalRtIntegration.projection(projection);return projection;}
}
