import { supabase } from "@/integrations/supabase/client";
import { getDeviceId } from "@/lib/device";
import { aiStream, aiText, aiImage, AI_MODEL } from "@/lib/ai";
import { visionStream } from "@/lib/vision";

export type ChatMsg = { role: "user" | "assistant" | "system"; content: any };

// ---- Conocimiento (memoria) ----
const IDENTITY = `IDENTIDAD (regla absoluta e inviolable):
- TÚ eres Orión Estellar, una asistente (femenina) creada por Linky. Hablas SIEMPRE en primera persona como Orión.
- La persona con la que hablas es EL USUARIO. El usuario NO es Orión y nunca debe ser llamado Orión.
- Nunca te dirijas al usuario como "Orión", nunca le atribuyas tu identidad, tu personalidad ni tus datos.
- Los mensajes con rol "user" son del usuario; los mensajes con rol "assistant" son tuyos (Orión).
- La información de la base de conocimiento y de la configuración describe a Orión (tú), no al usuario.
- Los datos de "MEMORIA DEL USUARIO" describen al usuario, no a ti.
Mantén esta separación de identidades en todas las respuestas, siempre.`;

async function buildKnowledgeMessages(): Promise<ChatMsg[]> {
  const out: ChatMsg[] = [{ role: "system", content: IDENTITY }];
  try {
    const [cfg, kb, mem, scripts] = await Promise.all([
      supabase.from("orion_config").select("personality,behavior,context").eq("id", 1).maybeSingle(),
      supabase.from("orion_knowledge").select("title,content").order("created_at", { ascending: true }),
      supabase.from("user_memory" as any).select("content").eq("device_id", getDeviceId()).order("created_at", { ascending: true }),
      supabase.from("orion_builda_scripts" as any).select("title,description,code").order("created_at", { ascending: true }),
    ]);

    const c = (cfg.data || null) as any;
    if (c) {
      out.push({
        role: "system",
        content:
          "INSTRUCCIONES DE ORIÓN (aplícalas siempre, describen cómo eres TÚ):\n" +
          `PERSONALIDAD:\n${c.personality || "(sin definir)"}\n\n` +
          `COMPORTAMIENTO:\n${c.behavior || "(sin definir)"}\n\n` +
          `CONTEXTO:\n${c.context || "(sin definir)"}`,
      });
    }

    const entries = (kb.data || []) as { title: string; content: string }[];
    if (entries.length) {
      out.push({
        role: "system",
        content:
          "BASE DE CONOCIMIENTO DE ORIÓN (usa SIEMPRE esta información como verdad y respóndela cuando sea relevante; son " +
          entries.length +
          " entradas completas):\n\n" +
          entries.map((e, i) => `#${i + 1} ${e.title}\n${e.content}`).join("\n\n---\n\n"),
      });
    }

    const scr = ((scripts.data || []) as any[]).filter((s) => s?.code);
    if (scr.length) {
      out.push({
        role: "system",
        content:
          "SCRIPTS DE BUILDA GUARDADOS EN MEMORIA (" +
          scr.length +
          " scripts). Cuando el usuario pida un script de Builda, USA SIEMPRE estos scripts como base y entrégalos completos, adaptándolos si hace falta. No inventes una sintaxis distinta:\n\n" +
          scr
            .map(
              (s, i) =>
                `### Script ${i + 1}: ${s.title}\n${s.description ? `Descripción: ${s.description}\n` : ""}\`\`\`\n${s.code}\n\`\`\``,
            )
            .join("\n\n"),
      });
    }

    const facts = ((mem.data || []) as any[]).map((m) => String(m.content)).filter(Boolean);
    if (facts.length) {
      out.push({
        role: "system",
        content: "MEMORIA DEL USUARIO (hechos sobre el USUARIO, no sobre ti):\n" + facts.map((f) => `- ${f}`).join("\n"),
      });
    }
  } catch (e) {
    console.warn("knowledge load failed", e);
  }
  return out;
}

// ---- Texto ----
export async function streamChat(messages: ChatMsg[], onDelta: (s: string) => void, signal?: AbortSignal) {
  const ctx = await buildKnowledgeMessages();
  return aiStream([...ctx, ...messages], onDelta, signal);
}

export type SearchHit = { title: string; url: string; snippet: string };

export async function webSearch(query: string): Promise<SearchHit[]> {
  try {
    const res = await fetch("/api/ai/search", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query }),
    });
    const json: any = await res.json().catch(() => null);
    return Array.isArray(json?.results) ? json.results : [];
  } catch {
    return [];
  }
}

export async function streamSearch(query: string, messages: ChatMsg[], onDelta: (s: string) => void, signal?: AbortSignal) {
  const [ctx, hits] = await Promise.all([buildKnowledgeMessages(), webSearch(query)]);
  const resultados = hits.length
    ? hits
        .map((h, i) => `[${i + 1}] ${h.title}\n${h.snippet}\nFuente: ${h.url}`)
        .join("\n\n")
    : "(la búsqueda no devolvió resultados)";

  const msgs: ChatMsg[] = [
    ...ctx,
    {
      role: "system",
      content:
        `RESULTADOS DE BÚSQUEDA WEB EN VIVO (fecha actual: ${new Date().toLocaleDateString("es-ES")}). ` +
        "Responde usando ESTOS resultados como fuente principal, resume con claridad y cita los enlaces al final. " +
        "Si los resultados no contienen el dato, dilo con honestidad.\n\n" +
        resultados,
    },
    ...messages,
    { role: "user", content: `Con base en los resultados de búsqueda, responde: ${query}` },
  ];
  return aiStream(msgs, onDelta, signal, { mode: "search" });
}

// Construye un prompt de imagen detallado usando la conversación como contexto.
export async function buildImagePrompt(request: string, history: ChatMsg[]): Promise<string> {
  const convo = history
    .slice(-8)
    .map((m) => `${m.role === "user" ? "Usuario" : "Orión"}: ${typeof m.content === "string" ? m.content : ""}`)
    .filter((l) => l.trim().length > 8)
    .join("\n")
    .slice(0, 4000);
  try {
    const out = await aiText(
      [
        {
          role: "system",
          content:
            "Eres un generador de prompts para un modelo de imágenes. Con la conversación previa y la petición, escribe UN SOLO prompt visual en inglés, detallado (sujeto, estilo, composición, luz, colores). Sin explicaciones, sin comillas, sin listas. Máximo 60 palabras.",
        },
        { role: "user", content: `Conversación previa:\n${convo || "(sin contexto)"}\n\nPetición: ${request || "(sin descripción, usa el contexto)"}` },
      ],
      { max_tokens: 200 },
    );
    const clean = out.replace(/^["'\s]+|["'\s]+$/g, "").split("\n").filter(Boolean).pop() || "";
    return clean.length > 5 ? clean : request;
  } catch {
    return request;
  }
}



export async function streamDebugVisual(imageUrl: string, notes: string, onDelta: (s: string) => void, signal?: AbortSignal) {
  return visionStream(
    `Eres Orión Estellar. Analiza esta captura de pantalla y detecta errores, fallos o problemas de interfaz. Explica causas probables y cómo solucionarlos.\nNotas del usuario: ${notes || "(sin notas)"}`,
    [imageUrl],
    onDelta,
    signal,
  );
}

// ---- Imágenes ----
export async function generateImage(prompt: string): Promise<string> {
  return aiImage(prompt);
}

export function fileToDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ""));
    reader.onerror = () => reject(reader.error || new Error("No se pudo leer la imagen"));
    reader.readAsDataURL(file);
  });
}

export async function uploadAttachment(file: File, bucket = "chat-attachments"): Promise<string> {
  const path = `${crypto.randomUUID()}-${file.name}`;
  const { error } = await supabase.storage.from(bucket).upload(path, file, { upsert: false });
  if (error) throw error;
  const { data } = supabase.storage.from(bucket).getPublicUrl(path);
  return data.publicUrl;
}

function parseJsonLoose(raw: string): any {
  const s = raw.indexOf("{");
  const e = raw.lastIndexOf("}");
  if (s === -1 || e <= s) return {};
  try {
    return JSON.parse(raw.slice(s, e + 1));
  } catch {
    return {};
  }
}

async function askJson(prompt: string): Promise<any> {
  const text = await aiText([{ role: "user", content: prompt }], { max_tokens: 600 });
  return parseJsonLoose(text);
}

// Memoria: extrae hechos con la IA y los guarda
export async function extractAndStoreMemory(text: string) {
  if (!text || text.length < 8) return;
  try {
    const out = await askJson(
      `Extrae hechos duraderos sobre el usuario del siguiente texto. Devuelve SOLO JSON con esta forma: {"facts":[{"content":"...","kind":"fact"}]}. Si no hay hechos, devuelve {"facts":[]}.\n\nTexto:\n${text}`,
    );
    const facts = out?.facts;
    if (!Array.isArray(facts) || facts.length === 0) return;
    const did = getDeviceId();
    await supabase.from("user_memory" as any).insert(
      facts
        .filter((f: any) => f?.content)
        .map((f: any) => ({ device_id: did, content: String(f.content), kind: f.kind || "fact" })),
    );
  } catch (e) {
    console.warn("memory extract failed", e);
  }
}

export async function classifyNote(title: string, content: string) {
  try {
    return await askJson(
      `Clasifica esta nota. Devuelve SOLO JSON: {"category":"...","tags":["..."],"summary":"..."}.\n\nTítulo: ${title}\nContenido: ${content}`,
    );
  } catch {
    return {};
  }
}

export async function analyzeProject(notes: any[]): Promise<string> {
  const resumen = notes
    .map((n: any) => `- ${n?.title || "(sin título)"}: ${String(n?.content || "").slice(0, 400)}`)
    .join("\n")
    .slice(0, 8000);
  return aiText(
    [
      {
        role: "user",
        content: `Analiza este conjunto de notas de un proyecto y entrega un análisis claro con puntos fuertes, riesgos y próximos pasos.\n\n${resumen}`,
      },
    ],
    { max_tokens: 1500 },
  );
}

export type DiagnosticsResult = {
  timestamp: string;
  env: Record<string, boolean>;
  results: Record<string, { ok: boolean; ms: number; sample: string; error: string | null }>;
};

export async function runDiagnostics(): Promise<DiagnosticsResult> {
  const t0 = performance.now();
  let ok = false;
  let sample = "";
  let error: string | null = null;
  try {
    sample = (await aiText([{ role: "user", content: "Responde solo: ok" }], { max_tokens: 20 })).slice(0, 120);
    ok = Boolean(sample);
  } catch (e) {
    error = String(e);
  }

  return {
    timestamp: new Date().toISOString(),
    env: { lovableAi: true },
    results: { [AI_MODEL]: { ok, ms: Math.round(performance.now() - t0), sample, error } },
  };
}
