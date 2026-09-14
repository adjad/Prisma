// SPDX-License-Identifier: MIT
package com.metallum.mixin.render;
import com.mojang.blaze3d.platform.NativeImage;
import net.minecraft.client.renderer.texture.SpriteContents;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** Versioned access to CPU sprite pixels; copied on the client thread before worker use. */
@Mixin(SpriteContents.class)
public interface RtSpriteContentsAccessor {
    @Accessor("originalImage") NativeImage metallum$originalImage();
}
