import "../src/styles.css";

document.documentElement.classList.remove("dark");
try { localStorage.setItem("theme", "light"); } catch {}
if (!(crypto as any).randomUUID) (crypto as any).randomUUID = () => "10000000-1000-4000-5000-100000000000".replace(/[018]/g, (c: any) => (c ^ (crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (c / 4)))).toString(16));
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
    const fallback = setTimeout(() => finish(getLocalDeviceId()), 5000);
    const b = (window as any).Builda;
    Promise.resolve(b?.whoami?.({ timeoutMs: 4000 }))
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
        <span className="text-sm text-muted-foreground flex items-center gap-2"><Loader2 className="w-5 h-5 animate-spin" /> Conectando con Builda…</span>
      </div>
    );
  return <ChatApp key={scope} />;
}

createRoot(document.getElementById("root")!).render(
  <AuthProvider>
    <BuildaGate />
  </AuthProvider>,
);
