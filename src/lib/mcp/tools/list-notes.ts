import { defineTool } from "@lovable.dev/mcp-js";
import { z } from "zod";
import { supabaseForUser } from "../supabase";

export default defineTool({
  name: "list_notes",
  title: "Listar notas",
  description: "Lista las notas del usuario en el Modo Notas.",
  inputSchema: { limit: z.number().int().min(1).max(100).optional().describe("Máximo de notas (por defecto 30).") },
  annotations: { readOnlyHint: true, openWorldHint: false },
  handler: async ({ limit }, ctx) => {
    const sb = supabaseForUser(ctx);
    const { data, error } = await sb
      .from("notes")
      .select("id,title,content,category,status,updated_at")
      .eq("user_id", ctx.getUserId()!)
      .order("updated_at", { ascending: false })
      .limit(limit ?? 30);
    if (error) return { content: [{ type: "text", text: error.message }], isError: true };
    const rows = (data ?? []).map((n: any) => ({
      id: String(n.id), title: String(n.title ?? ""), content: String(n.content ?? ""),
      category: n.category ? String(n.category) : null, status: String(n.status ?? ""), updated_at: String(n.updated_at),
    }));
    return { content: [{ type: "text", text: JSON.stringify(rows) }], structuredContent: { notes: rows } };
  },
});
