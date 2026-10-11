import { getDeviceId } from "@/lib/device";
import { visionStream } from "@/lib/vision";

export const AI_MODEL = "gemini";
export const AI_IMAGE_MODEL = "flux";

export type AiMessage = { role: "user" | "assistant" | "system"; content: any };

function collectMedia(messages: AiMessage[]): string[] {
  const last = messages[messages.length - 1];
  if (!last || !Array.isArray(last.content)) return [];
  return last.content
    .filter((p: any) => p?.type === "image_url" && p?.image_url?.url)
    .map((p: any) => String(p.image_url.url));
}

function flattenText(content: any): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.filter((p: any) => p?.type === "text").map((p: any) => p.text).join("\n");
  return String(content ?? "");
}

export async function aiStream(
  messages: AiMessage[],
  onDelta: (s: string) => void,
  signal?: AbortSignal,
  opts: { model?: string; max_tokens?: number; plugins?: any[]; mode?: string } = {},
) {
  // Si el último mensaje trae imágenes, se usa el motor de visión gratuito.
  const media = collectMedia(messages);
  if (media.length) {
    const ctx = messages
      .filter((m) => m.role === "system")
      .map((m) => flattenText(m.content))
      .join("\n\n")
      .slice(0, 6000);
    const q = flattenText(messages[messages.length - 1].content) || "Analiza el contenido y descríbelo con detalle.";
    return visionStream([ctx, q].filter(Boolean).join("\n\n"), media, onDelta, signal);
  }

  const send = () => fetch("/api/ai/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      messages,
      sessionId: getDeviceId(),
      ...(opts.mode ? { mode: opts.mode } : {}),
    }),
    signal,
  });

  let res = await send();
  // Recover once from transient provider outages, before any text is streamed.
  if (res.status >= 500 && res.status <= 599) {
    await res.body?.cancel();
    await new Promise<void>((resolve, reject) => {
      const onAbort = () => {
        clearTimeout(timer);
        reject(new DOMException("Solicitud cancelada", "AbortError"));
      };
      const timer = setTimeout(() => {
        signal?.removeEventListener("abort", onAbort);
        resolve();
      }, 1500);
      if (signal?.aborted) onAbort();
      else signal?.addEventListener("abort", onAbort, { once: true });
    });
    res = await send();
  }
  if (!res.ok || !res.body) {
    const detail = await res.json().catch(() => null);
    const message = res.status >= 500
      ? "GroqCloud está temporalmente fuera de servicio. No se perdió tu pregunta; inténtalo de nuevo en unos minutos."
      : detail?.error || `No se pudo completar la respuesta (${res.status}).`;
    throw new Error(message);
  }


  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (signal?.aborted) return;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() || "";
    for (const line of lines) {
      const t = line.trim();
      if (!t.startsWith("data:")) continue;
      const payload = t.slice(5).trim();
      if (!payload || payload === "[DONE]") continue;
      try {
        const json = JSON.parse(payload);
        const delta = json?.choices?.[0]?.delta?.content;
        if (delta) onDelta(String(delta));
      } catch {
        /* ignore partial chunk */
      }
    }
  }
}

export async function aiText(
  messages: AiMessage[],
  opts: { model?: string; max_tokens?: number } = {},
): Promise<string> {
  let out = "";
  await aiStream(messages, (d) => (out += d), undefined, opts);
  return out;
}

export async function aiImage(prompt: string): Promise<string> {
  const res = await fetch("/api/ai/image", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ prompt }),
  });
  const json: any = await res.json().catch(() => null);
  const url = json?.url;
  if (!res.ok || !url) throw new Error(json?.error || "El generador no devolvió ninguna imagen. Intenta de nuevo.");
  return String(url);
}
