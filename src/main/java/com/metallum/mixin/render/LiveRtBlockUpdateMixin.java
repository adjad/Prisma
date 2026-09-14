// SPDX-License-Identifier: MIT
package com.metallum.mixin.render;
import com.metallum.render.MetalRtIntegration;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
@Mixin(ClientLevel.class)
public class LiveRtBlockUpdateMixin {
    @Inject(method="setBlocksDirty",at=@At("HEAD"))
    private void metallum$changed(BlockPos pos,BlockState before,BlockState after,CallbackInfo ci){
        if(before!=after)MetalRtIntegration.changed((ClientLevel)(Object)this,pos,1);
    }
    @Inject(method="setSectionDirtyWithNeighbors",at=@At("HEAD"))
    private void metallum$section(int x,int y,int z,CallbackInfo ci){
        MetalRtIntegration.changed((ClientLevel)(Object)this,new BlockPos(x*16-16,y*16-16,z*16-16),48);
    }
}
