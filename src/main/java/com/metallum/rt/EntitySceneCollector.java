// SPDX-License-Identifier: MIT
package com.metallum.rt;

import com.mojang.blaze3d.platform.NativeImage;
import com.mojang.blaze3d.vertex.PoseStack;
import com.mojang.blaze3d.vertex.VertexConsumer;
import it.unimi.dsi.fastutil.floats.FloatArrayList;
import net.minecraft.client.Minecraft;
import net.minecraft.client.model.Model;
import net.minecraft.client.model.geom.PartPose;
import net.minecraft.client.renderer.SubmitNodeCollection;
import net.minecraft.client.renderer.SubmitNodeStorage;
import net.minecraft.client.renderer.feature.ModelFeatureRenderer;
import net.minecraft.client.renderer.rendertype.RenderType;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import net.minecraft.client.renderer.texture.DynamicTexture;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import net.minecraft.core.BlockPos;
import net.minecraft.resources.Identifier;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.phys.AABB;
import java.util.*;

/** Main-thread capture of actual posed model quads, independent of view culling. */
public final class EntitySceneCollector {
    public record Vertex(float x,float y,float z,float u,float v,int color) {}
    public record Texture(int width,int height,int[] pixels) {}
    private record Cached(Object gpu,Texture image) {}
    private static final Map<Identifier,Cached> TEXTURES=new LinkedHashMap<>();
    public record Mesh(float[] vertices,SceneMaterials.Payload materials,int entities,int models,int skipped,List<String> notes,long captureNanos) {
        public Mesh {vertices=vertices.clone();notes=List.copyOf(notes);}
        @Override public float[] vertices(){return vertices.clone();}
        public int triangles(){return vertices.length/9;}
    }
    private final FloatArrayList vertices=new FloatArrayList();
    private final SceneMaterials materials=new SceneMaterials();
    private final List<String> notes=new ArrayList<>();
    private int models,skipped;
    private static Texture pixels(NativeImage source){
        int width=source.getWidth(),height=source.getHeight();
        if(source.isClosed()||width<=0||height<=0||(long)width*height>16*1024*1024)throw new IllegalStateException("Invalid entity texture");
        int[] data=new int[width*height];for(int y=0;y<height;y++)for(int x=0;x<width;x++)data[y*width+x]=source.getPixel(x,y);
        return new Texture(width,height,data);
    }
    private static Texture texture(Identifier id)throws Exception {
        var mc=Minecraft.getInstance();var texture=mc.getTextureManager().getTexture(id);
        if(texture instanceof DynamicTexture dynamic&&dynamic.getPixels()!=null)return pixels(dynamic.getPixels());
        var cached=TEXTURES.get(id);Object gpu=texture.getTexture();
        if(cached!=null&&cached.gpu==gpu)return cached.image;
        try(var stream=mc.getResourceManager().getResourceOrThrow(id).open();var image=NativeImage.read(stream)){
            var result=pixels(image);if(TEXTURES.size()>=256)TEXTURES.clear();TEXTURES.put(id,new Cached(gpu,result));return result;
        }
    }
    public static Mesh capture(BlockPos origin,int side,CameraRenderState camera){
        return capture(origin,new AABB(origin.getX(),origin.getY(),origin.getZ(),origin.getX()+side,origin.getY()+side,origin.getZ()+side),camera);
    }
    public static Mesh capture(BlockPos origin,AABB bounds,CameraRenderState camera){
        long start=System.nanoTime();var collector=new EntitySceneCollector();var mc=Minecraft.getInstance();
        List<Entity> entities=new ArrayList<>();
        for(var entity:mc.level.entitiesForRendering()){
            if(entity.isRemoved()||entity.isInvisible()||!entity.getBoundingBox().intersects(bounds))continue;
            if(entity==mc.getCameraEntity()&&!mc.gameRenderer.mainCamera().isDetached())continue;
            entities.add(entity);
        }
        entities.sort(Comparator.comparingDouble((Entity e)->e.position().distanceToSqr(camera.pos)).thenComparingInt(Entity::getId));
        int limit=Math.max(1,Math.min(128,Integer.getInteger("metallum.rt.entityLimit",32))),captured=0,considered=0;
        float partial=mc.getDeltaTracker().getGameTimeDeltaPartialTick(true);var dispatcher=mc.getEntityRenderDispatcher();
        for(var entity:entities){
            if(considered++>=limit){collector.skipped++;continue;}
            int before=collector.vertices.size();
            try{
                var state=dispatcher.extractEntity(entity,partial);var storage=collector.new Storage();
                dispatcher.submit(state,camera,state.x-origin.getX(),state.y-origin.getY(),state.z-origin.getZ(),new PoseStack(),storage);
                if(collector.vertices.size()>before)captured++;
                else{collector.skipped++;collector.note("No supported model geometry: "+entity.getType());}
            }catch(Exception error){collector.skipped++;collector.note(entity.getType()+": "+error.getClass().getSimpleName()+" "+error.getMessage());}
        }
        return new Mesh(collector.vertices.toFloatArray(),collector.materials.finish(),captured,collector.models,collector.skipped,collector.notes,System.nanoTime()-start);
    }
    private void note(String text){if(notes.size()<12)notes.add(text);}
    private final class Storage extends SubmitNodeStorage {
        private final SubmitNodeCollection collection=new SubmitNodeCollection(){
            @Override public <S> void submitModel(Model<? super S> model,S state,PoseStack pose,RenderType type,int light,int overlay,int color,TextureAtlasSprite sprite,int outline,ModelFeatureRenderer.CrumblingOverlay crumbling){captureModel(model,state,pose,type,light,overlay,color,sprite);}
        };
        @Override public SubmitNodeCollection order(int order){return collection;}
        @Override public <S> void submitModel(Model<? super S> model,S state,PoseStack pose,RenderType type,int light,int overlay,int color,TextureAtlasSprite sprite,int outline,ModelFeatureRenderer.CrumblingOverlay crumbling){captureModel(model,state,pose,type,light,overlay,color,sprite);}
    }
    private <S> void captureModel(Model<? super S> model,S state,PoseStack pose,RenderType type,int light,int overlay,int color,TextureAtlasSprite sprite){
        // Additive/translucent layers require their own transport model; do not
        // turn glowing eyes or slime overlays into opaque duplicate surfaces.
        if(type.hasBlending()||type.isOutline()){skipped++;return;}
        var parts=model.allParts();PartPose[] saved=new PartPose[parts.size()];boolean[] visible=new boolean[parts.size()],skipDraw=new boolean[parts.size()];
        for(int i=0;i<parts.size();i++){var part=parts.get(i);saved[i]=part.storePose();visible[i]=part.visible;skipDraw[i]=part.skipDraw;}
        try{
            Texture image;Identifier id;
            if(sprite!=null){
                var contents=sprite.contents();id=contents.name();var source=((com.metallum.mixin.render.RtSpriteContentsAccessor)(Object)contents).metallum$originalImage();
                int width=contents.width(),height=contents.height(),frame=!contents.isAnimated()||contents.getUniqueFrames().isEmpty()?0:contents.getUniqueFrames().getInt(0);
                int columns=source.getWidth()/width,bx=frame%columns*width,by=frame/columns*height;int[] data=new int[width*height];
                for(int y=0;y<height;y++)for(int x=0;x<width;x++)data[y*width+x]=source.getPixel(bx+x,by+y);
                image=new Texture(width,height,data);
            }
            else{var binding=type.state.textures.get("Sampler0");if(binding==null){skipped++;note("No Sampler0: "+type);return;}id=binding.location();image=texture(id);}
            var output=new Vertices();model.setupAnim(state);model.renderToBuffer(pose,output,light,overlay,color);output.finish();
            if(output.values.size()%4!=0)throw new IllegalStateException("Model did not emit complete quads");
            if(vertices.size()/9+output.values.size()/2>100000)throw new IllegalStateException("Entity triangle budget exceeded");
            for(int q=0;q<output.values.size();q+=4)for(int[] indices:new int[][]{{0,1,2},{0,2,3}}){
                Vertex[] triangle={output.values.get(q+indices[0]),output.values.get(q+indices[1]),output.values.get(q+indices[2])};
                materials.appendEntity(image,triangle);
                for(var v:triangle){vertices.add(v.x);vertices.add(v.y);vertices.add(v.z);}
            }
            models++;note(id+": "+output.values.size()/2+" triangles");
        }catch(Exception error){skipped++;note("Model skipped: "+error.getClass().getSimpleName()+" "+error.getMessage());}
        finally{for(int i=0;i<parts.size();i++){var part=parts.get(i);part.loadPose(saved[i]);part.visible=visible[i];part.skipDraw=skipDraw[i];}}
    }
    private static final class Vertices implements VertexConsumer {
        private final List<Vertex> values=new ArrayList<>();private boolean pending;private float x,y,z,u,v;private int color=0xffffffff;
        void finish(){if(pending){values.add(new Vertex(x,y,z,u,v,color));pending=false;}}
        @Override public VertexConsumer addVertex(float x,float y,float z){finish();this.x=x;this.y=y;this.z=z;u=v=0;color=0xffffffff;pending=true;return this;}
        @Override public void addVertex(float x,float y,float z,int color,float u,float v,int overlay,int light,float nx,float ny,float nz){finish();values.add(new Vertex(x,y,z,u,v,color));}
        @Override public VertexConsumer setColor(int r,int g,int b,int a){color=(a<<24)|(r<<16)|(g<<8)|b;return this;}
        @Override public VertexConsumer setColor(int color){this.color=color;return this;}
        @Override public VertexConsumer setUv(float u,float v){this.u=u;this.v=v;return this;}
        @Override public VertexConsumer setUv1(int u,int v){return this;}
        @Override public VertexConsumer setUv2(int u,int v){return this;}
        @Override public VertexConsumer setNormal(float x,float y,float z){return this;}
        @Override public VertexConsumer setLineWidth(float width){return this;}
    }
}
