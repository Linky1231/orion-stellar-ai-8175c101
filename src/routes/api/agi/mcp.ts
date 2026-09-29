import { createFileRoute } from "@tanstack/react-router";

const MCP_URL = "https://api.agi.tech/v1/mcp";

/** Extrae el JSON del sobre MCP (content[].text) */
function unwrap(json: any): any {
  const err = json?.error;
  if (err) throw new Error(err.message || JSON.stringify(err));
  const result = json?.result;
  const parts = result?.content;
  if (Array.isArray(parts)) {
    const text = parts
      .filter((p: any) => p?.type === "text" && typeof p.text === "string")
      .map((p: any) => p.text)
      .join("\n");
    if (text) {
      try {
        return JSON.parse(text);
      } catch {
        return { text };
      }
    }
  }
  return result ?? {};
}

async function callTool(key: string, name: string, args: Record<string, any>) {
  const res = await fetch(MCP_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: Date.now(),
      method: "tools/call",
      params: { name, arguments: args },
    }),
  });

  const raw = await res.text();
  if (!res.ok) {
    throw new Error(`AGI ${res.status}: ${raw.slice(0, 400)}`);
  }

  // Puede venir como SSE cuando el transporte negocia streaming.
  let payload: any;
  if (raw.trimStart().startsWith("event:") || raw.includes("\ndata:")) {
    const line = raw
      .split("\n")
      .map((l) => l.trim())
      .filter((l) => l.startsWith("data:"))
      .map((l) => l.slice(5).trim())
      .filter(Boolean)
      .pop();
    payload = line ? JSON.parse(line) : {};
  } else {
    payload = JSON.parse(raw);
  }
  return unwrap(payload);
}

export const Route = createFileRoute("/api/agi/mcp")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const key = process.env["AGI_API_KEY"];
        if (!key) {
          return Response.json(
            { error: "El control del teléfono no está configurado." },
            { status: 500 },
          );
        }
        const body = (await request.json().catch(() => ({}))) as {
          tool?: string;
          args?: Record<string, any>;
        };
        const tool = body.tool;
        if (!tool) return Response.json({ error: "Falta la herramienta." }, { status: 400 });

        const allowed = new Set([
          "list_devices",
          "set_default_device",
          "phone_task_list",
          "phone_session_start",
          "phone_run_task",
          "phone_task_status",
          "phone_task_monitor",
          "phone_task_message",
          "phone_task_cancel",
          "phone_task_resume",
          "phone_session_end",
          "phone_device_status",
          "phone_get_state",
        ]);
        if (!allowed.has(tool)) {
          return Response.json({ error: "Herramienta no permitida." }, { status: 400 });
        }

        try {
          const data = await callTool(key, tool, body.args || {});
          return Response.json({ data });
        } catch (e: any) {
          return Response.json({ error: String(e?.message || e) }, { status: 502 });
        }
      },
    },
  },
});
