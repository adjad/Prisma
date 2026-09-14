// SPDX-License-Identifier: MIT
import com.metallum.rt.RtClientControls;
import com.metallum.rt.RtSettingsStore;
import com.metallum.rt.RtSettingsStore.Option;
import com.mojang.brigadier.CommandDispatcher;
import net.fabricmc.fabric.api.client.command.v2.FabricClientCommandSource;
import java.lang.reflect.Proxy;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Properties;

/** Tests actual registered Brigadier commands using an isolated settings store. */
public final class RtClientControlsProof {
    private static int checks;
    private static void check(boolean value, String message) {
        checks++;
        if (!value) throw new AssertionError(message);
    }
    public static void main(String[] args) throws Exception {
        var file = Files.createTempDirectory("metalrt-command-proof-").resolve("settings.properties");
        var properties = new Properties();
        var store = new RtSettingsStore(file, properties, ignored -> {});
        var field = RtClientControls.class.getDeclaredField("settings");
        field.setAccessible(true);
        field.set(null, store);
        var messages = new ArrayList<String>();
        boolean[] attended = {true};
        var source = (FabricClientCommandSource) Proxy.newProxyInstance(FabricClientCommandSource.class.getClassLoader(),
                new Class<?>[]{FabricClientCommandSource.class}, (proxy, method, arguments) -> switch (method.getName()) {
                    case "attended" -> attended[0];
                    case "sendFeedback", "sendError" -> { messages.add(arguments[0].toString()); yield null; }
                    case "toString" -> "Isolated Metal RT command test";
                    case "hashCode" -> System.identityHashCode(proxy);
                    case "equals" -> proxy == arguments[0];
                    default -> throw new AssertionError("Unexpected client or network operation: " + method.getName());
                });
        var dispatcher = new CommandDispatcher<FabricClientCommandSource>();
        RtClientControls.register(dispatcher);
        check(dispatcher.execute("metalrt preset balanced", source) == 1, "Balanced preset command succeeds");
        check(store.effective().get(Option.MODE).equals("hybrid") && Files.exists(file), "Preset is active and persisted");
        check(dispatcher.execute("metalrt set reflections 0.4", source) == 1, "Effect control command succeeds");
        check(store.effective().get(Option.REFLECTIONS).equals("0.4"), "Effect strength applies");
        check(dispatcher.execute("metalrt set exposureEv -1.5", source) == 1 && store.effective().get(Option.EXPOSURE_EV).equals("-1.5"), "Signed fractional exposure command");
        check(dispatcher.execute("metalrt set toneMapping false", source) == 1 && store.effective().get(Option.TONE_MAPPING).equals("false"), "Tone mapping bypass command");
        String before = Files.readString(file);
        check(dispatcher.execute("metalrt set samples 7", source) == 0, "Invalid value is reported");
        check(Files.readString(file).equals(before), "Invalid command leaves disk unchanged");
        attended[0] = false;
        boolean rejected = false;
        try { dispatcher.execute("metalrt set mode off", source); }
        catch (com.mojang.brigadier.exceptions.CommandSyntaxException expected) { rejected = true; }
        check(rejected && store.effective().get(Option.MODE).equals("hybrid"), "Unattended mutation is rejected");
        attended[0] = true;
        properties.setProperty(Option.SAMPLES.property(), "2");
        check(dispatcher.execute("metalrt save", source) == 1, "Save captures session settings");
        properties.setProperty(Option.SAMPLES.property(), "4");
        check(dispatcher.execute("metalrt reload", source) == 1 && store.effective().get(Option.SAMPLES).equals("2"), "Reload restores saved values");
        check(dispatcher.execute("metalrt help", source) == 1 && messages.size() >= Option.values().length, "Help lists supported settings");
        check(dispatcher.getRoot().getChild("metalrt").getChild("status") != null, "Status command registered");
        var suggestions = dispatcher.getCompletionSuggestions(dispatcher.parse("metalrt set mode ", source)).join().getList();
        check(suggestions.stream().anyMatch(value -> value.getText().equals("hybrid"))
                && suggestions.stream().anyMatch(value -> value.getText().equals("off")), "Mode values have tab completion");
        System.out.println("{\"passed\":true,\"checks\":" + checks + ",\"realBrigadierRegistration\":true,\"clientOnly\":true,\"unattendedMutationsRejected\":true}");
    }
}
