// SPDX-License-Identifier: MIT
package com.metallum.rt;

import java.io.IOException;
import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;
import java.nio.file.*;
import static java.lang.foreign.ValueLayout.*;

/** Owned native scene: synchronous construction/probes and asynchronous frame encoding. */
public final class NativeRtScene implements AutoCloseable {
    private final Arena arena = Arena.ofShared();
    private MemorySegment context = MemorySegment.NULL;
    private MethodHandle destroy, build, setMaterials, inheritHistory, frameStatistics, metalFxCamera, metalFxStatistics, trace, visibility, encodeFrame, error, epoch;
    private boolean closed;
    private MethodHandle setAreaLights,lightStatistics,localLighting;
    private MethodHandle setDynamic,dynamicStatistics,attributeStatistics,buildChunks,chunkStatistics,acquireChunkCache,seedChunkCache,releaseChunkCache;

    /** GPU completion blocks may run after a scene closes. Keep their native code loaded for the JVM lifetime. */
    private static final class Library {
        private static final SymbolLookup SYMBOLS=load();
        private static SymbolLookup load() {
            Path directory=null;
            try {
                directory=Files.createTempDirectory("metallum-rt-");Path library=directory.resolve("librtcore.dylib");
                try(var input=NativeRtScene.class.getResourceAsStream("/native/macos-aarch64/librtcore.dylib")){
                    if(input==null)throw new IOException("Native RT core is absent from this build");
                    Files.copy(input,library);
                }
                var symbols=SymbolLookup.libraryLookup(library,Arena.global());
                directory.toFile().deleteOnExit();library.toFile().deleteOnExit();
                return symbols;
            }catch(Throwable error){
                if(directory!=null)try{Files.deleteIfExists(directory.resolve("librtcore.dylib"));Files.deleteIfExists(directory);}catch(IOException ignored){}
                throw new IllegalStateException("Native RT library load failed",error);
            }
        }
    }

    public NativeRtScene(MemorySegment metalDevice) {
        try {
            var symbols = Library.SYMBOLS;
            var linker = Linker.nativeLinker();
            var create = linker.downcallHandle(symbols.findOrThrow("rt_create"), FunctionDescriptor.of(ADDRESS, ADDRESS, ADDRESS, ADDRESS, JAVA_LONG));
            destroy = linker.downcallHandle(symbols.findOrThrow("rt_destroy"), FunctionDescriptor.ofVoid(ADDRESS));
            build = linker.downcallHandle(symbols.findOrThrow("rt_build_triangles"), FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, JAVA_INT));
            setMaterials = linker.downcallHandle(symbols.findOrThrow("rt_set_materials"), FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, JAVA_INT, ADDRESS, JAVA_INT));
            setDynamic=linker.downcallHandle(symbols.findOrThrow("rt_set_dynamic_mesh"),FunctionDescriptor.of(JAVA_INT,ADDRESS,ADDRESS,JAVA_INT,ADDRESS,ADDRESS,JAVA_INT));
            buildChunks=linker.downcallHandle(symbols.findOrThrow("rt_build_chunks"),FunctionDescriptor.of(JAVA_INT,ADDRESS,ADDRESS,JAVA_INT));
            chunkStatistics=linker.downcallHandle(symbols.findOrThrow("rt_chunk_statistics"),FunctionDescriptor.of(JAVA_INT,ADDRESS,ADDRESS));
            acquireChunkCache=linker.downcallHandle(symbols.findOrThrow("rt_acquire_chunk_cache"),FunctionDescriptor.of(ADDRESS,ADDRESS));
            seedChunkCache=linker.downcallHandle(symbols.findOrThrow("rt_seed_chunk_cache"),FunctionDescriptor.of(JAVA_INT,ADDRESS,ADDRESS));
            releaseChunkCache=linker.downcallHandle(symbols.findOrThrow("rt_release_chunk_cache"),FunctionDescriptor.ofVoid(ADDRESS));
            attributeStatistics=linker.downcallHandle(symbols.findOrThrow("rt_attribute_statistics"),FunctionDescriptor.of(JAVA_INT,ADDRESS,ADDRESS));
            setAreaLights=linker.downcallHandle(symbols.findOrThrow("rt_set_area_lights"),FunctionDescriptor.of(JAVA_INT,ADDRESS,ADDRESS,JAVA_INT));
            lightStatistics=linker.downcallHandle(symbols.findOrThrow("rt_light_statistics"),FunctionDescriptor.of(JAVA_INT,ADDRESS,ADDRESS));
            localLighting=linker.downcallHandle(symbols.findOrThrow("rt_local_lighting"),FunctionDescriptor.of(JAVA_INT,ADDRESS,ADDRESS,ADDRESS,JAVA_INT,JAVA_INT,JAVA_INT,JAVA_FLOAT));
            dynamicStatistics=linker.downcallHandle(symbols.findOrThrow("rt_dynamic_statistics"),FunctionDescriptor.of(JAVA_INT,ADDRESS,ADDRESS));
            inheritHistory = linker.downcallHandle(symbols.findOrThrow("rt_inherit_history"),FunctionDescriptor.of(JAVA_INT,ADDRESS,ADDRESS));
            frameStatistics = linker.downcallHandle(symbols.findOrThrow("rt_frame_statistics"),FunctionDescriptor.of(JAVA_INT,ADDRESS,ADDRESS));
            metalFxCamera=linker.downcallHandle(symbols.findOrThrow("rt_set_metalfx_camera"),FunctionDescriptor.of(JAVA_INT,ADDRESS,ADDRESS,ADDRESS));
            metalFxStatistics=linker.downcallHandle(symbols.findOrThrow("rt_metalfx_statistics"),FunctionDescriptor.of(JAVA_INT,ADDRESS,ADDRESS));
            trace = linker.downcallHandle(symbols.findOrThrow("rt_trace"), FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, ADDRESS, JAVA_INT));
            visibility = linker.downcallHandle(symbols.findOrThrow("rt_visibility"), FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, ADDRESS, JAVA_INT, ADDRESS));
            encodeFrame = linker.downcallHandle(symbols.findOrThrow("rt_encode_frame"), FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, ADDRESS, ADDRESS, ADDRESS, ADDRESS));
            error = linker.downcallHandle(symbols.findOrThrow("rt_error"), FunctionDescriptor.of(ADDRESS, ADDRESS));
            epoch = linker.downcallHandle(symbols.findOrThrow("rt_scene_epoch"), FunctionDescriptor.of(JAVA_LONG, ADDRESS));
            String shader;
            try (var in = NativeRtScene.class.getResourceAsStream("/assets/metallum/rt/trace.metal")) {
                if (in == null) throw new IOException("RT shader resource is absent");
                shader = new String(in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
            }
            var message = arena.allocate(4096);
            context = (MemorySegment) create.invokeExact(metalDevice, arena.allocateFrom(shader), message, 4096L);
            if (context.address() == 0) throw new IllegalStateException(message.getString(0));
        } catch (Throwable e) {
            close(); throw new IllegalStateException("Native RT initialization failed", e);
        }
    }
    private void requireOpen() {
        if (closed) throw new IllegalStateException("RT scene is closed");
    }
    private void check(int success) throws Throwable {
        if (success == 0) {
            var pointer = (MemorySegment) error.invokeExact(context);
            throw new IllegalStateException(pointer.reinterpret(4096).getString(0));
        }
    }
    public void buildTriangles(float[] xyz) {
        requireOpen();
        if (xyz.length == 0 || xyz.length % 9 != 0) throw new IllegalArgumentException("Expected complete triangles");
        try (var temporary = Arena.ofConfined()) {
            check((int) build.invokeExact(context, temporary.allocateFrom(JAVA_FLOAT, xyz), xyz.length / 3));
        } catch (Throwable e) { throw new IllegalStateException("RT scene build failed", e); }
    }
    public static final class Chunk {
        private final long key;private final float x,y,z;private final float[] vertices;private final SceneMaterials.Payload materials;private final SceneLights.Emitters emitters;
        public Chunk(long key,float x,float y,float z,float[] vertices,SceneMaterials.Payload materials){this(key,x,y,z,vertices,materials,false,null);}
        private Chunk(long key,float x,float y,float z,float[] vertices,SceneMaterials.Payload materials,boolean shared,SceneLights.Emitters emitters){
            this.key=key;this.x=x;this.y=y;this.z=z;this.vertices=shared?vertices:vertices.clone();this.materials=materials;this.emitters=emitters==null?materials.emitters(this.vertices):emitters;
        }
        public long key(){return key;}public float x(){return x;}public float y(){return y;}public float z(){return z;}
        public float[] vertices(){return vertices.clone();}public SceneMaterials.Payload materials(){return materials;}public SceneLights.Emitters emitters(){return emitters;}
        public boolean samePayload(Chunk other){return key==other.key&&java.util.Arrays.equals(vertices,other.vertices)&&materials.sameContents(other.materials);}
        public int triangles(){return vertices.length/9;}public long byteSize(){return vertices.length*4L+materials.byteSize();}
        public Chunk translated(float x,float y,float z){return new Chunk(key,x,y,z,vertices,materials,true,emitters);}
    }
    private boolean horizontalCoverage;
    public void setHorizontalCoverage(boolean enabled){horizontalCoverage=enabled;}
    public static final class ChunkCache implements AutoCloseable {
        private MemorySegment handle;
        private final MethodHandle release;
        private ChunkCache(MemorySegment handle,MethodHandle release){this.handle=handle;this.release=release;}
        public synchronized boolean seed(NativeRtScene scene){
            if(handle.address()==0)return false;scene.requireOpen();
            try{scene.check((int)scene.seedChunkCache.invokeExact(scene.context,handle));return true;}
            catch(Throwable error){throw new IllegalStateException("RT chunk cache seed failed",error);}
        }
        @Override public synchronized void close(){
            if(handle.address()==0)return;
            try{release.invokeExact(handle);}catch(Throwable error){throw new IllegalStateException("RT chunk cache release failed",error);}
            finally{handle=MemorySegment.NULL;}
        }
    }
    public ChunkCache acquireChunkCache(){
        requireOpen();try{
            var cache=(MemorySegment)acquireChunkCache.invokeExact(context);
            if(cache.address()==0)throw new IllegalStateException("No chunk cache snapshot");
            return new ChunkCache(cache,releaseChunkCache);
        }catch(Throwable error){throw new IllegalStateException("RT chunk cache acquire failed",error);}
    }
    public void buildChunks(java.util.List<Chunk> chunks){
        requireOpen();if(chunks.size()>8192)throw new IllegalArgumentException("Too many chunk instances");
        try(var temporary=Arena.ofConfined()){
            var descriptors=chunks.isEmpty()?MemorySegment.NULL:temporary.allocate(chunks.size()*56L,8);
            for(int index=0;index<chunks.size();index++){
                var chunk=chunks.get(index);var vertices=chunk.vertices;var materials=chunk.materials().triangles();var texels=chunk.materials().texels();
                if(vertices.length==0||vertices.length%9!=0||materials.length/96!=vertices.length/9||materials.length%96!=0||texels.length==0)throw new IllegalArgumentException("Incomplete chunk payload");
                long at=index*56L;descriptors.set(JAVA_LONG,at,chunk.key());
                descriptors.set(JAVA_FLOAT,at+8,chunk.x());descriptors.set(JAVA_FLOAT,at+12,chunk.y());descriptors.set(JAVA_FLOAT,at+16,chunk.z());
                descriptors.set(JAVA_INT,at+24,vertices.length/3);descriptors.set(JAVA_INT,at+28,texels.length);
                descriptors.set(ADDRESS,at+32,temporary.allocateFrom(JAVA_FLOAT,vertices));descriptors.set(ADDRESS,at+40,temporary.allocateFrom(JAVA_BYTE,materials));descriptors.set(ADDRESS,at+48,temporary.allocateFrom(JAVA_INT,texels));
            }
            check((int)buildChunks.invokeExact(context,descriptors,chunks.size()));
        }catch(Throwable error){throw new IllegalStateException("RT chunk scene build failed",error);}
    }
    public record ChunkStatistics(long chunks,long triangles,long built,long reused,long removed,long geometryBytes,long packedBytes) {}
    public ChunkStatistics chunkStatistics(){
        requireOpen();try(var temporary=Arena.ofConfined()){
            var data=temporary.allocate(56,8);check((int)chunkStatistics.invokeExact(context,data));
            return new ChunkStatistics(data.get(JAVA_LONG,0),data.get(JAVA_LONG,8),data.get(JAVA_LONG,16),data.get(JAVA_LONG,24),data.get(JAVA_LONG,32),data.get(JAVA_LONG,40),data.get(JAVA_LONG,48));
        }catch(Throwable error){throw new IllegalStateException("RT chunk statistics failed",error);}
    }
    public void setMaterials(SceneMaterials.Payload payload) {
        requireOpen();byte[] triangles=payload.triangles();int[] texels=payload.texels();
        if(triangles.length==0||triangles.length%96!=0||texels.length==0)throw new IllegalArgumentException("Incomplete material payload");
        try(var temporary=Arena.ofConfined()){
            check((int)setMaterials.invokeExact(context,temporary.allocateFrom(JAVA_BYTE,triangles),triangles.length/96,temporary.allocateFrom(JAVA_INT,texels),texels.length));
        }catch(Throwable e){throw new IllegalStateException("RT materials failed",e);}
    }
    public boolean inheritHistory(NativeRtScene previous) {
        requireOpen();previous.requireOpen();
        try{return (int)inheritHistory.invokeExact(context,previous.context)!=0;}
        catch(Throwable e){throw new IllegalStateException("RT history transfer failed",e);}
    }
    public void setDynamicMesh(EntitySceneCollector.Mesh mesh){
        requireOpen();try(var temporary=Arena.ofConfined()){
            if(mesh==null||mesh.triangles()==0){check((int)setDynamic.invokeExact(context,MemorySegment.NULL,0,MemorySegment.NULL,MemorySegment.NULL,0));return;}
            var vertices=mesh.vertices();var materials=mesh.materials().triangles();var texels=mesh.materials().texels();
            if(materials.length!=mesh.triangles()*96)throw new IllegalArgumentException("Dynamic geometry/material mismatch");
            check((int)setDynamic.invokeExact(context,temporary.allocateFrom(JAVA_FLOAT,vertices),vertices.length/3,temporary.allocateFrom(JAVA_BYTE,materials),temporary.allocateFrom(JAVA_INT,texels),texels.length));
        }catch(Throwable error){throw new IllegalStateException("Dynamic RT mesh update failed",error);}
    }
    public void setAreaLights(java.util.List<SceneLights.AreaLight> lights) {
        requireOpen();var data=SceneLights.packLights(lights);
        try(var temporary=Arena.ofConfined()) {
            MemorySegment payload=data.length==0?MemorySegment.NULL:temporary.allocateFrom(JAVA_FLOAT,data);
            check((int)setAreaLights.invokeExact(context,payload,data.length/16));
        }catch(Throwable error){throw new IllegalStateException("RT area-light publication failed",error);}
    }
    public record LightStatistics(long count,long bytes,long revision) {}
    public LightStatistics lightStatistics() {
        requireOpen();try(var temporary=Arena.ofConfined()) {
            var output=temporary.allocate(24,8);check((int)lightStatistics.invokeExact(context,output));
            return new LightStatistics(output.get(JAVA_LONG,0),output.get(JAVA_LONG,8),output.get(JAVA_LONG,16));
        }catch(Throwable error){throw new IllegalStateException("RT light statistics failed",error);}
    }
    /** Synchronous probe only; do not call per frame on the render thread. Returns RGB and reserved zero per receiver. */
    public float[] localLighting(java.util.List<SceneLights.Receiver> receivers,int samples,int seed,float bias) {
        requireOpen();var data=SceneLights.packReceivers(receivers);int count=data.length/8;
        try(var temporary=Arena.ofConfined()) {
            var input=temporary.allocateFrom(JAVA_FLOAT,data);var output=temporary.allocate(count*16L,16);
            check((int)localLighting.invokeExact(context,input,output,count,samples,seed,bias));
            return output.toArray(JAVA_FLOAT);
        }catch(Throwable error){throw new IllegalStateException("RT local-lighting probe failed",error);}
    }
    public record DynamicStatistics(long triangles,long updates,boolean pending,long completedFrames) {}
    public DynamicStatistics dynamicStatistics(){
        requireOpen();try(var temporary=Arena.ofConfined()){
            var output=temporary.allocate(32,8);check((int)dynamicStatistics.invokeExact(context,output));
            return new DynamicStatistics(output.get(JAVA_LONG,0),output.get(JAVA_LONG,8),output.get(JAVA_LONG,16)!=0,output.get(JAVA_LONG,24));
        }catch(Throwable error){throw new IllegalStateException("Dynamic RT statistics failed",error);}
    }
    public record FrameStatistics(long encodedFrames,long completedFrames,long historyResets,double lastCommandGpuMs,double meanCommandGpuMs) {}
    public FrameStatistics frameStatistics() {
        requireOpen();try(var temporary=Arena.ofConfined()){
            var output=temporary.allocate(40,8);check((int)frameStatistics.invokeExact(context,output));
            return new FrameStatistics(output.get(JAVA_LONG,0),output.get(JAVA_LONG,8),output.get(JAVA_LONG,16),output.get(JAVA_DOUBLE,24),output.get(JAVA_DOUBLE,32));
        }catch(Throwable e){throw new IllegalStateException("RT frame statistics failed",e);}
    }
    public record AttributeStatistics(long staticBytes,long dynamicBytes) {}
    public AttributeStatistics attributeStatistics(){
        requireOpen();try(var temporary=Arena.ofConfined()){
            var output=temporary.allocate(64,8);check((int)attributeStatistics.invokeExact(context,output));
            return new AttributeStatistics(output.get(JAVA_LONG,0),output.get(JAVA_LONG,8));
        }catch(Throwable error){throw new IllegalStateException("Attribute statistics failed",error);}
    }
    public record Hit(boolean hit, float distance, int primitive) {}
    public void setMetalFxCamera(float[] view,float[] projection){
        requireOpen();if(view.length!=16||projection.length!=16)throw new IllegalArgumentException("Camera matrix layout mismatch");
        try(var temporary=Arena.ofConfined()){
            check((int)metalFxCamera.invokeExact(context,temporary.allocateFrom(JAVA_FLOAT,view),temporary.allocateFrom(JAVA_FLOAT,projection)));
        }catch(Throwable e){throw new IllegalStateException("MetalFX camera setup failed",e);}
    }
    public record MetalFxStatistics(boolean supported,boolean active,long encodedFrames,long completedFrames,long historyResets) {}
    public MetalFxStatistics metalFxStatistics(){
        requireOpen();try(var temporary=Arena.ofConfined()){
            var output=temporary.allocate(40,8);check((int)metalFxStatistics.invokeExact(context,output));
            return new MetalFxStatistics(output.get(JAVA_LONG,0)!=0,output.get(JAVA_LONG,8)!=0,output.get(JAVA_LONG,16),output.get(JAVA_LONG,24),output.get(JAVA_LONG,32));
        }catch(Throwable e){throw new IllegalStateException("MetalFX statistics failed",e);}
    }
    /** Each ray contains origin xyz, minimum distance, direction xyz, maximum distance. */
    public Hit[] trace(float[] rays) {
        requireOpen();
        if (rays.length == 0 || rays.length % 8 != 0) throw new IllegalArgumentException("Expected complete rays");
        int count = rays.length / 8;
        try (var temporary = Arena.ofConfined()) {
            var output = temporary.allocate(Math.multiplyExact((long) count, 16L), 16);
            check((int) trace.invokeExact(context, temporary.allocateFrom(JAVA_FLOAT, rays), output, count));
            Hit[] result = new Hit[count];
            for (int i = 0; i < count; i++) {
                long offset = i * 16L;
                result[i] = new Hit(output.get(JAVA_INT, offset + 8) != 0, output.get(JAVA_FLOAT, offset), output.get(JAVA_INT, offset + 4));
            }
            return result;
        } catch (Throwable e) { throw new IllegalStateException("RT trace failed", e); }
    }
    public long epoch() {
        requireOpen();
        try { return (long) epoch.invokeExact(context); }
        catch (Throwable e) { throw new IllegalStateException(e); }
    }
    public record Visibility(float ambient, float sun, float depth, boolean hit) {}
    /** Independent visibility buffers; no automatic multiplication into existing baked lighting. */
    public Visibility[] visibility(float[] rays, float sunX, float sunY, float sunZ, float angularRadius, float aoDistance, int samples, int seed) {
        requireOpen();
        if (rays.length==0 || rays.length%8!=0) throw new IllegalArgumentException("Expected complete rays");
        int count=rays.length/8;
        try(var temporary=Arena.ofConfined()) {
            var settings=temporary.allocate(32,16);
            settings.set(JAVA_FLOAT,0,sunX);settings.set(JAVA_FLOAT,4,sunY);settings.set(JAVA_FLOAT,8,sunZ);settings.set(JAVA_FLOAT,12,angularRadius);
            settings.set(JAVA_FLOAT,16,aoDistance);settings.set(JAVA_FLOAT,20,.001f);settings.set(JAVA_INT,24,samples);settings.set(JAVA_INT,28,seed);
            var output=temporary.allocate(Math.multiplyExact((long)count,16L),16);
            check((int) visibility.invokeExact(context,temporary.allocateFrom(JAVA_FLOAT,rays),output,count,settings));
            var values=new Visibility[count];
            for(int i=0;i<count;i++) {long at=i*16L;values[i]=new Visibility(output.get(JAVA_FLOAT,at),output.get(JAVA_FLOAT,at+4),output.get(JAVA_FLOAT,at+8),output.get(JAVA_FLOAT,at+12)>0);}
            return values;
        }catch(Throwable e){throw new IllegalStateException("RT visibility pass failed",e);}
    }
    public void encodeFrame(MemorySegment commandBuffer,MemorySegment color,MemorySegment depth,MemorySegment fence,float[] matrix,
                            float[] camera,float[] sun,float[] controls,float[] transport,int width,int height,int frame) {
        requireOpen();
        if(matrix.length!=16||camera.length!=4||sun.length!=4||controls.length!=4||transport.length!=4)throw new IllegalArgumentException("Frame layout mismatch");
        try(var temporary=Arena.ofConfined()) {
            var parameters=temporary.allocate(160,16);long at=0;
            for(var array:new float[][]{matrix,camera,sun,controls})for(float value:array){parameters.set(JAVA_FLOAT,at,value);at+=4;}
            parameters.set(JAVA_INT,112,(width+1)/2);parameters.set(JAVA_INT,116,(height+1)/2);
            parameters.set(JAVA_INT,120,frame);int bounces=Math.max(1,Math.min(4,Integer.getInteger("metallum.rt.bounces",1)));
            parameters.set(JAVA_INT,124,(Boolean.parseBoolean(System.getProperty("metallum.rt.temporal","true"))?0:2)|(Boolean.parseBoolean(System.getProperty("metallum.rt.transmissionGi","true"))?0:4)|(Boolean.parseBoolean(System.getProperty("metallum.rt.edgeRefine","true"))?0:8)|(Boolean.getBoolean("metallum.rt.metalfx")?16:0)|(bounces<<8));
            for(int i=0;i<4;i++)parameters.set(JAVA_FLOAT,128+i*4,transport[i]);
            parameters.set(JAVA_FLOAT,144,Float.parseFloat(System.getProperty("metallum.rt.exposureEv","0")));
            parameters.set(JAVA_FLOAT,148,Boolean.parseBoolean(System.getProperty("metallum.rt.toneMapping","true"))?1f:0f);
            if(!Boolean.parseBoolean(System.getProperty("metallum.rt.metalfxSurfaceGuides","true")))parameters.set(JAVA_INT,124,parameters.get(JAVA_INT,124)|32);
            int raySamples=Math.max(0,Math.min(4,Integer.getInteger("metallum.rt.samples",0)));
            parameters.set(JAVA_INT,124,parameters.get(JAVA_INT,124)|(raySamples<<12));
            if(Boolean.getBoolean("metallum.rt.physicalLighting"))parameters.set(JAVA_INT,124,parameters.get(JAVA_INT,124)|32768);
            if(!Boolean.parseBoolean(System.getProperty("metallum.rt.directSpecular","true")))parameters.set(JAVA_INT,124,parameters.get(JAVA_INT,124)|65536);
            if(horizontalCoverage)parameters.set(JAVA_INT,124,parameters.get(JAVA_INT,124)|2048);
            if(Boolean.getBoolean("metallum.rt.dynamicTemporal"))parameters.set(JAVA_INT,124,parameters.get(JAVA_INT,124)|128);
            if(Boolean.getBoolean("metallum.rt.metalfxFullSamples"))parameters.set(JAVA_INT,124,parameters.get(JAVA_INT,124)|64);
            check((int)encodeFrame.invokeExact(context,commandBuffer,color,depth,fence,parameters));
        }catch(Throwable e){throw new IllegalStateException("Live RT encoding failed",e);}
    }
    @Override public synchronized void close() {
        if (closed) return;
        closed = true;
        try {
            if (context.address() != 0 && destroy != null) destroy.invokeExact(context);
        } catch (Throwable e) { throw new IllegalStateException("Failed to release native RT scene", e); }
        finally {
            arena.close();
        }
    }
}
