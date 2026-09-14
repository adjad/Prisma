// SPDX-License-Identifier: MIT
import com.metallum.rt.RtSettingsStore;
import com.metallum.rt.RtSettingsStore.Option;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Properties;

/** Exercises real persistence and failed writes without loading Minecraft or Metal. */
public final class RtSettingsProof {
    private static int checks;
    private static void check(boolean value, String message) {
        checks++;
        if (!value) throw new AssertionError(message);
    }
    @FunctionalInterface private interface Operation { void run() throws Exception; }
    private static void rejects(Operation operation, String message) throws Exception {
        boolean failed = false;
        try { operation.run(); } catch (IllegalArgumentException | java.io.IOException expected) { failed = true; }
        check(failed, message);
    }

    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("metalrt-settings-proof-");
        Path file = directory.resolve("config/metallum-raytracing.properties");
        Properties runtime = new Properties();
        runtime.setProperty("metallum.rt.mode", "hybrid");
        runtime.setProperty("unrelated.setting", "preserved");
        var warnings = new ArrayList<String>();
        var store = new RtSettingsStore(file, runtime, warnings::add);
        check(store.effective().get(Option.MODE).equals("hybrid"), "Missing file retains launcher enablement");
        check(store.effective().get(Option.SAMPLES).equals("3"), "Balanced default sample budget");
        check(!Files.exists(file), "Read-only initialization does not create a settings file");

        store.set(Option.SHADOWS, "0.25");
        String firstSave = Files.readString(file);
        store.set(Option.SAMPLES, "2");
        check(Files.readString(file.resolveSibling(file.getFileName() + ".bak")).equals(firstSave), "Backup is the actual previous file");
        Properties restarted = new Properties();
        restarted.setProperty("metallum.rt.mode", "off");
        var reopened = new RtSettingsStore(file, restarted, warnings::add);
        check(reopened.effective().get(Option.MODE).equals("hybrid"), "Saved choice overrides stale launcher flags");
        check(reopened.effective().get(Option.SAMPLES).equals("2"), "Ray budget survives restart");
        check(reopened.effective().get(Option.SHADOWS).equals("0.25"), "Effect strength survives restart");

        String validFile = Files.readString(file);
        Properties beforeInvalid = (Properties) restarted.clone();
        for (String bad : new String[]{"NaN", "Infinity", "-0.1", "1.1"})
            rejects(() -> reopened.set(Option.GI, bad), "Reject invalid strength " + bad);
        rejects(() -> reopened.set(Option.SAMPLES, "5"), "Reject excessive ray budget");
        rejects(() -> reopened.set(Option.SAMPLES, "2.5"), "Reject fractional ray budget");
        rejects(() -> reopened.set(Option.BOUNCES, "0"), "Reject zero bounce count");
        rejects(() -> reopened.set(Option.LOCAL_LIGHTS, "yes"), "Reject ambiguous boolean");
        rejects(() -> reopened.set(Option.MODE, "magic"), "Reject unknown renderer mode");
        check(Files.readString(file).equals(validFile) && restarted.equals(beforeInvalid), "Rejected updates change neither disk nor runtime");

        Files.writeString(file, "schemaVersion=1\nunknownOption=true\n");
        rejects(reopened::reload, "Reject unknown disk key");
        check(restarted.equals(beforeInvalid), "Invalid reload preserves runtime state");
        Files.writeString(file, "schemaVersion=2\nmode=off\n");
        rejects(reopened::reload, "Reject future schema without rewriting it");
        check(Files.readString(file).startsWith("schemaVersion=2"), "Future file preserved");
        Properties badStartup = new Properties();
        new RtSettingsStore(file, badStartup, warnings::add);
        check(!warnings.isEmpty() && Files.readString(file).startsWith("schemaVersion=2"), "Bad startup file reports a warning and is preserved");

        Files.writeString(file, validFile);
        reopened.reload();
        restarted.setProperty(Option.SAMPLES.property(), "4");
        reopened.save(reopened.effective());
        check(new RtSettingsStore(file, new Properties(), warnings::add).effective().get(Option.SAMPLES).equals("4"), "Explicit save captures valid session overrides");
        reopened.save(RtSettingsStore.preset("balanced"));
        check(reopened.effective().get(Option.SAMPLES).equals("3") && reopened.effective().get(Option.BOUNCES).equals("1"), "Balanced preset restores its complete ray budget");
        reopened.save(RtSettingsStore.preset("quality"));
        check(reopened.effective().get(Option.SAMPLES).equals("4") && reopened.effective().get(Option.BOUNCES).equals("2"), "Quality preset selects four samples and two bounces");
        reopened.set(Option.MODE, "off");
        check(new RtSettingsStore(file, new Properties(), warnings::add).effective().get(Option.MODE).equals("off"), "Disabled state survives restart");
        check(runtime.getProperty("unrelated.setting").equals("preserved"), "Unowned application properties are untouched");

        reopened.set(Option.PHYSICAL_LIGHTING, "true");
        check(new RtSettingsStore(file, new Properties(), warnings::add).effective().get(Option.PHYSICAL_LIGHTING).equals("true"), "Traced surface lighting survives restart");
        reopened.save(RtSettingsStore.preset("balanced"));
        check(reopened.effective().get(Option.PHYSICAL_LIGHTING).equals("false"), "Balanced retains the measured hybrid lighting mode");
        reopened.set(Option.DIRECT_SPECULAR, "false");
        check(new RtSettingsStore(file, new Properties(), warnings::add).effective().get(Option.DIRECT_SPECULAR).equals("false"), "Direct specular selection survives restart");
        reopened.set(Option.EXPOSURE_EV, "-1.5");
        reopened.set(Option.TONE_MAPPING, "false");
        var displayRestart = new RtSettingsStore(file, new Properties(), warnings::add);
        check(displayRestart.effective().get(Option.EXPOSURE_EV).equals("-1.5"), "Fractional negative exposure survives restart");
        check(displayRestart.effective().get(Option.TONE_MAPPING).equals("false"), "Display bypass survives restart");
        for (String bad : new String[]{"NaN", "Infinity", "-8.01", "8.01"})
            rejects(() -> reopened.set(Option.EXPOSURE_EV, bad), "Reject invalid exposure " + bad);
        check(Option.EXPOSURE_EV.normalize("-8").equals("-8.0") && Option.EXPOSURE_EV.normalize("8").equals("8.0"), "Exposure endpoints accepted");
        reopened.save(RtSettingsStore.preset("balanced"));
        check(reopened.effective().get(Option.TONE_MAPPING).equals("true") && reopened.effective().get(Option.EXPOSURE_EV).equals("0.0"), "Preset restores neutral display controls");
        Path parentFile = directory.resolve("not-a-directory");
        Files.writeString(parentFile, "keep");
        Properties failedRuntime = new Properties();
        var unwritable = new RtSettingsStore(parentFile.resolve("settings.properties"), failedRuntime, warnings::add);
        Properties beforeFailure = (Properties) failedRuntime.clone();
        rejects(() -> unwritable.set(Option.SAMPLES, "1"), "Write failure must be reported");
        check(failedRuntime.equals(beforeFailure) && Files.readString(parentFile).equals("keep"), "Failed persistence does not apply a live change");
        System.out.println("{\"passed\":true,\"checks\":" + checks + ",\"persistence\":true,\"backup\":true,\"invalidReloadPreservesState\":true,\"failedWritePreservesState\":true}");
    }
}
