// SPDX-License-Identifier: MIT
package com.metallum.rt;

import net.minecraft.core.BlockPos;
import it.unimi.dsi.fastutil.floats.FloatArrayList;
import it.unimi.dsi.fastutil.ints.IntArrayList;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.*;

/** Split a main-thread model snapshot by its owning section, with local textures/vertices. */
public final class ChunkMeshSnapshot {
    private record Image(int offset,int width,int height) {}
    private static final class Part {
        final FloatArrayList vertices=new FloatArrayList();
        final ByteArrayOutputStream materials=new ByteArrayOutputStream();
        final IntArrayList texels=new IntArrayList();
        final Map<Image,Integer> images=new HashMap<>();
    }
    public static List<NativeRtScene.Chunk> split(BlockSceneSnapshot.Mesh mesh,BlockPos sceneOrigin){
        float[] vertices=mesh.vertices();byte[] materials=mesh.materials().triangles();int[] texels=mesh.materials().texels();long[] keys=mesh.sectionKeys();
        if(keys.length!=mesh.triangles())throw new IllegalArgumentException("Missing section ownership");
        var parts=new TreeMap<Long,Part>();
        for(int triangle=0;triangle<keys.length;triangle++){
            long key=keys[triangle];var part=parts.computeIfAbsent(key,k->new Part());
            int x=BlockPos.getX(key)*16,y=BlockPos.getY(key)*16,z=BlockPos.getZ(key)*16;
            for(int v=0;v<3;v++){
                int at=triangle*9+v*3;
                part.vertices.add(vertices[at]+sceneOrigin.getX()-x);
                part.vertices.add(vertices[at+1]+sceneOrigin.getY()-y);
                part.vertices.add(vertices[at+2]+sceneOrigin.getZ()-z);
            }
            byte[] bytes=Arrays.copyOfRange(materials,triangle*96,(triangle+1)*96);var data=ByteBuffer.wrap(bytes).order(ByteOrder.nativeOrder());
            var image=new Image(data.getInt(80),data.getInt(84),data.getInt(88));
            int offset=part.images.computeIfAbsent(image,i->{
                int base=part.texels.size(),count=Math.multiplyExact(i.width(),i.height());
                part.texels.addElements(base,texels,i.offset(),count);return base;
            });
            data.putInt(80,offset);part.materials.writeBytes(bytes);
        }
        var result=new ArrayList<NativeRtScene.Chunk>();
        for(var entry:parts.entrySet()){
            long key=entry.getKey();var part=entry.getValue();
            result.add(new NativeRtScene.Chunk(key,BlockPos.getX(key)*16-sceneOrigin.getX(),BlockPos.getY(key)*16-sceneOrigin.getY(),BlockPos.getZ(key)*16-sceneOrigin.getZ(),part.vertices.toFloatArray(),new SceneMaterials.Payload(part.materials.toByteArray(),part.texels.toIntArray())));
        }
        return List.copyOf(result);
    }
    private ChunkMeshSnapshot() {}
}
