// SPDX-License-Identifier: MIT
package com.metallum.rt;

import com.mojang.blaze3d.vertex.VertexConsumer;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.block.FluidRenderer;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.state.BlockState;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Captures vanilla 26.2 fluid quads, including corner heights, flow UVs and waterlogging. */
final class FluidSceneCollector implements VertexConsumer {
    record Vertex(float x,float y,float z,float u,float v) {}
    record Quad(List<Vertex> vertices,TextureAtlasSprite sprite,int tint) {}
    private final List<Vertex> vertices=new ArrayList<>();
    static List<Quad> capture(ClientLevel level,BlockState state,BlockPos pos,BlockPos origin) {
        var models=Minecraft.getInstance().getModelManager().getFluidStateModelSet();
        var model=models.get(state.getFluidState());
        var collector=new FluidSceneCollector();
        new FluidRenderer(models).tesselate(level,pos,layer->collector,state,state.getFluidState());
        if(collector.vertices.size()%4!=0)throw new IllegalStateException("Incomplete fluid quad");
        var sprites=new ArrayList<TextureAtlasSprite>();
        sprites.add(model.stillMaterial().sprite());sprites.add(model.flowingMaterial().sprite());
        if(model.overlayMaterial()!=null)sprites.add(model.overlayMaterial().sprite());
        int tint=model.tintSource()==null?0xffffffff:model.tintSource().colorInWorld(state,level,pos);
        // Vanilla emits section-local coordinates; convert to this RT scene's origin.
        float dx=(pos.getX()&~15)-origin.getX(),dy=(pos.getY()&~15)-origin.getY(),dz=(pos.getZ()&~15)-origin.getZ();
        List<Quad> result=new ArrayList<>();Set<List<String>> seen=new HashSet<>();
        for(int i=0;i<collector.vertices.size();i+=4){
            var quad=collector.vertices.subList(i,i+4);
            // Raster needs reversed back faces; Metal intersections are already two-sided.
            var key=quad.stream().map(v->v.x+","+v.y+","+v.z).sorted().toList();
            if(!seen.add(key))continue;
            var sprite=sprites.stream().filter(s->quad.stream().allMatch(v->v.u>=s.getU0()-.000001f&&v.u<=s.getU1()+.000001f&&v.v>=s.getV0()-.000001f&&v.v<=s.getV1()+.000001f)).findFirst()
                .orElseThrow(()->new IllegalStateException("Fluid UV outside its model sprites"));
            result.add(new Quad(quad.stream().map(v->new Vertex(v.x+dx,v.y+dy,v.z+dz,v.u,v.v)).toList(),sprite,tint));
        }
        return result;
    }
    // FluidRenderer.vertex calls this complete-vertex overload in 26.2.
    @Override public void addVertex(float x,float y,float z,int color,float u,float v,int overlay,int light,float nx,float ny,float nz){vertices.add(new Vertex(x,y,z,u,v));}
    private static UnsupportedOperationException incomplete(){return new UnsupportedOperationException("Fluid renderer changed its complete vertex contract");}
    @Override public VertexConsumer addVertex(float x,float y,float z){throw incomplete();}
    @Override public VertexConsumer setColor(int r,int g,int b,int a){throw incomplete();}
    @Override public VertexConsumer setColor(int color){throw incomplete();}
    @Override public VertexConsumer setUv(float u,float v){throw incomplete();}
    @Override public VertexConsumer setUv1(int u,int v){throw incomplete();}
    @Override public VertexConsumer setUv2(int u,int v){throw incomplete();}
    @Override public VertexConsumer setNormal(float x,float y,float z){throw incomplete();}
    @Override public VertexConsumer setLineWidth(float width){throw incomplete();}
}
