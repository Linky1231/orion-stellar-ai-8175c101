import "../src/styles.css";
import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { Loader2 } from "lucide-react";
import { ChatApp } from "@/components/orion/ChatApp";
import { AuthProvider } from "@/lib/auth";
import { setAccountScope, getLocalDeviceId } from "@/lib/device";

// The Builda build is static: send Orión's server calls to the published app.
const API_ORIGIN = "https://orion-stellar-ai.lovable.app";
const nativeFetch = window.fetch.bind(window);
window.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
  if (typeof input === "string" && input.startsWith("/api/")) input = API_ORIGIN + input;
  return nativeFetch(input, init);
};

// No login inside Builda: the player's Builda account identifies their chats and notes.
function BuildaGate() {
  const [scope, setScope] = useState<string | null>(null);
  useEffect(() => {
    let done = false;
    const finish = (id: string) => {
      if (done) return;
      done = true;
      setAccountScope(id);
      setScope(id);
    };
    const fallback = setTimeout(() => finish(getLocalDeviceId()), 8000);
    const b = (window as any).Builda;
    Promise.resolve(b?.whoami?.({ timeoutMs: 7000 }))
      .then((r: any) => {
        const id = r?.ok && r.data?.id ? `builda-${r.data.id}` : getLocalDeviceId();
        if (r?.ok && r.data?.name) localStorage.setItem("orion_builda_name", r.data.name);
        finish(id);
      })
      .catch(() => finish(getLocalDeviceId()))
      .finally(() => clearTimeout(fallback));
  }, []);
  if (!scope)
    return (
      <div className="min-h-screen flex items-center justify-center">
        <Loader2 className="w-6 h-6 animate-spin text-primary" />
      </div>
    );
  return <ChatApp key={scope} />;
}

createRoot(document.getElementById("root")!).render(
  <AuthProvider>
    <BuildaGate />
  </AuthProvider>,
);
