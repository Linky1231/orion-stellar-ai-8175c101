import { defineTool } from "@lovable.dev/mcp-js";
import { z } from "zod";
import { supabaseForUser } from "../supabase";

export const listMemory = defineTool({
  name: "list_memory",
  title: "Ver memoria",
  description: "Devuelve lo que Orión recuerda del usuario.",
  inputSchema: { limit: z.number().int().min(1).max(200).optional().describe("Máximo de entradas (por defecto 50).") },
  annotations: { readOnlyHint: true, openWorldHint: false },
  handler: async ({ limit }, ctx) => {
    const sb = supabaseForUser(ctx);
    const { data, error } = await sb
      .from("user_memory")
      .select("id,kind,content,created_at")
      .eq("user_id", ctx.getUserId()!)
      .order("created_at", { ascending: false })
      .limit(limit ?? 50);
    if (error) return { content: [{ type: "text", text: error.message }], isError: true };
    const rows = (data ?? []).map((m: any) => ({ id: String(m.id), kind: String(m.kind), content: String(m.content), created_at: String(m.created_at) }));
    return { content: [{ type: "text", text: JSON.stringify(rows) }], structuredContent: { memory: rows } };
  },
});

export const addMemory = defineTool({
  name: "add_memory",
  title: "Guardar recuerdo",
  description: "Guarda un dato nuevo en la memoria de Orión sobre el usuario.",
  inputSchema: { content: z.string().trim().min(1).max(4000).describe("Lo que Orión debe recordar.") },
  annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  handler: async ({ content }, ctx) => {
    const uid = ctx.getUserId()!;
    const sb = supabaseForUser(ctx);
    const { error } = await sb.from("user_memory").insert({ user_id: uid, device_id: uid, content, kind: "fact" });
    if (error) return { content: [{ type: "text", text: error.message }], isError: true };
    return { content: [{ type: "text", text: "Recuerdo guardado." }] };
  },
});
