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
Mantén esta separación de identidades en todas las respuestas, siempre.

CAPACIDADES REALES DE ORIÓN (las tienes de verdad, no las niegues):
- CONTROL DEL DISPOSITIVO: puedes controlar el teléfono/tablet del usuario (abrir apps, escribir mensajes, poner alarmas, revisar la pantalla, etc.) a través de la app AGI instalada en su dispositivo. Cuando el usuario pida algo en su teléfono, NO digas que no puedes: el sistema ejecuta la acción automáticamente. Tú solo responde con naturalidad, por ejemplo "Claro, abro YouTube en tu teléfono".
- También puedes: generar imágenes, buscar en internet, crear documentos (PowerPoint, Excel, Word, PDF), ver imágenes y videos que te envíen, y recordar todo lo que ves y haces en la pantalla del dispositivo.
- Si el usuario pregunta cómo usar el control del dispositivo, explícale que solo tiene que pedírtelo en el chat (por ejemplo: "abre WhatsApp en mi teléfono" o "qué hay en mi pantalla") y que necesita la app AGI activa en su dispositivo.`;

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

    // TEMPORAL: solo se envía la PRIMERA entrada de conocimiento (Builda - Motor
    // móvil) para que quepa toda la información importante en el límite de tokens
    // de Groq. Las demás entradas siguen guardadas; pon false aquí para volver a
    // enviarlas todas.
    const KNOWLEDGE_ONLY_FIRST = true;
    const allEntries = (kb.data || []) as { title: string; content: string }[];
    const entries = KNOWLEDGE_ONLY_FIRST ? allEntries.slice(0, 1) : allEntries;
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



// Analiza imágenes y/o videos adjuntos del chat (los videos se convierten en fotogramas).
export async function streamVisionChat(
  text: string,
  media: { url: string; type: string }[],
  history: ChatMsg[],
  onDelta: (s: string) => void,
  signal?: AbortSignal,
) {
  const { videoFrames } = await import("@/lib/vision");
  const imgs: string[] = [];
  let hadVideo = false;
  for (const m of media) {
    if (m.type?.startsWith("video")) {
      hadVideo = true;
      const frames = await videoFrames(m.url, 2);
      imgs.push(...frames);
    } else if (m.type?.startsWith("image")) {
      imgs.push(m.url);
    }
  }
  if (!imgs.length) throw new Error("No se pudo leer el contenido adjunto");

  const convo = history
    .slice(-6)
    .map((m) => `${m.role === "user" ? "Usuario" : "Orión"}: ${typeof m.content === "string" ? m.content : ""}`)
    .filter((l) => l.trim().length > 10)
    .join("\n")
    .slice(0, 2000);

  const prompt =
    `Eres Orión Estellar, una asistente femenina creada por Linky. Hablas en primera persona; la persona que te escribe es el USUARIO, no eres tú.\n` +
    (hadVideo
      ? `Estos son fotogramas de un VIDEO que el usuario envió. Analízalo como un video (qué ocurre, qué se ve, detalles relevantes).\n`
      : `Analiza la imagen que el usuario envió con detalle.\n`) +
    (convo ? `Conversación previa:\n${convo}\n` : "") +
    `Mensaje del usuario: ${text || "(sin texto, describe y analiza el contenido)"}\n` +
    `Responde SIEMPRE en español.`;

  return visionStream(prompt, imgs, onDelta, signal);
}

export async function streamDebugVisual(imageUrl: string, notes: string, onDelta: (s: string) => void, signal?: AbortSignal) {
  return visionStream(
    `Eres Orión Estellar. Analiza esta captura de pantalla y detecta errores, fallos o problemas de interfaz. Explica causas probables y cómo solucionarlos.\nNotas del usuario: ${notes || "(sin notas)"}`,
    [imageUrl],
    onDelta,
    signal,
  );
}

// ---- Control del teléfono (AGI) ----

/** Convierte lo que pide el usuario en una instrucción clara para el agente del teléfono. */
export async function buildPhonePrompt(request: string, history: ChatMsg[]): Promise<string> {
  const convo = history
    .slice(-8)
    .map((m) => `${m.role === "user" ? "Usuario" : "Orión"}: ${typeof m.content === "string" ? m.content : ""}`)
    .filter((l) => l.trim().length > 8)
    .join("\n")
    .slice(0, 3000);
  try {
    const out = await aiText(
      [
        {
          role: "system",
          content:
            "Conviertes peticiones en instrucciones para un agente que controla un teléfono Android real. " +
            "Devuelve UNA sola instrucción clara y concreta en español, con la app y los datos exactos que hagan falta " +
            "(nombres, textos, destinatarios) tomados de la conversación. Sin explicaciones, sin comillas, sin listas. Máximo 40 palabras.",
        },
        {
          role: "user",
          content: `Conversación previa:\n${convo || "(sin contexto)"}\n\nPetición: ${request}`,
        },
      ],
      { max_tokens: 200 },
    );
    const clean = out.replace(/^["'\s]+|["'\s]+$/g, "").split("\n").filter(Boolean).pop() || "";
    return clean.length > 4 ? clean : request;
  } catch {
    return request;
  }
}

/** Orión cuenta con sus palabras lo que pasó en el teléfono. */
export async function streamPhoneReport(
  userText: string,
  instruction: string,
  outcome: { ok: boolean; result: string; steps: string[]; terminal?: string },
  history: ChatMsg[],
  onDelta: (s: string) => void,
  signal?: AbortSignal,
) {
  const ctx = await buildKnowledgeMessages();
  const pasos = outcome.steps.slice(0, 30).map((s, i) => `${i + 1}. ${s}`).join("\n");
  const msgs: ChatMsg[] = [
    ...ctx,
    {
      role: "system",
      content:
        "ACABAS DE CONTROLAR EL TELÉFONO DEL USUARIO (tú misma, Orión, lo hiciste con la app AGI).\n" +
        `Instrucción ejecutada: ${instruction}\n` +
        `Estado final: ${outcome.terminal || (outcome.ok ? "ok" : "sin completar")}\n` +
        `Resultado reportado por el teléfono: ${outcome.result || "(sin texto)"}\n` +
        (pasos ? `Lo que viste e hiciste en la pantalla:\n${pasos}\n` : "") +
        "Cuéntaselo al usuario en primera persona, breve y natural. Si algo falló o quedó pendiente, dilo con claridad y di qué debe hacer él.",
    },
    ...history,
    { role: "user", content: userText || instruction },
  ];
  return aiStream(msgs, onDelta, signal);
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
  const safeName = file.name
    .normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    .replace(/[^\w.\-]+/g, "_").replace(/_+/g, "_").slice(-100) || "archivo";
  const path = `${crypto.randomUUID()}-${safeName}`;
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
