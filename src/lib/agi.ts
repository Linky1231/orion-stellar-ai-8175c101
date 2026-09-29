// Control del teléfono del usuario a través de la app AGI (AGI, Inc.)
import { supabase } from "@/integrations/supabase/client";
import { getDeviceId } from "@/lib/device";

export type AgiDevice = {
  device_id: string;
  device_name: string;
  device_model?: string;
  status: "online" | "offline" | string;
  paused?: boolean;
  is_default?: boolean;
  last_seen?: string;
};

export type AgiStep = {
  index?: number;
  thought?: string;
  action?: string;
  summary?: string;
  screenshot?: string;
  screenshot_url?: string;
  [k: string]: any;
};

export type PhoneProgress = {
  phase: "checking" | "starting" | "running" | "paused" | "done" | "error";
  label: string;
  steps: string[];
  screenshot?: string | null;
};

async function tool<T = any>(name: string, args: Record<string, any> = {}): Promise<T> {
  const res = await fetch("/api/agi/mcp", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ tool: name, args }),
  });
  const json: any = await res.json().catch(() => null);
  if (!res.ok || json?.error) throw new Error(json?.error || `Error ${res.status}`);
  return json.data as T;
}

export async function listDevices(): Promise<AgiDevice[]> {
  const data = await tool<{ devices?: AgiDevice[] }>("list_devices");
  return data?.devices || [];
}

/** ¿El usuario está pidiendo que Orión use su teléfono? */
const PHONE_RE =
  /\b(en|con|desde|usa|usar|abre|abrir|abri|controla|controlar|toma el control|maneja|manejar)\b[^.?!]{0,30}\b(mi )?(tel[eé]fono|celular|m[oó]vil|dispositivo|pantalla|tablet|tel[eé)]?)\b|\b(abre|abri|abrir|entra a|entra en|ve a)\s+(whatsapp|instagram|facebook|youtube|tiktok|chrome|gmail|uber|telegram|spotify|twitter|x|messenger|ajustes|configuraci[oó]n|la c[aá]mara|la galer[ií]a|el navegador)\b|\b(m[aá]ndale?|env[ií]ale?|escr[ií]bele?|mandar|enviar|escribir)\s+(un\s+)?(mensaje|whats?app|correo|sms)\b|\bpon(er)?\s+(una\s+)?(alarma|temporizador|recordatorio|m[uú]sica)\b|\b(ll[aá]male?|llamar)\s+a\b|\brevisa\b[^.?!]{0,25}\b(mi )?(tel[eé]fono|celular|pantalla|whatsapp|notificaciones|correo|mensajes)\b|\bhaz(lo)?\s+(esto\s+)?(en|por)\s+(mi|el)\s+(tel[eé]fono|celular|m[oó]vil|dispositivo|pantalla)\b|\btoma una captura\b|\bqu[eé] hay en (mi|la) pantalla\b/i;

export function detectPhoneRequest(text: string) {
  if (!text) return false;
  return PHONE_RE.test(text);
}

function pickScreenshot(step: AgiStep): string | null {
  const s = step.screenshot_url || step.screenshot || (step as any).image_url || (step as any).image;
  if (typeof s !== "string" || !s) return null;
  if (s.startsWith("http") || s.startsWith("data:")) return s;
  return `data:image/jpeg;base64,${s}`;
}

function describeStep(step: AgiStep, i: number): string {
  const bits = [step.summary, step.action, step.thought]
    .filter((x) => typeof x === "string" && x.trim())
    .map((x) => String(x).trim());
  if (!bits.length) return `Paso ${i + 1}`;
  return bits[0].slice(0, 200);
}

/**
 * Ejecuta una instrucción en el teléfono del usuario y va reportando el avance.
 * Guarda en la memoria de Orión todo lo que vio y lo que hizo en la pantalla.
 */
export async function runPhoneTask(
  prompt: string,
  onProgress: (p: PhoneProgress) => void,
  signal?: AbortSignal,
): Promise<{ ok: boolean; result: string; steps: string[]; screenshot?: string | null; terminal?: string }> {
  const steps: string[] = [];
  let lastShot: string | null = null;
  const report = (phase: PhoneProgress["phase"], label: string) =>
    onProgress({ phase, label, steps: [...steps], screenshot: lastShot });

  report("checking", "Buscando tu teléfono…");
  const devices = await listDevices();
  const device = devices.find((d) => d.status === "online" && !d.paused) || devices[0];
  if (!device) throw new Error("No encuentro ningún teléfono vinculado a tu cuenta de AGI.");
  if (device.status !== "online") {
    throw new Error(`Tu ${device.device_name} está desconectado. Abre la app AGI en el teléfono.`);
  }
  if (device.paused) {
    throw new Error(`El control de tu ${device.device_name} está en pausa. Reanúdalo en la app AGI.`);
  }

  report("starting", `Conectada a ${device.device_name}`);
  const start = await tool<any>("phone_run_task", {
    device_id: device.device_id,
    prompt,
    per_call_timeout_s: 300,
    queue_wait_timeout_s: 60,
  });
  const taskId: string = start?.task_id || start?.taskId;
  if (!taskId) throw new Error("El teléfono no aceptó la tarea.");

  report("running", "Trabajando en tu teléfono…");

  let sinceStep = 0;
  let terminal = "";
  let result = "";
  const deadline = Date.now() + 10 * 60 * 1000;

  while (Date.now() < deadline) {
    if (signal?.aborted) {
      await tool("phone_task_cancel", { device_id: device.device_id, task_id: taskId, reason: "user_stop" }).catch(
        () => {},
      );
      throw new Error("Tarea cancelada.");
    }

    const mon = await tool<any>("phone_task_monitor", {
      task_id: taskId,
      timeout_s: 30,
      include_steps: true,
      since_step: sinceStep,
    });

    const newSteps: AgiStep[] = mon?.steps || mon?.task?.steps || [];
    for (const st of newSteps) {
      const shot = pickScreenshot(st);
      if (shot) lastShot = shot;
      steps.push(describeStep(st, steps.length));
    }
    if (newSteps.length) sinceStep += newSteps.length;

    const status = mon?.status || mon?.task?.status;
    terminal = mon?.terminal || mon?.task?.terminal || "";
    result = mon?.result || mon?.task?.result || result;

    if (mon?.monitor_timed_out) {
      report("running", "Sigue trabajando en tu teléfono…");
      continue;
    }

    if (status === "paused" || terminal === "needs_user_control") {
      report("paused", "Necesito que confirmes algo en la pantalla de tu teléfono.");
      return {
        ok: false,
        result:
          result ||
          "El teléfono pide tu confirmación (contraseña, huella o un aviso). Termina ese paso en la pantalla y dime cuando siga.",
        steps,
        screenshot: lastShot,
        terminal: terminal || "paused",
      };
    }

    if (status === "completed" || terminal) break;
    report("running", "Sigue trabajando en tu teléfono…");
  }

  const ok = terminal === "ok";
  report(ok ? "done" : "error", ok ? "Listo en tu teléfono" : "La tarea terminó sin completarse");

  // Memoria visual: Orión recuerda lo que vio y lo que hizo en la pantalla.
  void storeScreenMemory(prompt, steps, result, device.device_name, terminal);

  return { ok, result: result || (ok ? "Tarea completada." : mensajeTerminal(terminal)), steps, screenshot: lastShot, terminal };
}

function mensajeTerminal(t: string) {
  switch (t) {
    case "timeout":
      return "La tarea tardó demasiado en el teléfono y se detuvo.";
    case "stopped_by_user":
      return "Detuviste la tarea desde el teléfono.";
    case "device_offline":
      return "El teléfono se desconectó a mitad de la tarea.";
    case "queue_wait_exceeded":
      return "El teléfono no respondió a tiempo para empezar.";
    case "iteration_limit":
      return "La tarea necesitó demasiados pasos y se detuvo.";
    case "agent_error":
      return "Hubo un problema al ejecutar la tarea en el teléfono.";
    default:
      return "La tarea no se completó.";
  }
}

async function storeScreenMemory(
  prompt: string,
  steps: string[],
  result: string,
  deviceName: string,
  terminal: string,
) {
  try {
    const cuando = new Date().toLocaleString("es-ES");
    const resumenPasos = steps.slice(0, 40).map((s, i) => `${i + 1}. ${s}`).join("\n");
    const content =
      `[PANTALLA DEL DISPOSITIVO · ${deviceName} · ${cuando}] ` +
      `El usuario pidió: "${prompt}". ` +
      `Resultado (${terminal || "sin estado"}): ${result || "sin resultado"}.` +
      (resumenPasos ? `\nLo que vi e hice en la pantalla:\n${resumenPasos}` : "");
    await supabase.from("user_memory" as any).insert({
      device_id: getDeviceId(),
      content: content.slice(0, 6000),
      kind: "device_screen",
    });
  } catch (e) {
    console.warn("screen memory failed", e);
  }
}
