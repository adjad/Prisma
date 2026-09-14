// SPDX-License-Identifier: MIT
package com.metallum.rt;

import com.metallum.Metallum;
import com.metallum.render.MetalRtIntegration;
import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.arguments.StringArgumentType;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.command.v2.ClientCommandRegistrationCallback;
import net.fabricmc.fabric.api.client.command.v2.FabricClientCommandSource;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.network.chat.Component;

import java.io.IOException;

import static net.fabricmc.fabric.api.client.command.v2.ClientCommands.argument;
import static net.fabricmc.fabric.api.client.command.v2.ClientCommands.literal;

/** Local commands only: renderer settings never become server commands or chat. */
public final class RtClientControls implements ClientModInitializer {
    private static RtSettingsStore settings;

    @Override public void onInitializeClient() {
        settings = new RtSettingsStore(FabricLoader.getInstance().getConfigDir().resolve("metallum-raytracing.properties"),
                System.getProperties(), Metallum.LOGGER::warn);
        ClientCommandRegistrationCallback.EVENT.register((dispatcher, registry) -> register(dispatcher));
    }

    public static void register(CommandDispatcher<FabricClientCommandSource> dispatcher) {
        var root = literal("metalrt").executes(context -> status(context.getSource()));
        root.then(literal("status").executes(context -> status(context.getSource())));
        root.then(literal("help").executes(context -> {
            feedback(context.getSource(), "/metalrt preset performance|balanced|quality; /metalrt set <setting> <value>; /metalrt save; /metalrt reload");
            for (var option : RtSettingsStore.Option.values())
                feedback(context.getSource(), option.key + " = " + settings.effective().get(option) + " (" + option.valueHint() + ")");
            feedback(context.getSource(), "samples=0 selects the automatic budget. MetalFX is experimental. Quality uses more rays and two bounces; 60 FPS is not guaranteed.");
            feedback(context.getSource(), "physicalLighting replaces baked surface lighting; experimental, with atmosphere and material-detail work remaining. AO is redundant for its traced diffuse paths.");
            feedback(context.getSource(), "toneMapping applies exposureEv and highlight rolloff to traced surface lighting after denoising. false bypasses both; hybrid lighting is unchanged.");
            feedback(context.getSource(), "Settings: " + settings.file() + " (previous file: .bak)");
            return 1;
        }));
        var preset = literal("preset").requires(FabricClientCommandSource::attended);
        for (String name : new String[]{"performance", "balanced", "quality"}) {
            preset.then(literal(name).executes(context -> change(context.getSource(), () -> settings.save(RtSettingsStore.preset(name)), "Saved " + name + " preset")));
        }
        root.then(preset);
        var set = literal("set").requires(FabricClientCommandSource::attended);
        for (var option : RtSettingsStore.Option.values()) {
            set.then(literal(option.key).then(argument("value", StringArgumentType.word())
                    .suggests((context, builder) -> {
                        for (String value : option.suggestedValues()) if (value.startsWith(builder.getRemaining())) builder.suggest(value);
                        return builder.buildFuture();
                    })
                    .executes(context -> change(context.getSource(),
                            () -> settings.set(option, StringArgumentType.getString(context, "value")),
                            "Saved " + option.key + "=" + StringArgumentType.getString(context, "value")))));
        }
        root.then(set);
        root.then(literal("save").requires(FabricClientCommandSource::attended)
                .executes(context -> change(context.getSource(), () -> settings.save(settings.effective()), "Saved current session settings")));
        root.then(literal("reload").requires(FabricClientCommandSource::attended)
                .executes(context -> change(context.getSource(), settings::reload, "Reloaded saved settings")));
        dispatcher.register(root);
    }

    @FunctionalInterface private interface Edit { void run() throws IOException; }

    private static int change(FabricClientCommandSource source, Edit edit, String message) {
        String previousRadius = settings.effective().get(RtSettingsStore.Option.CHUNK_RADIUS);
        try {
            edit.run();
            if (!previousRadius.equals(settings.effective().get(RtSettingsStore.Option.CHUNK_RADIUS))) MetalRtIntegration.invalidate();
            feedback(source, message + ". Applied locally.");
            return 1;
        } catch (IOException | IllegalArgumentException error) {
            source.sendError(Component.literal("Metal RT settings unchanged: " + error.getMessage()));
            return 0;
        }
    }

    private static int status(FabricClientCommandSource source) {
        var values = settings.effective();
        String samples = values.get(RtSettingsStore.Option.SAMPLES);
        feedback(source, "Metal RT " + values.get(RtSettingsStore.Option.MODE) + ": "
                + (samples.equals("0") ? "automatic sample budget" : samples + " samples") + ", " + values.get(RtSettingsStore.Option.BOUNCES) + " diffuse bounces.");
        feedback(source, "AO " + values.get(RtSettingsStore.Option.AO) + ", shadows " + values.get(RtSettingsStore.Option.SHADOWS)
                + ", reflections " + values.get(RtSettingsStore.Option.REFLECTIONS) + ", GI " + values.get(RtSettingsStore.Option.GI)
                + ", local lights " + values.get(RtSettingsStore.Option.LOCAL_LIGHTS) + ".");
        feedback(source, "Surface lighting: " + (values.get(RtSettingsStore.Option.PHYSICAL_LIGHTING).equals("true") ? "traced direct and indirect" : "hybrid over Minecraft lighting") + ".");
        feedback(source, "Direct specular sampling: " + values.get(RtSettingsStore.Option.DIRECT_SPECULAR) + " (traced surface lighting, opaque primary materials).");
        feedback(source, "Display: tone mapping " + values.get(RtSettingsStore.Option.TONE_MAPPING) + ", exposure " + values.get(RtSettingsStore.Option.EXPOSURE_EV) + " EV (traced surface lighting only).");
        var state = MetalRtIntegration.controlStatus();
        feedback(source, state + ".");
        var window = source.getClient().getWindow();
        feedback(source, "Framebuffer " + window.getWidth() + "×" + window.getHeight() + "; " + source.getClient().getFps() + " FPS.");
        return 1;
    }

    private static void feedback(FabricClientCommandSource source, String message) {
        source.sendFeedback(Component.literal(message));
    }
}
