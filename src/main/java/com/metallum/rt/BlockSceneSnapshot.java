// SPDX-License-Identifier: MIT
package com.metallum.rt;

import it.unimi.dsi.fastutil.floats.FloatArrayList;
import it.unimi.dsi.fastutil.longs.LongArrayList;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.model.geom.builders.UVPair;
import net.minecraft.client.renderer.block.BlockStateModelSet;
import net.minecraft.client.renderer.block.dispatch.BlockStateModelPart;
import net.minecraft.client.resources.model.geometry.BakedQuad;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.RenderShape;
import net.minecraft.world.level.block.state.BlockState;
import java.util.ArrayList;
import java.util.List;

/** Main-thread model snapshot. No camera/frustum or primary-view entity culling inputs. */
public final class BlockSceneSnapshot {
    public record Surface(String block, String layer, String atlas, String sprite, int tintIndex,
                          int lightEmission, int flags, long uv0, long uv1, long uv2) {}
    public record Mesh(float[] vertices, List<Surface> surfaces, int blocks, int fluidBlocks, SceneMaterials.Payload materials, long[] sectionKeys) {
        public Mesh { vertices = vertices.clone(); surfaces = List.copyOf(surfaces); sectionKeys=sectionKeys.clone(); }
        @Override public long[] sectionKeys(){return sectionKeys.clone();}
        @Override public float[] vertices() { return vertices.clone(); }
        public int triangles() { return vertices.length / 9; }
    }
    private final SceneMaterials materials = new SceneMaterials();
    private final LongArrayList sections=new LongArrayList();
    private final FloatArrayList vertices = new FloatArrayList();
    private final List<Surface> surfaces = new ArrayList<>();
    private final List<BlockStateModelPart> parts = new ArrayList<>();
    private final RandomSource random = RandomSource.create(0);
    private int blocks, fluidBlocks;
    private boolean diagnostics=true;
    private static final int MAX_TRIANGLES = 1_000_000;

    /** Bounded main-thread collection; no world or model access occurs on the build worker. */
    public static final class Cursor {
        private final BlockSceneSnapshot snapshot=new BlockSceneSnapshot();
        private final BlockPos origin;
        private final int side;
        private int index;
        public Cursor(BlockPos origin,int side) {this(origin,side,true);}
        public Cursor(BlockPos origin,int side,boolean diagnostics) {
            snapshot.diagnostics=diagnostics;
            if(side<1||side>32)throw new IllegalArgumentException("Snapshot side must be 1..32");
            this.origin=origin;this.side=side;
        }
        public boolean step(ClientLevel level,BlockStateModelSet models,int maxBlocks) {
            return step(level,models,maxBlocks,Long.MAX_VALUE);
        }
        public boolean step(ClientLevel level,BlockStateModelSet models,int maxBlocks,long deadline) {
            int end=Math.min(side*side*side,index+maxBlocks);
            for(;index<end;index++) {
                if((index&15)==0&&System.nanoTime()>=deadline)return false;
                int x=index%side,y=(index/side)%side,z=index/(side*side);
                var pos=origin.offset(x,y,z);if(!level.hasChunkAt(pos))continue;
                var state=level.getBlockState(pos);if(!state.getFluidState().isEmpty())snapshot.appendFluid(state,pos,origin,level);
                if(state.getRenderShape()==RenderShape.MODEL)snapshot.append(models,state,pos,origin,level);
            }
            return index==side*side*side;
        }
        public Mesh finish(){if(index!=side*side*side)throw new IllegalStateException("Incomplete snapshot");return snapshot.finish();}
        public BlockPos origin(){return origin;}
    }

    public static Mesh capture(ClientLevel level, BlockStateModelSet models, BlockPos origin, int size) {
        if (size < 1 || size > 32) throw new IllegalArgumentException("Snapshot side must be 1..32 blocks");
        var snapshot = new BlockSceneSnapshot();
        for (int z=0; z<size; z++) for (int y=0; y<size; y++) for (int x=0; x<size; x++) {
            var pos = origin.offset(x,y,z);
            if (!level.hasChunkAt(pos)) continue;
            var state = level.getBlockState(pos);
            if (!state.getFluidState().isEmpty()) snapshot.appendFluid(state,pos,origin,level);
            if (state.getRenderShape() != RenderShape.MODEL) continue;
            snapshot.append(models, state, pos, origin, level);
        }
        return snapshot.finish();
    }
    public static Mesh model(BlockStateModelSet models, BlockState state) {
        var snapshot = new BlockSceneSnapshot();
        snapshot.append(models, state, BlockPos.ZERO, BlockPos.ZERO, null);
        return snapshot.finish();
    }
    private Mesh finish() { return new Mesh(vertices.toFloatArray(), surfaces, blocks, fluidBlocks, materials.finish(), sections.toLongArray()); }
    private void append(BlockStateModelSet models, BlockState state, BlockPos pos, BlockPos origin, ClientLevel level) {
        blocks++;
        parts.clear(); random.setSeed(state.getSeed(pos));
        models.get(state).collectParts(random, parts);
        var offset = state.getOffset(pos);
        float x = (float)(pos.getX()-origin.getX()+offset.x), y=(float)(pos.getY()-origin.getY()+offset.y), z=(float)(pos.getZ()-origin.getZ()+offset.z);
        for (var part : parts) {
            for (var quad : part.getQuads(null)) appendQuad(state,pos,level,quad,x,y,z);
            for (var side : Direction.values()) {
                if (level != null && !Block.shouldRenderFace(state, level.getBlockState(pos.relative(side)), side)) continue;
                for (var quad : part.getQuads(side)) appendQuad(state,pos,level,quad,x,y,z);
            }
        }
    }
    private void appendFluid(BlockState state,BlockPos pos,BlockPos origin,ClientLevel level) {
        fluidBlocks++;
        for(var quad:FluidSceneCollector.capture(level,state,pos,origin)){
            if(vertices.size()/9+2>MAX_TRIANGLES)throw new IllegalStateException("Snapshot triangle budget exceeded");
            for(int[] indices:new int[][]{{0,1,2},{0,2,3}}){
                long[] uv=new long[3];int index=0;
                for(int i:indices){var v=quad.vertices().get(i);vertices.add(v.x());vertices.add(v.y());vertices.add(v.z());uv[index++]=UVPair.pack(v.u(),v.v());}
                materials.appendFluid(state,quad,indices);
                sections.add(BlockPos.asLong(pos.getX()>>4,pos.getY()>>4,pos.getZ()>>4));
                if(diagnostics)surfaces.add(new Surface(BuiltInRegistries.BLOCK.getKey(state.getBlock()).toString(),"FLUID",quad.sprite().atlasLocation().toString(),quad.sprite().contents().name().toString(),0,state.getLightEmission(),0,uv[0],uv[1],uv[2]));
            }
        }
    }
    private void appendQuad(BlockState state, BlockPos pos, ClientLevel level, BakedQuad quad, float x, float y, float z) {
        if (vertices.size()/9+2 > MAX_TRIANGLES) throw new IllegalStateException("Snapshot triangle budget exceeded");
        appendTriangle(state,pos,level,quad,0,1,2,x,y,z);
        appendTriangle(state,pos,level,quad,0,2,3,x,y,z);
    }
    private void appendTriangle(BlockState state, BlockPos pos, ClientLevel level, BakedQuad quad, int a, int b, int c, float x, float y, float z) {
        for (int i : new int[]{a,b,c}) {
            var p=quad.position(i); vertices.add(p.x()+x); vertices.add(p.y()+y); vertices.add(p.z()+z);
        }
        materials.append(state,pos,level,quad,a,b,c);
        sections.add(BlockPos.asLong(pos.getX()>>4,pos.getY()>>4,pos.getZ()>>4));
        var m=quad.materialInfo();
        if(diagnostics)surfaces.add(new Surface(BuiltInRegistries.BLOCK.getKey(state.getBlock()).toString(), m.layer().toString(),
            m.sprite().atlasLocation().toString(), m.sprite().contents().name().toString(), m.tintIndex(),
            Math.max(m.lightEmission(),state.getLightEmission()),m.flags(),quad.packedUV(a),quad.packedUV(b),quad.packedUV(c)));
    }
}
