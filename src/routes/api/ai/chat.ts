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

        // Groq (plan gratuito) limita ~7000 tokens por minuto: recortamos memoria e historial.
        const SYS_MAX = 12000;
        const CONVO_MAX = 6000;
        let sys = systems.join("\n\n");
        if (sys.length > SYS_MAX) sys = sys.slice(0, SYS_MAX / 2) + "\n…\n" + sys.slice(-SYS_MAX / 2);
        const trimmed: { role: string; content: string }[] = [];
        let used = 0;
        for (let i = convo.length - 1; i >= 0; i--) {
          let c = convo[i].content;
          const left = CONVO_MAX - used;
          if (left <= 200 && trimmed.length) break;
          if (c.length > left) c = c.slice(-Math.max(left, 200));
          trimmed.unshift({ role: convo[i].role, content: c });
          used += c.length;
        }
        if (trimmed[0]?.role === "assistant") trimmed.shift();
        const messages = [...(sys ? [{ role: "system", content: sys }] : []), ...trimmed];

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

        if (!upstream.ok || !upstream.body) {
          const detail = await upstream.text().catch(() => "");
          return Response.json(
            { error: upstream.status===401?"La clave de Groq no es válida. Revísala en console.groq.com.":upstream.status===429?"Límite de Groq alcanzado, intenta en unos segundos.":`Groq no respondió (${upstream.status}). ${detail.slice(0, 200)}` },
            { status: upstream.status===401||upstream.status===429?upstream.status:502 },
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
