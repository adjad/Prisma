export default {
    async fetch(request, env) {
        const url = new URL(request.url);

        if (request.method === "POST" && url.pathname === "/ping") {
            const os = url.searchParams.get("os") ?? "";
            const v = url.searchParams.get("v") ?? "";
            await env.DB.prepare(`
                INSERT INTO pings (os_version, mod_version, count) VALUES (?1, ?2, 1)
                ON CONFLICT(os_version, mod_version) DO UPDATE SET count = count + 1
            `).bind(os, v).run();
            return new Response("ok");
        }

        if (request.method === "GET" && url.pathname === "/stats") {
            const { results } = await env.DB.prepare(
                "SELECT os_version, mod_version, count FROM pings ORDER BY count DESC"
            ).all();
            return Response.json(results);
        }

        return new Response("not found", { status: 404 });
    }
};
