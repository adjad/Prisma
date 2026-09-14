// SPDX-License-Identifier: MIT
package com.metallum.rt;

import java.util.List;
import java.util.Objects;

/** Physical, scene-relative area lights; independent of Minecraft's baked light levels. */
public final class SceneLights {
    private SceneLights() {}
    public record Vector(float x,float y,float z) {
        public Vector {
            if (!Float.isFinite(x)||!Float.isFinite(y)||!Float.isFinite(z))
                throw new IllegalArgumentException("Non-finite light vector");
        }
        private void put(float[] data,int offset) {data[offset]=x;data[offset+1]=y;data[offset+2]=z;}
    }
    /** Half edges define physical size and emitting normal through cross(halfU, halfV). */
    public record AreaLight(Vector center,Vector halfU,Vector halfV,Vector radiance,boolean twoSided) {
        public AreaLight {
            Objects.requireNonNull(center);Objects.requireNonNull(halfU);Objects.requireNonNull(halfV);Objects.requireNonNull(radiance);
        }
    }
    public record Receiver(Vector position,Vector normal) {
        public Receiver {Objects.requireNonNull(position);Objects.requireNonNull(normal);}
    }
    public record Emitters(List<AreaLight> lights,int unsupported) {
        public Emitters {lights=List.copyOf(lights);}
    }
    /** Baked quads arrive as (a,b,c),(a,c,d). Cache this per immutable section payload. */
    static Emitters fromQuads(float[] xyz,byte[] materialBytes,int[] texels) {
        var result=new java.util.ArrayList<AreaLight>();int unsupported=0;
        var materials=java.nio.ByteBuffer.wrap(materialBytes).order(java.nio.ByteOrder.nativeOrder());
        var colors=new java.util.HashMap<Integer,Vector>();
        for(int triangle=0;triangle+1<xyz.length/9;triangle+=2) {
            int m=triangle*96;float emission=materials.getFloat(m+24);
            if(emission<=0)continue;
            int at=triangle*9;float[] a={xyz[at],xyz[at+1],xyz[at+2]},b={xyz[at+3],xyz[at+4],xyz[at+5]},c={xyz[at+6],xyz[at+7],xyz[at+8]},d={xyz[at+15],xyz[at+16],xyz[at+17]};
            float[] u=new float[3],v=new float[3];boolean rectangle=true;float dot=0,uu=0,vv=0;
            for(int j=0;j<3;j++) {
                u[j]=(b[j]-a[j])*.5f;v[j]=(d[j]-a[j])*.5f;dot+=u[j]*v[j];uu+=u[j]*u[j];vv+=v[j]*v[j];
                rectangle&=Math.abs(c[j]-(b[j]+d[j]-a[j]))<.0001f&&Math.abs(xyz[at+9+j]-a[j])<.0001f&&Math.abs(xyz[at+12+j]-c[j])<.0001f;
            }
            if(!rectangle||uu<1e-8f||vv<1e-8f||Math.abs(dot)>Math.sqrt(uu*vv)*.0001f){unsupported++;continue;}
            int image=materials.getInt(m+80),width=materials.getInt(m+84),height=materials.getInt(m+88);
            if(width<=0||height<=0||image<0||(long)image+(long)width*height>texels.length){unsupported++;continue;}
            Vector average=colors.get(image);
            if(average==null) {
                double r=0,g=0,blue=0;
                for(int i=0;i<width*height;i++){int argb=texels[image+i];float alpha=((argb>>>24)&255)/255f;r+=linear((argb>>>16)&255)*alpha;g+=linear((argb>>>8)&255)*alpha;blue+=linear(argb&255)*alpha;}
                average=new Vector((float)(r/(width*height)),(float)(g/(width*height)),(float)(blue/(width*height)));colors.put(image,average);
            }
            float r=average.x*materials.getFloat(m)*emission,g=average.y*materials.getFloat(m+4)*emission,blue=average.z*materials.getFloat(m+8)*emission;
            if(Math.max(r,Math.max(g,blue))<=0)continue;
            result.add(new AreaLight(new Vector((a[0]+c[0])*.5f,(a[1]+c[1])*.5f,(a[2]+c[2])*.5f),new Vector(u[0],u[1],u[2]),new Vector(v[0],v[1],v[2]),new Vector(r,g,blue),false));
        }
        return new Emitters(result,unsupported);
    }
    private static double linear(int channel){double value=channel/255.;return value<=.04045?value/12.92:Math.pow((value+.055)/1.055,2.4);}
    public record Selection(List<AreaLight> lights,int available,int unsupported) {
        public Selection {lights=List.copyOf(lights);}
    }
    public static Selection select(java.util.List<NativeRtScene.Chunk> chunks,float cameraX,float cameraY,float cameraZ) {
        var lights=new java.util.ArrayList<AreaLight>();int unsupported=0;
        for(var chunk:chunks) {
            var payload=chunk.emitters();unsupported+=payload.unsupported;
            for(var light:payload.lights)lights.add(new AreaLight(new Vector(light.center.x+chunk.x(),light.center.y+chunk.y(),light.center.z+chunk.z()),light.halfU,light.halfV,light.radiance,light.twoSided));
        }
        int available=lights.size();
        lights.sort(java.util.Comparator.comparingDouble(light->{var p=light.center;double x=p.x-cameraX,y=p.y-cameraY,z=p.z-cameraZ;return x*x+y*y+z*z;}));
        if(lights.size()>8192)lights.subList(8192,lights.size()).clear();
        return new Selection(lights,available,unsupported);
    }
    static float[] packLights(List<AreaLight> source) {
        var lights=List.copyOf(source);
        if(lights.size()>8192)throw new IllegalArgumentException("At most 8192 area lights");
        var data=new float[lights.size()*16];
        for(int i=0;i<lights.size();i++) {
            var light=lights.get(i);int offset=i*16;
            light.center.put(data,offset);light.halfU.put(data,offset+4);light.halfV.put(data,offset+8);
            data[offset+11]=light.twoSided?1:0;light.radiance.put(data,offset+12);
        }
        return data;
    }
    static float[] packReceivers(List<Receiver> source) {
        var receivers=List.copyOf(source);
        if(receivers.isEmpty()||receivers.size()>1_000_000)throw new IllegalArgumentException("Expected 1–1000000 receivers");
        var data=new float[receivers.size()*8];
        for(int i=0;i<receivers.size();i++) {receivers.get(i).position.put(data,i*8);receivers.get(i).normal.put(data,i*8+4);}
        return data;
    }
}
