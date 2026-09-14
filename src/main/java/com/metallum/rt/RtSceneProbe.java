// SPDX-License-Identifier: MIT
package com.metallum.rt;

import com.google.gson.GsonBuilder;
import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.Blocks;
import net.fabricmc.loader.api.FabricLoader;
import java.lang.foreign.MemorySegment;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.awt.image.BufferedImage;
import javax.imageio.ImageIO;
import java.util.*;

/** Explicit diagnostic snapshot, not a per-frame rendering path or a gameplay effect. */
public final class RtSceneProbe {
    private RtSceneProbe() {}
    public static void capture(Minecraft mc) throws Exception {
        if (!mc.isSameThread() || mc.level == null || mc.player == null) throw new IllegalStateException("Probe requires loaded client world on main thread");
        var folder=FabricLoader.getInstance().getGameDir().resolve("rt-development");
        Files.createDirectories(folder);
        var models=mc.getModelManager().getBlockStateModelSet();
        var checks=new LinkedHashMap<String,Object>();
        try(var scene=new NativeRtScene(MemorySegment.NULL)) {
            for(var entry:Map.of("cube",Blocks.STONE.defaultBlockState(),"slab",Blocks.STONE_SLAB.defaultBlockState(),
                    "stairs",Blocks.OAK_STAIRS.defaultBlockState(),"glass",Blocks.GLASS.defaultBlockState(),"foliage",Blocks.OAK_LEAVES.defaultBlockState()).entrySet()) {
                var mesh=BlockSceneSnapshot.model(models,entry.getValue());
                float[] xyz=mesh.vertices(); scene.buildTriangles(xyz);
                var hit=scene.trace(new float[]{.25f,2,.25f,0, 0,-1,0,10})[0];
                float maxY=-Float.MAX_VALUE,minY=Float.MAX_VALUE;
                for(int i=1;i<xyz.length;i+=3) {maxY=Math.max(maxY,xyz[i]);minY=Math.min(minY,xyz[i]);}
                if(entry.getKey().equals("slab") && (!hit.hit() || Math.abs(hit.distance()-1.5f)>2e-5 || Math.abs(maxY-.5f)>1e-6)) throw new IllegalStateException("Bottom slab model lost its half-height geometry");
                if(entry.getKey().equals("cube") && (!hit.hit() || Math.abs(hit.distance()-1)>2e-5)) throw new IllegalStateException("Cube intersection mismatch");
                checks.put(entry.getKey(),Map.of("triangles",mesh.triangles(),"minY",minY,"maxY",maxY,"topRay",hit,
                    "layers",mesh.surfaces().stream().map(BlockSceneSnapshot.Surface::layer).distinct().toList()));
            }
            BlockPos origin=mc.player.blockPosition().offset(-12,-12,-12);
            var mesh=BlockSceneSnapshot.capture(mc.level,models,origin,25);
            float[] xyz=mesh.vertices();
            if(xyz.length==0) throw new IllegalStateException("No block geometry near player");
            scene.buildTriangles(xyz);
            var eye=mc.player.getEyePosition();
            int width=320,height=200; float[] rays=new float[width*height*8];
            double yaw=Math.toRadians(mc.player.getYRot()),pitch=Math.toRadians(mc.player.getXRot());
            double[] forward={-Math.sin(yaw)*Math.cos(pitch),-Math.sin(pitch),Math.cos(yaw)*Math.cos(pitch)};
            double[] right={-Math.cos(yaw),0,-Math.sin(yaw)};
            double[] up={-Math.sin(yaw)*Math.sin(pitch),Math.cos(pitch),Math.cos(yaw)*Math.sin(pitch)};
            double tan=Math.tan(Math.toRadians(70)/2);
            for(int y=0;y<height;y++) for(int x=0;x<width;x++) {
                int at=(y*width+x)*8;
                rays[at]=(float)(eye.x-origin.getX());rays[at+1]=(float)(eye.y-origin.getY());rays[at+2]=(float)(eye.z-origin.getZ());rays[at+3]=.001f;
                double u=(2*(x+.5)/width-1)*tan*width/height,v=(1-2*(y+.5)/height)*tan;
                double dx=forward[0]+u*right[0]+v*up[0],dy=forward[1]+u*right[1]+v*up[1],dz=forward[2]+u*right[2]+v*up[2],len=Math.sqrt(dx*dx+dy*dy+dz*dz);
                rays[at+4]=(float)(dx/len);rays[at+5]=(float)(dy/len);rays[at+6]=(float)(dz/len);rays[at+7]=48;
            }
            var hits=scene.trace(rays);var image=new BufferedImage(width,height,BufferedImage.TYPE_INT_RGB);int hitCount=0;
            for(int i=0;i<hits.length;i++) {
                int rgb=0x42668a;
                if(hits[i].hit()) {hitCount++;int gray=Math.max(24,Math.min(255,(int)(255*Math.exp(-hits[i].distance()/16))));rgb=gray*0x010101;}
                image.setRGB(i%width,i/width,rgb);
            }
            ImageIO.write(image,"png",folder.resolve("geometry-depth.png").toFile());
            var visibility=scene.visibility(rays,-.6f,.8f,0,.00465f,2,32,20260914);
            double sumAo=0,sumSun=0;int visibilityHits=0;
            var aoImage=new BufferedImage(width,height,BufferedImage.TYPE_INT_RGB);
            var sunImage=new BufferedImage(width,height,BufferedImage.TYPE_INT_RGB);
            for(int i=0;i<visibility.length;i++) {
                var value=visibility[i];
                if(!Float.isFinite(value.ambient())||!Float.isFinite(value.sun())||value.ambient()<0||value.ambient()>1||value.sun()<0||value.sun()>1)
                    throw new IllegalStateException("Invalid visibility buffer value");
                if(value.hit()){sumAo+=value.ambient();sumSun+=value.sun();visibilityHits++;}
                aoImage.setRGB(i%width,i/width,(int)(255*value.ambient())*0x010101);
                sunImage.setRGB(i%width,i/width,(int)(255*value.sun())*0x010101);
            }
            ImageIO.write(aoImage,"png",folder.resolve("ambient-visibility.png").toFile());
            ImageIO.write(sunImage,"png",folder.resolve("sun-visibility.png").toFile());
            var buffer=ByteBuffer.allocate(xyz.length*4).order(ByteOrder.LITTLE_ENDIAN);
            for(float f:xyz)buffer.putFloat(f);
            Files.write(folder.resolve("triangles-f32le.bin"),buffer.array());
            var gson=new GsonBuilder().setPrettyPrinting().create();
            Files.writeString(folder.resolve("surfaces.json"),gson.toJson(mesh.surfaces()));
            var result=new LinkedHashMap<String,Object>();
            result.put("time",java.time.Instant.now().toString());result.put("modelChecks",checks);
            result.put("dimension",mc.level.dimension().toString());result.put("origin",List.of(origin.getX(),origin.getY(),origin.getZ()));
            result.put("sideBlocks",25);result.put("blocks",mesh.blocks());result.put("triangles",mesh.triangles());result.put("primaryRayHits",hitCount);
            result.put("rays",hits.length);result.put("sceneEpoch",scene.epoch());result.put("cameraFrustumCulling",false);
            result.put("fluidBlocksIncluded",mesh.fluidBlocks());result.put("entitiesIncluded",false);result.put("alphaTestActive",false);
            result.put("snapshotOnly",true);result.put("gameplayEffectsActive",false);
            result.put("visibilitySamplesPerEffect",32);result.put("visibilityHits",visibilityHits);
            result.put("meanAmbientVisibility",sumAo/Math.max(1,visibilityHits));result.put("meanSunVisibility",sumSun/Math.max(1,visibilityHits));
            result.put("sunDirection",List.of(-.6,.8,0));result.put("sunFollowsGameClock",false);
            Files.writeString(folder.resolve("scene-proof.json"),gson.toJson(result)+"\n");
        }
    }
}
