import { createFileRoute } from "@tanstack/react-router";

const ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";
const MODEL = "qwen/qwen3.8-27b";

type Msg = { role: string; content: any };

function flatten(content: any): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((p: any) => {
        if (typeof p === "string") return p;
        if (p?.type === "text") return p.text;
        if (p?.type === "image_url") return `[imagen: ${p.image_url?.url}]`;
        if (p?.type === "video_url") return `[video: ${p.video_url?.url}]`;
        return "";
      })
      .filter(Boolean)
      .join("\n");
  }
  return String(content ?? "");
}

export const Route = createFileRoute("/api/ai/chat")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const body = (await request.json().catch(() => ({}))) as { messages?: Msg[]; mode?: string };
        const incoming = body.messages || [];

        const apiKey = process.env["GROQ_API_KEY"];
        if (!apiKey) return Response.json({ error: "Falta la clave de Groq." }, { status: 500 });

        // Toda la memoria/conocimiento va completa: los system se unen en uno solo.
        const systems = incoming.filter((m) => m.role === "system").map((m) => flatten(m.content));
        if (body.mode === "search") {
          systems.push(
            "Responde con la información más actual y verificable que conozcas e indica cuando un dato pueda haber cambiado.",
          );
        }
        const convo = incoming
          .filter((m) => m.role !== "system")
          .map((m) => ({ role: m.role === "assistant" ? "assistant" : "user", content: flatten(m.content) }))
          .filter((m) => m.content);

        const messages = [
          ...(systems.length ? [{ role: "system", content: systems.join("\n\n") }] : []),
          ...convo,
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
              model: MODEL,
              messages,
              max_tokens: 8192,
              stream: true,
            }),
          });
        } catch (e) {
          return Response.json({ error: "No se pudo contactar al proveedor." }, { status: 502 });
        }

        // Solo Profundo: sin respaldo de otros proveedores.

        if (!upstream.ok || !upstream.body) {
          const detail = await upstream.text().catch(() => "");
          return Response.json(
            { error: upstream.status===401?"La clave de Profundo no es válida. Revísala en tu cuenta de profundoai.com.":upstream.status===402?"Sin saldo en Profundo. Recarga tu cuenta en profundoai.com.":upstream.status===429?"Demasiadas solicitudes, intenta en unos segundos.":`Profundo no respondió (${upstream.status}). ${detail.slice(0, 200)}` },
            { status: upstream.status===401||upstream.status===402||upstream.status===429?upstream.status:502 },
          );
        }

        // Se reenvía como SSE, descartando el razonamiento interno del modelo.
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
