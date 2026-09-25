import { createFileRoute } from "@tanstack/react-router";

const ENDPOINT = "https://ai.gateway.lovable.dev/v1/chat/completions";
const IMAGE_MODEL = "google/gemini-3.1-flash-image";

export const Route = createFileRoute("/api/ai/image")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const { prompt } = (await request.json().catch(() => ({}))) as { prompt?: string };
        if (!prompt) return Response.json({ error: "Falta la descripción de la imagen." }, { status: 400 });

        const apiKey = process.env["LOVABLE_API_KEY"];
        if (!apiKey) return Response.json({ error: "Falta la clave de Lovable AI." }, { status: 500 });

        try {
          const res = await fetch(ENDPOINT, {
            method: "POST",
            headers: { "Lovable-API-Key": apiKey, "X-Lovable-AIG-SDK": "fetch", "Content-Type": "application/json" },
            body: JSON.stringify({
              model: IMAGE_MODEL,
              messages: [{ role: "user", content: prompt }],
              modalities: ["image", "text"],
            }),
          });
          if (!res.ok) {
            const msg =
              res.status === 402
                ? "Sin créditos de IA. Recarga en Ajustes → Planes y créditos."
                : res.status === 429
                  ? "Demasiadas solicitudes, intenta en unos segundos."
                  : `El generador falló (${res.status}).`;
            return Response.json({ error: msg }, { status: res.status === 402 || res.status === 429 ? res.status : 502 });
          }
          const json: any = await res.json();
          const msg = json?.choices?.[0]?.message;
          const url = msg?.images?.[0]?.image_url?.url || msg?.images?.[0]?.url;
          if (url) return Response.json({ url });
          return Response.json({ error: "El generador no devolvió ninguna imagen." }, { status: 502 });
        } catch {
          return Response.json({ error: "No se pudo contactar al generador." }, { status: 502 });
        }
      },
    },
  },
});
