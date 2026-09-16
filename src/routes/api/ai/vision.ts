import { createFileRoute } from "@tanstack/react-router";

const ENDPOINT = "https://integrate.api.nvidia.com/v1/chat/completions";
const VISION_MODEL = "meta/llama-3.2-11b-vision-instruct";
const MAX_B64 = 180_000; // límite de imagen en línea del proveedor

function toBase64(buf: Uint8Array) {
  let bin = "";
  for (let i = 0; i < buf.length; i++) bin += String.fromCharCode(buf[i]);
  return btoa(bin);
}

async function toDataUrl(src: string): Promise<string | null> {
  try {
    if (src.startsWith("data:")) {
      const b64 = src.split(",")[1] || "";
      return b64.length > MAX_B64 ? null : src;
    }
    const res = await fetch(src);
    if (!res.ok) return null;
    const ct = res.headers.get("content-type") || "image/jpeg";
    if (!ct.startsWith("image/")) return null;
    const b64 = toBase64(new Uint8Array(await res.arrayBuffer()));
    if (b64.length > MAX_B64) return null;
    return `data:${ct};base64,${b64}`;
  } catch {
    return null;
  }
}

export const Route = createFileRoute("/api/ai/vision")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const body = (await request.json().catch(() => ({}))) as { prompt?: string; images?: string[] };
        const prompt = body.prompt || "Analiza la imagen y descríbela con detalle.";
        const srcs = (body.images || []).slice(0, 1);

        const apiKey = process.env["NVIDIA_API_KEY"];
        if (!apiKey) return Response.json({ error: "Falta la clave de NVIDIA." }, { status: 500 });

        const images = (await Promise.all(srcs.map(toDataUrl))).filter(Boolean) as string[];
        if (!images.length)
          return Response.json(
            { error: "No se pudo leer la imagen (formato no soportado o demasiado pesada)." },
            { status: 400 },
          );

        const content: any[] = [
          { type: "text", text: prompt },
          ...images.map((url) => ({ type: "image_url", image_url: { url } })),
        ];

        let upstream: Response;
        try {
          upstream = await fetch(ENDPOINT, {
            method: "POST",
            headers: {
              Authorization: `Bearer ${apiKey}`,
              "Content-Type": "application/json",
              Accept: "text/event-stream",
            },
            body: JSON.stringify({
              model: VISION_MODEL,
              messages: [{ role: "user", content }],
              temperature: 0.6,
              max_tokens: 4096,
              stream: true,
            }),
          });
        } catch {
          return Response.json({ error: "No se pudo contactar al proveedor de visión." }, { status: 502 });
        }

        if (!upstream.ok || !upstream.body) {
          const detail = await upstream.text().catch(() => "");
          return Response.json(
            { error: `El proveedor de visión no respondió (${upstream.status}). ${detail.slice(0, 200)}` },
            { status: 502 },
          );
        }

        const reader = upstream.body.getReader();
        const decoder = new TextDecoder();
        const enc = new TextEncoder();

        const stream = new ReadableStream({
          async start(controller) {
            let buffer = "";
            const send = (text: string) =>
              controller.enqueue(enc.encode(`data: ${JSON.stringify({ choices: [{ delta: { content: text } }] })}\n\n`));
            try {
              while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                buffer += decoder.decode(value, { stream: true });
                const lines = buffer.split("\n");
                buffer = lines.pop() || "";
                for (const line of lines) {
                  const t = line.trim();
                  if (!t.startsWith("data:")) continue;
                  const payload = t.slice(5).trim();
                  if (!payload || payload === "[DONE]") continue;
                  try {
                    const json: any = JSON.parse(payload);
                    const delta = json?.choices?.[0]?.delta?.content;
                    if (delta) send(String(delta));
                  } catch {
                    /* fragmento parcial */
                  }
                }
              }
            } catch {
              /* fin abrupto */
            }
            controller.enqueue(enc.encode("data: [DONE]\n\n"));
            controller.close();
          },
        });

        return new Response(stream, {
          headers: { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
        });
      },
    },
  },
});
