// SPDX-License-Identifier: MIT
package com.metallum.rt;

import com.google.gson.GsonBuilder;
import com.metallum.Metallum;
import com.metallum.objc.Msg;
import com.metallum.mtl.MTLDevice;
import net.fabricmc.loader.api.FabricLoader;
import java.lang.foreign.MemorySegment;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import static java.lang.foreign.ValueLayout.JAVA_BOOLEAN;

public final class RtDiagnostics {
    private RtDiagnostics() {}
    private static boolean flag(MemorySegment device, String selector) throws Throwable {
        var msg = Msg.of(selector, JAVA_BOOLEAN);
        return (boolean) msg.handle().invokeExact(device, msg.sel());
    }
    public static void inspect(MemorySegment device) {
        var report = new LinkedHashMap<String, Object>();
        report.put("time", java.time.Instant.now().toString());
        report.put("device", new MTLDevice(device).name());
        report.put("effectsActive", false);
        report.put("intersectionProofPassed", false);
        String mode = System.getProperty("metallum.rt.mode", "off");
        report.put("requestedMode", mode);
        try {
            boolean supported = flag(device, "supportsRaytracing");
            report.put("apiSupported", supported);
            report.put("unifiedMemory", flag(device, "hasUnifiedMemory"));
            report.put("recommendedWorkingSetBytes", new MTLDevice(device).recommendedMaxWorkingSetSize());
            if (!supported) report.put("status", "unsupported-raster-fallback");
            else if (mode.equals("off")) report.put("status", "disabled-raster-fallback");
            else if (!mode.equals("proof") && !mode.equals("hybrid")) report.put("status", "unknown-mode-raster-fallback");
            else {
                try (var scene = new NativeRtScene(device)) {
                    scene.buildTriangles(new float[]{-1,-1,0, 1,-1,0, 1,1,0, -1,-1,0, 1,1,0, -1,1,0});
                    var hits = scene.trace(new float[]{.5f,-.5f,2,0, 0,0,-1,10, -.5f,.5f,2,0, 0,0,-1,10, 2,0,2,0, 0,0,-1,10, .5f,-.5f,2,0, 0,0,-1,1.9f});
                    if (!hits[0].hit() || hits[0].primitive()!=0 || Math.abs(hits[0].distance()-2)>2e-5 ||
                        !hits[1].hit() || hits[1].primitive()!=1 || Math.abs(hits[1].distance()-2)>2e-5 || hits[2].hit() || hits[3].hit())
                        throw new IllegalStateException("Java-to-Metal intersection proof mismatch");
                    report.put("sceneEpoch", scene.epoch());
                    report.put("intersectionProofPassed", true);
                    report.put("status", "proof-passed-effects-not-integrated");
                }
            }
        } catch (Throwable error) {
            report.put("status", "initialization-failed-raster-fallback");
            report.put("reason", error.toString());
            Metallum.LOGGER.warn("RT diagnostics failed; retaining raster renderer", error);
        }
        String json = new GsonBuilder().setPrettyPrinting().create().toJson(report);
        Metallum.LOGGER.info("RT status: {}", json);
        try { Files.writeString(FabricLoader.getInstance().getConfigDir().resolve("metallum-rt-status.json"), json + "\n"); }
        catch (java.io.IOException error) { Metallum.LOGGER.warn("Unable to write RT status", error); }
    }
}
