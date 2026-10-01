import { defineTool, ToolError } from "@lovable.dev/mcp-js";
import { z } from "zod";
import { supabaseForUser } from "../supabase";

export default defineTool({
  name: "get_messages",
  title: "Leer chat",
  description: "Devuelve los mensajes de un chat del usuario.",
  inputSchema: { conversation_id: z.string().uuid().describe("ID del chat.") },
  annotations: { readOnlyHint: true, openWorldHint: false },
  handler: async ({ conversation_id }, ctx) => {
    const sb = supabaseForUser(ctx);
    const { data: conv } = await sb
      .from("conversations")
      .select("id")
      .eq("id", conversation_id)
      .eq("user_id", ctx.getUserId()!)
      .maybeSingle();
    if (!conv) throw new ToolError("Chat no encontrado.");
    const { data, error } = await sb
      .from("messages")
      .select("role,content,created_at")
      .eq("conversation_id", conversation_id)
      .order("created_at", { ascending: true })
      .limit(200);
    if (error) return { content: [{ type: "text", text: error.message }], isError: true };
    const rows = (data ?? []).map((m: any) => ({ role: String(m.role), content: String(m.content ?? ""), created_at: String(m.created_at) }));
    return { content: [{ type: "text", text: JSON.stringify(rows) }], structuredContent: { messages: rows } };
  },
});
