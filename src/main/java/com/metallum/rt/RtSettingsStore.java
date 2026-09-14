// SPDX-License-Identifier: MIT
package com.metallum.rt;

import java.io.IOException;
import java.io.StringReader;
import java.io.StringWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.EnumMap;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;
import java.util.function.Consumer;

/** Validated persistent controls; disk writes complete before live settings change. */
public final class RtSettingsStore {
    private enum Kind { BOOLEAN, INTEGER, STRENGTH, REAL, MODE }

    public enum Option {
        MODE("mode", Kind.MODE, "off", 0, 0),
        DIRECT_SPECULAR("directSpecular", Kind.BOOLEAN, "true", 0, 0),
        TONE_MAPPING("toneMapping", Kind.BOOLEAN, "true", 0, 0),
        EXPOSURE_EV("exposureEv", Kind.REAL, "0", -8, 8),
        PHYSICAL_LIGHTING("physicalLighting", Kind.BOOLEAN, "false", 0, 0),
        SAMPLES("samples", Kind.INTEGER, "3", 0, 4),
        BOUNCES("bounces", Kind.INTEGER, "1", 1, 4),
        AO("ao", Kind.STRENGTH, "0.65", 0, 1),
        SHADOWS("shadows", Kind.STRENGTH, "0.65", 0, 1),
        REFLECTIONS("reflections", Kind.STRENGTH, "1", 0, 1),
        GI("gi", Kind.STRENGTH, "1", 0, 1),
        LOCAL_LIGHTS("localLights", Kind.BOOLEAN, "true", 0, 0),
        ENTITIES("entities", Kind.BOOLEAN, "true", 0, 0),
        TEMPORAL("temporal", Kind.BOOLEAN, "true", 0, 0),
        DYNAMIC_TEMPORAL("dynamicTemporal", Kind.BOOLEAN, "true", 0, 0),
        TRANSMISSION_GI("transmissionGi", Kind.BOOLEAN, "true", 0, 0),
        EDGE_REFINE("edgeRefine", Kind.BOOLEAN, "true", 0, 0),
        METALFX("metalfx", Kind.BOOLEAN, "false", 0, 0),
        METALFX_GUIDES("metalfxSurfaceGuides", Kind.BOOLEAN, "true", 0, 0),
        METALFX_FULL_SAMPLES("metalfxFullSamples", Kind.BOOLEAN, "false", 0, 0),
        CHUNK_RADIUS("chunkRadius", Kind.INTEGER, "8", 1, 8);

        public final String key;
        private final Kind kind;
        private final String defaultValue;
        private final int minimum, maximum;

        Option(String key, Kind kind, String defaultValue, int minimum, int maximum) {
            this.key = key;
            this.kind = kind;
            this.defaultValue = defaultValue;
            this.minimum = minimum;
            this.maximum = maximum;
        }

        public String property() { return "metallum.rt." + key; }

        public String normalize(String input) {
            String value = input.trim();
            try {
                return switch (kind) {
                    case BOOLEAN -> {
                        if (!value.equalsIgnoreCase("true") && !value.equalsIgnoreCase("false"))
                            throw new IllegalArgumentException();
                        yield value.toLowerCase(Locale.ROOT);
                    }
                    case MODE -> {
                        if (!value.equals("off") && !value.equals("hybrid"))
                            throw new IllegalArgumentException();
                        yield value;
                    }
                    case INTEGER -> {
                        int number = Integer.parseInt(value);
                        if (number < minimum || number > maximum) throw new IllegalArgumentException();
                        yield Integer.toString(number);
                    }
                    case STRENGTH, REAL -> {
                        float number = Float.parseFloat(value);
                        if (!Float.isFinite(number) || number < minimum || number > maximum)
                            throw new IllegalArgumentException();
                        yield Float.toString(number);
                    }
                };
            } catch (IllegalArgumentException error) {
                throw new IllegalArgumentException("Invalid " + key + ": expected " + valueHint());
            }
        }

        public String valueHint() {
            return switch (kind) {
                case BOOLEAN -> "true or false";
                case MODE -> "off or hybrid";
                case INTEGER -> minimum + "–" + maximum;
                case STRENGTH -> "0–1";
                case REAL -> minimum + "–" + maximum + " EV";
            };
        }

        public java.util.List<String> suggestedValues() {
            return switch (kind) {
                case BOOLEAN -> java.util.List.of("true", "false");
                case MODE -> java.util.List.of("off", "hybrid");
                case INTEGER -> java.util.stream.IntStream.rangeClosed(minimum, maximum).mapToObj(Integer::toString).toList();
                case REAL -> java.util.List.of("-4", "-2", "-1", "0", "1", "2", "4");
                case STRENGTH -> java.util.List.of("0", "0.25", "0.5", "0.75", "1");
            };
        }

        public static Option find(String key) {
            for (Option option : values()) if (option.key.equals(key)) return option;
            throw new IllegalArgumentException("Unknown setting: " + key);
        }
    }

    public record Snapshot(Map<Option, String> values) {
        public Snapshot {
            var checked = new EnumMap<Option, String>(Option.class);
            for (Option option : Option.values()) {
                String value = values.get(option);
                if (value == null) throw new IllegalArgumentException("Missing " + option.key);
                checked.put(option, option.normalize(value));
            }
            values = Map.copyOf(checked);
        }
        public String get(Option option) { return values.get(option); }
        public Snapshot with(Option option, String value) {
            var changed = new EnumMap<Option, String>(Option.class);
            changed.putAll(values);
            changed.put(option, option.normalize(value));
            return new Snapshot(changed);
        }
    }

    private final Path file;
    private final Properties runtime;
    private Snapshot saved;

    public RtSettingsStore(Path file, Properties runtime, Consumer<String> warning) {
        this.file = file.toAbsolutePath().normalize();
        this.runtime = runtime;
        saved = defaults();
        // A saved user choice wins over older launcher flags. Without a saved file,
        // retain existing development flags and use defaults for unspecified keys.
        var initial = new EnumMap<Option, String>(Option.class);
        for (Option option : Option.values()) {
            try { initial.put(option, option.normalize(runtime.getProperty(option.property(), saved.get(option)))); }
            catch (IllegalArgumentException invalid) {
                warning.accept(invalid.getMessage() + "; using default");
                initial.put(option, saved.get(option));
            }
        }
        saved = new Snapshot(initial);
        if (Files.exists(file)) {
            try { saved = read(); }
            catch (IOException | IllegalArgumentException invalid) {
                warning.accept("Cannot load " + file.getFileName() + ": " + invalid.getMessage() + "; file preserved");
            }
        }
        publish(saved);
    }

    public Path file() { return file; }

    public static Snapshot defaults() {
        var values = new EnumMap<Option, String>(Option.class);
        for (Option option : Option.values()) values.put(option, option.defaultValue);
        return new Snapshot(values);
    }

    public static Snapshot preset(String name) {
        Snapshot result = defaults().with(Option.MODE, "hybrid");
        return switch (name) {
            case "performance" -> result.with(Option.SAMPLES, "2");
            case "balanced" -> result;
            case "quality" -> result.with(Option.SAMPLES, "4").with(Option.BOUNCES, "2");
            default -> throw new IllegalArgumentException("Unknown preset: " + name);
        };
    }

    /** Includes valid session changes made by the development diagnostics. */
    public synchronized Snapshot effective() {
        var values = new EnumMap<Option, String>(Option.class);
        for (Option option : Option.values()) {
            try { values.put(option, option.normalize(runtime.getProperty(option.property(), saved.get(option)))); }
            catch (IllegalArgumentException invalid) { values.put(option, saved.get(option)); }
        }
        return new Snapshot(values);
    }

    public synchronized void set(Option option, String value) throws IOException {
        save(effective().with(option, value));
    }

    public synchronized void save(Snapshot next) throws IOException {
        Properties properties = new Properties();
        properties.setProperty("schemaVersion", "1");
        for (Option option : Option.values()) properties.setProperty(option.key, next.get(option));
        var text = new StringWriter();
        properties.store(text, "Metal RT local settings. /metalrt help lists controls.");
        Files.createDirectories(file.getParent());
        Path temporary = Files.createTempFile(file.getParent(), "metalrt-", ".tmp");
        try {
            Files.writeString(temporary, text.toString(), StandardCharsets.UTF_8);
            if (Files.exists(file)) Files.copy(file, file.resolveSibling(file.getFileName() + ".bak"), StandardCopyOption.REPLACE_EXISTING);
            try { Files.move(temporary, file, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING); }
            catch (AtomicMoveNotSupportedException unsupported) {
                Files.move(temporary, file, StandardCopyOption.REPLACE_EXISTING);
            }
        } finally { Files.deleteIfExists(temporary); }
        saved = next;
        publish(next);
    }

    public synchronized void reload() throws IOException {
        Snapshot next = read();
        saved = next;
        publish(next);
    }

    private Snapshot read() throws IOException {
        if (Files.size(file) > 65536) throw new IOException("Settings file exceeds 64 KiB");
        Properties properties = new Properties();
        properties.load(new StringReader(Files.readString(file, StandardCharsets.UTF_8)));
        if (!"1".equals(properties.getProperty("schemaVersion")))
            throw new IllegalArgumentException("Unsupported settings schema");
        var values = new EnumMap<Option, String>(Option.class);
        values.putAll(defaults().values());
        for (String key : properties.stringPropertyNames()) {
            if (key.equals("schemaVersion")) continue;
            Option option = Option.find(key);
            values.put(option, option.normalize(properties.getProperty(key)));
        }
        return new Snapshot(values);
    }

    private void publish(Snapshot snapshot) {
        for (Option option : Option.values()) runtime.setProperty(option.property(), snapshot.get(option));
    }
}
