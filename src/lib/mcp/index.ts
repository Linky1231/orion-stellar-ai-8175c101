import { auth, defineMcp } from "@lovable.dev/mcp-js";
import listConversations from "./tools/list-conversations";
import getMessages from "./tools/get-messages";
import listNotes from "./tools/list-notes";
import { listMemory, addMemory } from "./tools/memory";

const projectRef = import.meta.env["VITE_SUPABASE_PROJECT_ID"] ?? "project-ref-unset";

export default defineMcp({
  name: "orion-estellar-ai",
  title: "Orión Estellar AI",
  version: "0.1.0",
  instructions:
    "Herramientas de Orión Estellar para el usuario conectado: leer sus chats y notas, ver y añadir recuerdos a la memoria de Orión.",
  auth: auth.oauth.issuer({
    issuer: `https://${projectRef}.supabase.co/auth/v1`,
    acceptedAudiences: "authenticated",
  }),
  tools: [listConversations, getMessages, listNotes, listMemory, addMemory],
});
