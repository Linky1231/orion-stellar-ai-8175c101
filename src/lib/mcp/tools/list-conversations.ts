import { defineTool } from "@lovable.dev/mcp-js";
import { z } from "zod";
import { supabaseForUser } from "../supabase";

export default defineTool({
  name: "list_conversations",
  title: "Listar chats",
  description: "Lista los chats recientes del usuario con Orión.",
  inputSchema: { limit: z.number().int().min(1).max(50).optional().describe("Máximo de chats (por defecto 20).") },
  annotations: { readOnlyHint: true, openWorldHint: false },
  handler: async ({ limit }, ctx) => {
    const sb = supabaseForUser(ctx);
    const { data, error } = await sb
      .from("conversations")
      .select("id,title,updated_at")
      .eq("user_id", ctx.getUserId()!)
      .order("updated_at", { ascending: false })
      .limit(limit ?? 20);
    if (error) return { content: [{ type: "text", text: error.message }], isError: true };
    const rows = (data ?? []).map((r: any) => ({ id: String(r.id), title: String(r.title ?? ""), updated_at: String(r.updated_at) }));
    return { content: [{ type: "text", text: JSON.stringify(rows) }], structuredContent: { conversations: rows } };
  },
});
