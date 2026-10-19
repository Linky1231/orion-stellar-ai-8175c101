import "./ws-shim";
import "../src/styles.css";
import { installBuildaStorage } from "./storage";

document.documentElement.classList.remove("dark");
if (!(crypto as any).randomUUID) (crypto as any).randomUUID = () => "10000000-1000-4000-5000-100000000000".replace(/[018]/g, (c: any) => (c ^ (crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (c / 4)))).toString(16));
import { createRoot } from "react-dom/client";
import { ChatApp } from "@/components/orion/ChatApp";

import { localChatResponse, preloadLocalAi } from "./local-ai";

// Builda blocks external servers: chat runs on the local model; other calls still try the published app.
const API_ORIGIN = "https://orion-stellar-ai.lovable.app";
const nativeFetch = window.fetch.bind(window);
window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
  if (input === "/api/ai/chat") {
    let body: any = {};
    try { body = JSON.parse(String(init?.body ?? "{}")); } catch {}
    return localChatResponse(body, init?.signal);
  }
  if (typeof input === "string" && input.startsWith("/api/")) input = API_ORIGIN + input;
  return nativeFetch(input, init);
};
preloadLocalAi();
installBuildaStorage();

// Open the local chat immediately, without account lookup or login.
const root = document.getElementById("root");
if (root) createRoot(root).render(<ChatApp />);
