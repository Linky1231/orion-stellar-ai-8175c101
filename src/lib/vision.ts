// Análisis visual: NVIDIA (principal) con motor gratuito Puter.js como respaldo.
let loading: Promise<any> | null = null;

export function loadVisionEngine(): Promise<any> {
  if (typeof window === "undefined") return Promise.reject(new Error("Solo disponible en el navegador"));
  const w = window as any;
  if (w.puter) return Promise.resolve(w.puter);
  if (!loading) {
    loading = new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = "https://js.puter.com/v2/";
      s.async = true;
      s.onload = () => {
        const tries = 40;
        let n = 0;
        const t = window.setInterval(() => {
          if ((window as any).puter?.ai) {
            window.clearInterval(t);
            resolve((window as any).puter);
          } else if (++n > tries) {
            window.clearInterval(t);
            reject(new Error("El motor de visión no se inicializó"));
          }
        }, 250);
      };
      s.onerror = () => reject(new Error("No se pudo cargar el motor de visión"));
      document.head.appendChild(s);
    });
  }
  return loading;
}

export const VISION_MODELS = [
  "google/gemini-2.5-flash",
  "gpt-5-nano",
  "claude-sonnet-4",
  "openrouter:meta-llama/llama-4-scout",
];

function isImage(src: string) {
  if (src.startsWith("data:")) return src.startsWith("data:image/");
  return !/\.(mp4|webm|mov|m4v|avi|mkv)(\?|$)/i.test(src);
}

function errText(e: any) {
  if (!e) return "";
  if (typeof e === "string") return e;
  if (e instanceof Error) return e.message;
  const m = e?.message || e?.error?.message || e?.error || e?.detail;
  if (typeof m === "string") return m;
  try {
    return JSON.stringify(e).slice(0, 160);
  } catch {
    return String(e);
  }
}

// Reduce la imagen en el navegador para que el proveedor pueda leerla siempre.
async function shrink(src: string, max = 900, quality = 0.72): Promise<string> {
  if (typeof document === "undefined") return src;
  try {
    const img = await new Promise<HTMLImageElement>((resolve, reject) => {
      const i = new Image();
      i.crossOrigin = "anonymous";
      i.onload = () => resolve(i);
      i.onerror = () => reject(new Error("no-load"));
      i.src = src;
    });
    const scale = Math.min(1, max / Math.max(img.naturalWidth, img.naturalHeight));
    const w = Math.max(1, Math.round(img.naturalWidth * scale));
    const h = Math.max(1, Math.round(img.naturalHeight * scale));
    const c = document.createElement("canvas");
    c.width = w;
    c.height = h;
    const ctx = c.getContext("2d");
    if (!ctx) return src;
    ctx.drawImage(img, 0, 0, w, h);
    let out = c.toDataURL("image/jpeg", quality);
    if (out.length > 230_000) out = c.toDataURL("image/jpeg", 0.5);
    return out;
  } catch {
    return src;
  }
}

async function nvidiaVision(
  prompt: string,
  images: string[],
  onDelta: (s: string) => void,
  signal?: AbortSignal,
): Promise<boolean> {
  const small = await Promise.all(images.slice(0, 1).map((s) => shrink(s)));
  const res = await fetch("/api/ai/vision", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ prompt, images: small }),
    signal,
  });
  if (!res.ok || !res.body) return false;

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let got = false;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (signal?.aborted) return true;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() || "";
    for (const line of lines) {
      const t = line.trim();
      if (!t.startsWith("data:")) continue;
      const payload = t.slice(5).trim();
      if (!payload || payload === "[DONE]") continue;
      try {
        const delta = JSON.parse(payload)?.choices?.[0]?.delta?.content;
        if (delta) {
          got = true;
          onDelta(String(delta));
        }
      } catch {
        /* fragmento parcial */
      }
    }
  }
  return got;
}

export async function visionStream(
  prompt: string,
  images: string[],
  onDelta: (s: string) => void,
  signal?: AbortSignal,
) {
  let lastError: any = null;

  if (images.length && images.every(isImage)) {
    try {
      if (await nvidiaVision(prompt, images, onDelta, signal)) return;
    } catch (e) {
      if (signal?.aborted) return;
      lastError = e;
    }
  }

  let puter: any = null;
  try {
    puter = await loadVisionEngine();
  } catch (e) {
    lastError = e;
  }

  if (puter) {
    for (const model of VISION_MODELS) {
      if (signal?.aborted) return;
      try {
        const arg = images.length === 1 ? images[0] : images;
        const resp = await puter.ai.chat(prompt, arg, false, { model, stream: true });
        let got = false;
        for await (const part of resp) {
          if (signal?.aborted) return;
          const t = part?.text ?? "";
          if (t) {
            got = true;
            onDelta(String(t));
          }
        }
        if (got) return;
      } catch (e) {
        lastError = e;
      }
    }

    try {
      const resp = await puter.ai.chat(prompt, images[0], false, { model: VISION_MODELS[0] });
      const txt = resp?.message?.content ?? resp?.text ?? String(resp ?? "");
      const out = Array.isArray(txt) ? txt.map((p: any) => p?.text || "").join("") : String(txt);
      if (out.trim()) {
        onDelta(out);
        return;
      }
    } catch (e) {
      lastError = e;
    }
  }

  const detail = errText(lastError);
  throw new Error("No se pudo analizar el contenido visual" + (detail ? ` (${detail})` : ""));
}
