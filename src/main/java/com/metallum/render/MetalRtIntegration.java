// SPDX-License-Identifier: MIT
package com.metallum.render;

import com.metallum.Metallum;
import com.metallum.rt.BlockSceneSnapshot;
import com.metallum.rt.SectionSceneCollector;
import com.metallum.rt.NativeRtScene;
import com.metallum.rt.EntitySceneCollector;
import com.metallum.rt.SceneLights;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import net.minecraft.core.BlockPos;
import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;

/** Experimental live visibility. All scene ownership transfers happen at frame boundaries. */
public final class MetalRtIntegration implements AutoCloseable {
    private static MetalRtIntegration active;
    private static final AtomicLong EDITS=new AtomicLong();
    private final MetalDevice device;
    private final ExecutorService worker=Executors.newSingleThreadExecutor(r->{var t=new Thread(r,"Metal RT scene builder");t.setDaemon(true);return t;});
    private volatile boolean closed;
    private boolean failed;
    private ClientLevel level;
    private SectionSceneCollector collector;
    private long seenEdits, generation;
    private CompletableFuture<Scene> pending;
    private Scene current,lastLightScene;private boolean lastLightsEnabled;
    private NativeRtScene.ChunkCache chunkCache;
    private long chunkBuilt,chunkReused,chunkRemoved;
    private EntitySceneCollector.Mesh lastEntities;
    public record EntityStatistics(int entities,int models,int skipped,int triangles,double captureMs,String origin,String bounds,java.util.List<String> notes,NativeRtScene.DynamicStatistics nativeState) {}
    public static EntityStatistics entityStatistics(){
        if(active==null||active.current==null)return null;var mesh=active.lastEntities;
        float[] bounds={Float.POSITIVE_INFINITY,Float.POSITIVE_INFINITY,Float.POSITIVE_INFINITY,Float.NEGATIVE_INFINITY,Float.NEGATIVE_INFINITY,Float.NEGATIVE_INFINITY};
        if(mesh!=null){var xyz=mesh.vertices();for(int i=0;i<xyz.length;i++){int axis=i%3;bounds[axis]=Math.min(bounds[axis],xyz[i]);bounds[axis+3]=Math.max(bounds[axis+3],xyz[i]);}}
        return new EntityStatistics(mesh==null?0:mesh.entities(),mesh==null?0:mesh.models(),mesh==null?0:mesh.skipped(),mesh==null?0:mesh.triangles(),mesh==null?0:mesh.captureNanos()/1e6,active.current.origin.toString(),java.util.Arrays.toString(bounds),mesh==null?java.util.List.of():mesh.notes(),active.current.nativeScene.dynamicStatistics());
    }
    private BlockPos pendingOrigin;
    private Matrix4f worldProjection;
    private long frames, published, invalidations, lastBuildFrame;
    private record Scene(NativeRtScene nativeScene,BlockPos origin,long generation,long revision,int triangles,int width,SceneLights.Selection lights) implements AutoCloseable {
        public void close(){nativeScene.close();}
    }
    static void install(MetalDevice device){if(active!=null)active.close();active=new MetalRtIntegration(device);}
    static void uninstall(MetalDevice device){if(active!=null&&active.device==device){active.close();active=null;}}
    private MetalRtIntegration(MetalDevice device){this.device=device;}
    public record ChunkSceneStatistics(long published,long totalBuilt,long totalReused,long totalRemoved,String origin,NativeRtScene.ChunkStatistics current) {}
    public static ChunkSceneStatistics chunkStatistics(){return active!=null&&active.current!=null?new ChunkSceneStatistics(active.published,active.chunkBuilt,active.chunkReused,active.chunkRemoved,active.current.origin.toString(),active.current.nativeScene.chunkStatistics()):null;}
    public record LightStatistics(int available,int selected,int unsupported,NativeRtScene.LightStatistics nativeState) {}
    public static LightStatistics lightStatistics(){if(active==null||active.current==null)return null;var s=active.current;return new LightStatistics(s.lights.available(),s.lights.lights().size(),s.lights.unsupported(),s.nativeScene.lightStatistics());}
    public static NativeRtScene.AttributeStatistics attributeStatistics(){return active!=null&&active.current!=null?active.current.nativeScene.attributeStatistics():null;}
    public static NativeRtScene.FrameStatistics statistics(){return active!=null&&active.current!=null?active.current.nativeScene.frameStatistics():null;}
    public static NativeRtScene.MetalFxStatistics metalFxStatistics(){return active!=null&&active.current!=null?active.current.nativeScene.metalFxStatistics():null;}
    public static String controlStatus() {
        if (active == null) return "Metal renderer unavailable";
        if (active.failed) return "Ray-tracing pass failed; raster rendering retained. Restart the game after checking the log";
        if (!System.getProperty("metallum.rt.mode", "off").equals("hybrid")) return "Ray-tracing effects off; raster rendering active";
        if (active.current == null) return "Ray scene is not ready";
        return "Hardware ray scene active: " + active.current.triangles + " static triangles";
    }
    public static void invalidate(){EDITS.incrementAndGet();}
    public static void projection(Matrix4fc matrix){if(active!=null)active.worldProjection=new Matrix4f(matrix);}
    public static void changed(ClientLevel level,BlockPos minimum,int size) {
        if(active==null||active.level!=level)return;
        if(active.collector!=null)active.collector.changed(minimum,size);
    }
    public static void afterWorld(CameraRenderState camera,Matrix4fc projection){
        if(active!=null)active.frame(camera,projection);
    }
    public static SectionSceneCollector.Statistics collectionStatistics(){return active!=null&&active.collector!=null?active.collector.statistics():null;}
    private void reset(ClientLevel newLevel) {
        if(chunkCache!=null){chunkCache.close();chunkCache=null;}
        level=newLevel;generation++;invalidations++;collector=newLevel==null?null:new SectionSceneCollector(newLevel);seenEdits=EDITS.get();
        if(current!=null){current.close();current=null;}lastLightScene=null;
    }
    private void frame(CameraRenderState camera,Matrix4fc projection) {
        if(closed||failed)return;
        String mode=System.getProperty("metallum.rt.mode","off");
        var mc=Minecraft.getInstance();
        if(!mode.equals("hybrid")||mc.level==null){if(level!=null)reset(null);return;}
        try {
            frames++;
            if(level!=mc.level||seenEdits!=EDITS.get())reset(mc.level);
            if(pending!=null&&pending.isDone()){
                Scene next=pending.join();pending=null;pendingOrigin=null;
                if(next!=null){
                    if(next.generation!=generation)next.close();
                    else {
                        if(current!=null)current.close();
                        current=next;if(chunkCache!=null)chunkCache.close();chunkCache=next.nativeScene.acquireChunkCache();
                        var stats=next.nativeScene.chunkStatistics();chunkBuilt+=stats.built();chunkReused+=stats.reused();chunkRemoved+=stats.removed();published++;
                    }
                }
            }
            collector.step(BlockPos.containing(camera.pos),mc.getModelManager().getBlockStateModelSet());
            if(pending==null&&(current==null||current.revision!=collector.revision())&&(current==null||frames-lastBuildFrame>=30)){
                var snapshot=collector.snapshot();var cache=chunkCache;long gen=generation;
                var origin=snapshot.origin();pendingOrigin=origin;lastBuildFrame=frames;
                float cx=(float)(camera.pos.x-origin.getX()),cy=(float)(camera.pos.y-origin.getY()),cz=(float)(camera.pos.z-origin.getZ());
                var retainedDevice=com.metallum.objc.ObjC.retain(device.metalDeviceHandle());
                pending=CompletableFuture.supplyAsync(()->{
                    try {
                        var scene=new NativeRtScene(retainedDevice);
                        try{if(cache!=null)cache.seed(scene);scene.buildChunks(snapshot.chunks());scene.setHorizontalCoverage(true);var lights=SceneLights.select(snapshot.chunks(),cx,cy,cz);return new Scene(scene,origin,gen,snapshot.revision(),snapshot.triangles(),snapshot.width(),lights);}
                        catch(Throwable e){scene.close();throw e;}
                    }finally{com.metallum.objc.ObjC.release(retainedDevice);}
                },worker);
                pending.thenAccept(scene->{if(closed&&scene!=null)scene.close();});
            }
            if(current==null)return;
            lastEntities=Boolean.parseBoolean(System.getProperty("metallum.rt.entities","true"))?EntitySceneCollector.capture(current.origin,new net.minecraft.world.phys.AABB(current.origin.getX(),level.getMinY(),current.origin.getZ(),current.origin.getX()+current.width,level.getMaxY()+1,current.origin.getZ()+current.width),camera):null;
            current.nativeScene.setDynamicMesh(lastEntities);
            boolean lightsEnabled=Boolean.parseBoolean(System.getProperty("metallum.rt.localLights","true"));
            if(lastLightScene!=current||lastLightsEnabled!=lightsEnabled){current.nativeScene.setAreaLights(lightsEnabled?current.lights.lights():java.util.List.of());lastLightScene=current;lastLightsEnabled=lightsEnabled;}
            var target=mc.gameRenderer.mainRenderTarget();
            if(!(target.getColorTexture() instanceof MetalGpuTexture color)||!(target.getDepthTexture() instanceof MetalGpuTexture depth))return;
            if(worldProjection==null)return;
            // LevelRenderer's matrix argument is view rotation, not projection.
            // Capture the actual world projection after hurt/bob/portal transforms.
            Matrix4f inverse=new Matrix4f(worldProjection).mul(projection).invert();
            if(Boolean.getBoolean("metallum.rt.metalfx")){
                Matrix4f view=new Matrix4f(projection).translate((float)(current.origin.getX()-camera.pos.x),(float)(current.origin.getY()-camera.pos.y),(float)(current.origin.getZ()-camera.pos.z));
                current.nativeScene.setMetalFxCamera(view.get(new float[16]),worldProjection.get(new float[16]));
            }
            float angle=mc.gameRenderer.gameRenderState().levelRenderState.skyRenderState.sunAngle;
            // SkyRenderer rotates the celestial plane about X after a -90 degree Y rotation.
            float[] sun={-(float)Math.sin(angle),(float)Math.cos(angle),0,.00465f};
            float ao=setting("metallum.rt.ao",.65f),shadows=setting("metallum.rt.shadows",.65f);
            device.createCommandEncoder().encodeRt(current.nativeScene,color,depth,inverse.get(new float[16]),
                new float[]{(float)(camera.pos.x-current.origin.getX()),(float)(camera.pos.y-current.origin.getY()),(float)(camera.pos.z-current.origin.getZ()),current.width},
                sun,new float[]{2,.003f,ao,shadows},new float[]{setting("metallum.rt.reflections",1),setting("metallum.rt.gi",1),3.1415927f,current.width},target.width,target.height,(int)frames);
            if(frames%120==0)Metallum.LOGGER.info("RT live: frames={}, scenes={}, triangles={}, invalidations={}, AO={}, shadows={}, reflections={}, GI={}",frames,published,current.triangles,invalidations,ao,shadows,setting("metallum.rt.reflections",1),setting("metallum.rt.gi",1));
        }catch(Throwable error){failed=true;Metallum.LOGGER.error("RT live pass disabled after failure; raster renderer retained",error);reset(null);}
    }
    private static float setting(String name,float fallback){try{float value=Float.parseFloat(System.getProperty(name,Float.toString(fallback)));return Float.isFinite(value)?Math.max(0,Math.min(1,value)):fallback;}catch(NumberFormatException e){return fallback;}}
    @Override public void close(){if(closed)return;closed=true;reset(null);if(pending!=null&&pending.isDone()&&!pending.isCompletedExceptionally()){Scene s=pending.join();if(s!=null)s.close();}worker.shutdown();}
}
