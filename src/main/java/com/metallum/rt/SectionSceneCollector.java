// SPDX-License-Identifier: MIT
package com.metallum.rt;

import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.block.BlockStateModelSet;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import java.util.*;

/** Main-thread, bounded section collection. Published payloads contain no mutable world objects. */
public final class SectionSceneCollector {
    private static final class Entry {
        long revision;
        NativeRtScene.Chunk mesh;
        boolean deferred;
    }
    public record Snapshot(long revision,BlockPos origin,int width,List<NativeRtScene.Chunk> chunks,int triangles) {}
    public record Statistics(int radius,int knownSections,int residentSections,int queuedSections,int deferredSections,
                             int loadedColumns,long completedSections,long unchangedSections,long skippedAirSections,long evictions,
                             long triangles,long payloadBytes,long revision,double lastCollectionMs,double maxCollectionMs,
                             String collecting,String origin) {}
    private final ClientLevel level;
    private final int radius,maxTriangles;
    private final long maxBytes,budgetNanos;
    private final Map<Long,Entry> entries=new HashMap<>();
    private final Map<Long,LevelChunk> columns=new HashMap<>();
    private final Set<Long> queued=new HashSet<>();
    private final PriorityQueue<Long> queue=new PriorityQueue<>(this::compare);
    private List<Long> scanColumns=List.of();
    private int scanIndex,cx=Integer.MIN_VALUE,cy,cz;
    private BlockSceneSnapshot.Cursor cursor;
    private long cursorKey,cursorRevision,revision=1,completed,unchanged,air,evictions,triangles,bytes;
    private double lastMs,maxMs;

    public SectionSceneCollector(ClientLevel level){
        this.level=level;
        radius=Math.max(1,Math.min(8,Integer.getInteger("metallum.rt.chunkRadius",8)));
        maxTriangles=Math.max(100_000,Math.min(6_000_000,Integer.getInteger("metallum.rt.sceneTriangles",4_000_000)));
        maxBytes=Math.max(64,Math.min(1024,Integer.getInteger("metallum.rt.sceneMiB",768)))*1024L*1024;
        budgetNanos=Math.max(250_000,Math.min(8_000_000,Integer.getInteger("metallum.rt.collectMicros",2000)*1000L));
    }
    private long distance(long key){long x=BlockPos.getX(key)-cx,y=BlockPos.getY(key)-cy,z=BlockPos.getZ(key)-cz;return x*x+y*y+z*z;}
    private int compare(long a,long b){int c=Long.compare(distance(a),distance(b));return c!=0?c:Long.compare(a,b);}
    private boolean wanted(long key){return Math.abs((long)BlockPos.getX(key)-cx)<=radius&&Math.abs((long)BlockPos.getZ(key)-cz)<=radius;}
    public BlockPos origin(){return new BlockPos((cx-radius)*16,level.getMinY(),(cz-radius)*16);}
    public int width(){return (2*radius+1)*16;}
    public long revision(){return revision;}
    private void enqueue(long key){if(queued.add(key))queue.add(key);}
    private void remove(long key){
        Entry old=entries.remove(key);queued.remove(key);
        if(old!=null&&old.mesh!=null){triangles-=old.mesh.triangles();bytes-=old.mesh.byteSize();revision++;evictions++;}
        if(cursor!=null&&cursorKey==key)cursor=null;
    }
    private void dirty(long key){
        if(!wanted(key)||BlockPos.getY(key)<level.getMinSectionY()||BlockPos.getY(key)>level.getMaxSectionY())return;
        Entry e=entries.computeIfAbsent(key,k->new Entry());e.revision++;e.deferred=false;enqueue(key);
        if(cursor!=null&&cursorKey==key)cursor=null;
    }
    /** Include adjacent sections because face culling and fluid geometry read neighboring blocks. */
    public void changed(BlockPos minimum,int size){
        int x0=(minimum.getX()-1)>>4,x1=(minimum.getX()+size)>>4;
        int y0=(minimum.getY()-1)>>4,y1=(minimum.getY()+size)>>4;
        int z0=(minimum.getZ()-1)>>4,z1=(minimum.getZ()+size)>>4;
        for(int x=Math.max(x0,cx-radius);x<=Math.min(x1,cx+radius);x++)
            for(int z=Math.max(z0,cz-radius);z<=Math.min(z1,cz+radius);z++)
                for(int y=Math.max(y0,level.getMinSectionY());y<=Math.min(y1,level.getMaxSectionY());y++)dirty(BlockPos.asLong(x,y,z));
    }
    private void focus(BlockPos camera){
        int nx=camera.getX()>>4,ny=camera.getY()>>4,nz=camera.getZ()>>4;
        if(nx==cx&&ny==cy&&nz==cz)return;
        boolean moved=nx!=cx||nz!=cz;cx=nx;cy=ny;cz=nz;
        if(moved){
            for(long key:new ArrayList<>(entries.keySet()))if(!wanted(key))remove(key);
            columns.keySet().removeIf(k->!wanted(k));
            var list=new ArrayList<Long>();
            for(int x=cx-radius;x<=cx+radius;x++)for(int z=cz-radius;z<=cz+radius;z++)list.add(BlockPos.asLong(x,cy,z));
            list.sort(this::compare);scanColumns=List.copyOf(list);scanIndex=0;revision++;
        }
        queue.clear();queue.addAll(queued);
        for(var e:entries.entrySet())if(e.getValue().deferred){e.getValue().deferred=false;enqueue(e.getKey());}
    }
    private void invalidateNeighbors(int x,int z){
        for(long key:new ArrayList<>(entries.keySet()))if(Math.abs(BlockPos.getX(key)-x)<=1&&Math.abs(BlockPos.getZ(key)-z)<=1)dirty(key);
    }
    private void scanColumn(long column){
        int x=BlockPos.getX(column),z=BlockPos.getZ(column);long id=BlockPos.asLong(x,0,z);
        LevelChunk chunk=level.getChunkSource().getChunk(x,z,ChunkStatus.FULL,false);
        LevelChunk previous=columns.get(id);
        if(chunk!=previous){
            if(chunk==null)columns.remove(id);else columns.put(id,chunk);
            invalidateNeighbors(x,z);
        }
        if(chunk==null){
            for(int y=level.getMinSectionY();y<=level.getMaxSectionY();y++)remove(BlockPos.asLong(x,y,z));
            return;
        }
        for(int y=level.getMinSectionY();y<=level.getMaxSectionY();y++){
            long key=BlockPos.asLong(x,y,z);var section=chunk.getSection(level.getSectionIndexFromSectionY(y));
            if(section.hasOnlyAir()){if(entries.containsKey(key)){remove(key);air++;}continue;}
            if(!entries.containsKey(key)){entries.put(key,new Entry());enqueue(key);}
            else if(chunk!=previous)dirty(key);
        }
    }
    private void store(long key,NativeRtScene.Chunk mesh){
        Entry entry=entries.get(key);if(entry==null)return;
        if((mesh==null&&entry.mesh==null)||(mesh!=null&&entry.mesh!=null&&entry.mesh.samePayload(mesh))){completed++;unchanged++;return;}
        long oldTriangles=entry.mesh==null?0:entry.mesh.triangles(),oldBytes=entry.mesh==null?0:entry.mesh.byteSize();
        if(mesh!=null){
            // Keep nearby coverage when a pathological scene exceeds the declared payload budget.
            var far=entries.entrySet().stream().filter(e->e.getValue().mesh!=null&&compare(e.getKey(),key)>0)
                    .sorted((a,b)->compare(b.getKey(),a.getKey())).iterator();
            while((triangles-oldTriangles+mesh.triangles()>maxTriangles||bytes-oldBytes+mesh.byteSize()>maxBytes)&&far.hasNext()){
                var e=far.next();Entry v=e.getValue();triangles-=v.mesh.triangles();bytes-=v.mesh.byteSize();v.mesh=null;v.deferred=true;revision++;evictions++;
            }
            if(triangles-oldTriangles+mesh.triangles()>maxTriangles||bytes-oldBytes+mesh.byteSize()>maxBytes){
                entry.deferred=true;mesh=null;
            }
        }
        triangles-=oldTriangles;bytes-=oldBytes;entry.mesh=mesh;
        if(mesh!=null){triangles+=mesh.triangles();bytes+=mesh.byteSize();}
        revision++;completed++;
    }
    public void step(BlockPos camera,BlockStateModelSet models){
        long start=System.nanoTime(),deadline=start+budgetNanos;
        focus(camera);
        // Periodically observe loaded chunk identity without forcing loads or consuming Sodium's tracking sets.
        for(int n=0;n<8&&!scanColumns.isEmpty();n++){
            scanColumn(scanColumns.get(scanIndex));scanIndex=(scanIndex+1)%scanColumns.size();
            if(System.nanoTime()-start>=budgetNanos/4)break;
        }
        while(System.nanoTime()<deadline){
            if(cursor==null){
                Long key;
                do{key=queue.poll();}while(key!=null&&!queued.remove(key));
                if(key==null)break;
                Entry entry=entries.get(key);if(entry==null||!wanted(key)||entry.deferred)continue;
                int x=BlockPos.getX(key),y=BlockPos.getY(key),z=BlockPos.getZ(key);
                var chunk=level.getChunkSource().getChunk(x,z,ChunkStatus.FULL,false);
                if(chunk==null||chunk.getSection(level.getSectionIndexFromSectionY(y)).hasOnlyAir()){remove(key);air++;continue;}
                cursorKey=key;cursorRevision=entry.revision;cursor=new BlockSceneSnapshot.Cursor(new BlockPos(x*16,y*16,z*16),16,false);
            }
            if(!cursor.step(level,models,4096,deadline))break;
            var mesh=cursor.finish();long key=cursorKey;cursor=null;
            Entry entry=entries.get(key);
            if(entry!=null&&entry.revision==cursorRevision){
                store(key,mesh.triangles()==0?null:new NativeRtScene.Chunk(key,0,0,0,mesh.vertices(),mesh.materials()));
            }
        }
        lastMs=(System.nanoTime()-start)/1e6;maxMs=Math.max(maxMs,lastMs);
    }
    public Snapshot snapshot(){
        BlockPos origin=origin();var result=new ArrayList<NativeRtScene.Chunk>();
        entries.entrySet().stream().filter(e->e.getValue().mesh!=null).sorted(Map.Entry.comparingByKey()).forEach(e->{
            long key=e.getKey();result.add(e.getValue().mesh.translated(BlockPos.getX(key)*16-origin.getX(),BlockPos.getY(key)*16-origin.getY(),BlockPos.getZ(key)*16-origin.getZ()));
        });
        return new Snapshot(revision,origin,width(),List.copyOf(result),(int)triangles);
    }
    public Statistics statistics(){
        int resident=0,deferred=0;for(Entry e:entries.values()){if(e.mesh!=null)resident++;if(e.deferred)deferred++;}
        return new Statistics(radius,entries.size(),resident,queued.size(),deferred,columns.size(),completed,unchanged,air,evictions,triangles,bytes,revision,lastMs,maxMs,cursor==null?"none":cursor.origin().toString(),origin().toString());
    }
}
