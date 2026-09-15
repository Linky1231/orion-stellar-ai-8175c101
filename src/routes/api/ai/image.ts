import { createFileRoute } from "@tanstack/react-router";

const POLLINATIONS = "https://image.pollinations.ai/prompt/";
const PREXZY_IMAGE = "https://prexzyapis.com/ai/aiwriter-image";
const NVIDIA_IMAGE = "https://ai.api.nvidia.com/v1/genai/black-forest-labs/flux.1-dev";

function pickUrl(json: any): string {
  const r = json?.result ?? json;
  const cand =
    r?.url ||
    r?.image ||
    r?.image_url ||
    (Array.isArray(r?.images) ? r.images[0]?.url || r.images[0] : "") ||
    (Array.isArray(r?.data) ? r.data[0]?.url || r.data[0] : "") ||
    (typeof r?.text === "string" && r.text.startsWith("http") ? r.text : "");
  return typeof cand === "string" ? cand : "";
}

function toDataUrl(ct: string, buf: Uint8Array) {
  let bin = "";
  for (let i = 0; i < buf.length; i++) bin += String.fromCharCode(buf[i]);
  return `data:${ct};base64,${btoa(bin)}`;
}

export const Route = createFileRoute("/api/ai/image")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const { prompt, size } = (await request.json().catch(() => ({}))) as { prompt?: string; size?: string };
        if (!prompt) return Response.json({ error: "Falta la descripción de la imagen." }, { status: 400 });

        const [w, h] = (size || "1024x1024").split("x").map((n) => parseInt(n, 10) || 1024);

        // 1) Pollinations: gratis e ilimitado
        try {
          const url = new URL(POLLINATIONS + encodeURIComponent(prompt));
          url.searchParams.set("width", String(w));
          url.searchParams.set("height", String(h));
          url.searchParams.set("nologo", "true");
          url.searchParams.set("model", "flux");
          url.searchParams.set("seed", String(Math.floor(Math.random() * 1e9)));
          const res = await fetch(url.toString(), { headers: { "User-Agent": "Mozilla/5.0" } });
          const ct = res.headers.get("content-type") || "";
          if (res.ok && ct.startsWith("image/")) {
            const buf = new Uint8Array(await res.arrayBuffer());
            if (buf.length > 1000) return Response.json({ url: toDataUrl(ct, buf) });
          }
        } catch {
          /* siguiente proveedor */
        }

        // 2) Prexzy como respaldo
        try {
          const url = new URL(PREXZY_IMAGE);
          url.searchParams.set("prompt", prompt);
          url.searchParams.set("size", size || "1024x1024");
          const token = process.env["PREXZY_TOKEN"];
          if (token) url.searchParams.set("token", token);
          const res = await fetch(url.toString(), { headers: { "User-Agent": "Mozilla/5.0" } });
          const ct = res.headers.get("content-type") || "";
          if (ct.startsWith("image/")) {
            const buf = new Uint8Array(await res.arrayBuffer());
            return Response.json({ url: toDataUrl(ct, buf) });
          }
          const raw = await res.text();
          if (raw.trim().startsWith("http")) return Response.json({ url: raw.trim() });
          const found = pickUrl(JSON.parse(raw));
          if (found) return Response.json({ url: found });
        } catch {
          /* sin respaldo */
        }

        return Response.json({ error: "El generador no devolvió ninguna imagen. Intenta de nuevo." }, { status: 502 });
      },
    },
  },
});
