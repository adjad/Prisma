// SPDX-License-Identifier: MIT
package com.metallum.rt;

import com.metallum.mixin.render.RtSpriteContentsAccessor;
import it.unimi.dsi.fastutil.ints.IntArrayList;
import net.minecraft.client.Minecraft;
import net.minecraft.client.model.geom.builders.UVPair;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.texture.SpriteContents;
import net.minecraft.client.resources.model.geometry.BakedQuad;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.level.block.state.BlockState;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.List;

/** Immutable native material payload. Physical properties are explicit development defaults. */
public final class SceneMaterials {
    public record Payload(byte[] triangles,int[] texels) {
        public Payload {triangles=triangles.clone();texels=texels.clone();}
        public boolean sameContents(Payload other){return java.util.Arrays.equals(triangles,other.triangles)&&java.util.Arrays.equals(texels,other.texels);}
        public SceneLights.Emitters emitters(float[] vertices){return SceneLights.fromQuads(vertices,triangles,texels);}
        public long byteSize(){return triangles.length+(long)texels.length*4;}
        @Override public byte[] triangles(){return triangles.clone();}
        @Override public int[] texels(){return texels.clone();}
    }
    private record Image(int offset,int width,int height) {}
    private final IdentityHashMap<SpriteContents,Image> images=new IdentityHashMap<>();
    private final IdentityHashMap<int[],Image> entityImages=new IdentityHashMap<>();
    private final IntArrayList texels=new IntArrayList();
    private final List<byte[]> triangles=new ArrayList<>();
    private static final int MAX_TEXELS=16*1024*1024;
    private Image image(SpriteContents contents) {
        return images.computeIfAbsent(contents,key->{
            var source=((RtSpriteContentsAccessor)(Object)key).metallum$originalImage();
            if(source.isClosed())throw new IllegalStateException("Closed sprite during RT snapshot");
            int width=key.width(),height=key.height();
            if(width<=0||height<=0||(long)texels.size()+(long)width*height>MAX_TEXELS)throw new IllegalStateException("RT sprite budget exceeded");
            // 26.2 returns [1] for nonanimated getUniqueFrames(); those images begin at (0,0).
            int frame=!key.isAnimated()||key.getUniqueFrames().isEmpty()?0:key.getUniqueFrames().getInt(0);
            int columns=source.getWidth()/width;
            if(columns<1||frame<0||(long)(frame/columns+1)*height>source.getHeight())throw new IllegalStateException("Invalid RT sprite frame: "+key.name());
            int baseX=(frame%columns)*width,baseY=(frame/columns)*height;
            Image result=new Image(texels.size(),width,height);
            for(int y=0;y<height;y++)for(int x=0;x<width;x++)texels.add(source.getPixel(baseX+x,baseY+y));
            return result;
        });
    }
    public void append(BlockState state,BlockPos pos,ClientLevel level,BakedQuad quad,int a,int b,int c) {
        var material=quad.materialInfo();var sprite=material.sprite();var image=image(sprite.contents());
        var bytes=ByteBuffer.allocate(96).order(ByteOrder.nativeOrder());
        int tint=0xffffffff;
        if(material.isTinted()){
            var source=Minecraft.getInstance().getBlockColors().getTintSource(state,material.tintIndex());
            if(source!=null)tint=level==null?source.color(state):source.colorInWorld(state,level,pos);
        }
        for(int shift:new int[]{16,8,0})bytes.putFloat(linear((tint>>>shift)&255));bytes.putFloat(1);
        String block=BuiltInRegistries.BLOCK.getKey(state.getBlock()).toString();
        boolean metal=block.equals("minecraft:gold_block")||block.equals("minecraft:iron_block")||block.equals("minecraft:copper_block")||block.equals("minecraft:cut_copper");
        boolean glass=block.contains("glass")||block.equals("minecraft:ice");
        float roughness=metal?.2f:glass?.04f:.85f;
        float emission=Math.max(state.getLightEmission(),material.lightEmission())/15.f;
        bytes.putFloat(roughness).putFloat(metal?1:0).putFloat(emission*2).putFloat(glass?.98f:0);
        for(int vertex:new int[]{a,b,c}){
            long packed=quad.packedUV(vertex);
            bytes.putFloat((UVPair.unpackU(packed)-sprite.getU0())/(sprite.getU1()-sprite.getU0()));
            bytes.putFloat((UVPair.unpackV(packed)-sprite.getV0())/(sprite.getV1()-sprite.getV0()));
        }
        bytes.putFloat(0).putFloat(0);
        boolean cutout=!glass&&material.layer().name().equals("CUTOUT");
        bytes.putFloat(1.5f).putFloat(cutout?.5f:0).putFloat(1).putFloat(0);
        bytes.putInt(image.offset).putInt(image.width).putInt(image.height).putInt(cutout?1:0);
        triangles.add(bytes.array());
    }
    public void appendFluid(BlockState state,FluidSceneCollector.Quad quad,int[] indices){
        var sprite=quad.sprite();var image=image(sprite.contents());
        var bytes=ByteBuffer.allocate(96).order(ByteOrder.nativeOrder());
        for(int shift:new int[]{16,8,0})bytes.putFloat(linear((quad.tint()>>>shift)&255));bytes.putFloat(1);
        boolean water=state.getFluidState().is(net.minecraft.tags.FluidTags.WATER);
        bytes.putFloat(water?.04f:.85f).putFloat(0).putFloat(state.getLightEmission()/15.f*2).putFloat(water?.995f:0);
        for(int i:indices){var v=quad.vertices().get(i);bytes.putFloat((v.u()-sprite.getU0())/(sprite.getU1()-sprite.getU0()));bytes.putFloat((v.v()-sprite.getV0())/(sprite.getV1()-sprite.getV0()));}
        bytes.putFloat(0).putFloat(0);
        bytes.putFloat(water?1.333f:1.5f).putFloat(0).putFloat(1).putFloat(water?.4f:0);
        bytes.putInt(image.offset).putInt(image.width).putInt(image.height).putInt(0);
        triangles.add(bytes.array());
    }
    private static float linear(int channel){float v=channel/255.f;return v<=.04045f?v/12.92f:(float)Math.pow((v+.055f)/1.055f,2.4);}
    public void appendEntity(EntitySceneCollector.Texture texture,EntitySceneCollector.Vertex[] vertices){
        var image=entityImages.computeIfAbsent(texture.pixels(),pixels->{
            if((long)texels.size()+pixels.length>MAX_TEXELS)throw new IllegalStateException("Entity texture budget exceeded");
            var value=new Image(texels.size(),texture.width(),texture.height());texels.addElements(texels.size(),pixels);return value;
        });
        var bytes=ByteBuffer.allocate(96).order(ByteOrder.nativeOrder());int color=vertices[0].color();
        for(int shift:new int[]{16,8,0})bytes.putFloat(linear((color>>>shift)&255));bytes.putFloat(((color>>>24)&255)/255.f);
        bytes.putFloat(.85f).putFloat(0).putFloat(0).putFloat(0);
        for(var vertex:vertices)bytes.putFloat(vertex.u()).putFloat(vertex.v());bytes.putFloat(0).putFloat(0);
        bytes.putFloat(1.5f).putFloat(.1f).putFloat(1).putFloat(0);
        bytes.putInt(image.offset).putInt(image.width).putInt(image.height).putInt(1);triangles.add(bytes.array());
    }
    public Payload finish(){
        var data=ByteBuffer.allocate(Math.multiplyExact(triangles.size(),96));for(var triangle:triangles)data.put(triangle);
        return new Payload(data.array(),texels.toIntArray());
    }
}
