// Offline AI for the Builda build: a small GGUF model runs inside the game via WebAssembly.
import { Wllama } from "@wllama/wllama";

const SYSTEM =
  "Eres Orión Estellar, una asistente de IA amable y breve. Respondes siempre en español, con frases claras y cortas.";

let ready: Promise<Wllama> | null = null;

function load(): Promise<Wllama> {
  if (!ready) {
    ready = (async () => {
      const w = new Wllama({ default: new URL("./wasm/wllama.wasm", document.baseURI).href } as any, { suppressNativeLog: true });
      const res = await fetch(new URL("./model.bin", document.baseURI).href);
      if (!res.ok) throw new Error(`No se pudo cargar el modelo local (${res.status}).`);
      const blob = await res.blob();
      await w.loadModel([blob], { n_ctx: 2048, n_gpu_layers: 0 } as any);
      return w;
    })().catch((e) => {
      ready = null;
      throw e;
    });
  }
  return ready;
}

export function preloadLocalAi() {
  load().catch(() => {});
}

function text(content: any): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.filter((p: any) => p?.type === "text").map((p: any) => p.text).join("\n");
  return String(content ?? "");
}

/** Returns an OpenAI-style SSE Response, matching what /api/ai/chat streams. */
export function localChatResponse(body: any, signal?: AbortSignal | null): Response {
  const convo = (body?.messages ?? [])
    .filter((m: any) => m.role === "user" || m.role === "assistant")
    .slice(-6)
    .map((m: any) => ({ role: m.role, content: text(m.content).slice(0, 1500) }));
  const enc = new TextEncoder();
  const stream = new ReadableStream({
    async start(ctrl) {
      const send = (s: string) =>
        ctrl.enqueue(enc.encode(`data: ${JSON.stringify({ choices: [{ delta: { content: s } }] })}\n\n`));
      try {
        const w = await load();
        await w.createChatCompletion({
          messages: [{ role: "system", content: SYSTEM }, ...convo],
          max_tokens: 400,
          temperature: 0.7,
          stream: true,
          abortSignal: signal ?? undefined,
          onData: (c: any) => {
            const d = c?.choices?.[0]?.delta?.content;
            if (d) send(d);
          },
        } as any);
      } catch (e: any) {
        if (e?.name !== "AbortError") send(`\n\n_(IA local: ${e?.message || "error"})_`);
      }
      ctrl.enqueue(enc.encode("data: [DONE]\n\n"));
      ctrl.close();
    },
  });
  return new Response(stream, { headers: { "Content-Type": "text/event-stream" } });
}
