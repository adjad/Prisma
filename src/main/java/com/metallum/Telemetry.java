package com.metallum;

import net.fabricmc.loader.api.FabricLoader;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

public final class Telemetry {
    private static final String ENDPOINT = "https://metallum-telemetry.kirill-zaripow.workers.dev/ping";
    private static final String PATH = "metallum-telemetry.txt";

    private Telemetry() {
    }

    public static void pingOncePerVersion() {
        try {
            String modVersion = FabricLoader.getInstance()
                    .getModContainer(Metallum.MOD_ID)
                    .map(c -> c.getMetadata().getVersion().getFriendlyString())
                    .orElse("unknown");

            Path marker = FabricLoader.getInstance().getConfigDir().resolve(PATH);
            String last = Files.exists(marker) ? Files.readString(marker).trim() : "";
            if (last.equals("off") || last.equals(modVersion)) return;

            Files.writeString(marker, modVersion);

            String query = "?os=" + URLEncoder.encode(System.getProperty("os.version", "unknown"), StandardCharsets.UTF_8)
                    + "&v=" + URLEncoder.encode(modVersion, StandardCharsets.UTF_8);
            URI uri = URI.create(ENDPOINT + query);

            HttpClient client = HttpClient.newHttpClient();
            client.sendAsync(
                            HttpRequest.newBuilder(uri).POST(HttpRequest.BodyPublishers.noBody()).build(),
                            HttpResponse.BodyHandlers.discarding())
                    .whenComplete((response, error) -> {
                        if (error != null) {
                            Metallum.LOGGER.info("Telemetry ping failed: {}", error.toString());
                        } else {
                            Metallum.LOGGER.info("Telemetry ping: HTTP {}", response.statusCode());
                        }
                        client.close();
                    });
        } catch (Exception ignored) {
        }
    }
}
