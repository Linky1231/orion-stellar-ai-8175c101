import { useState } from "react";
import { Plug, Copy, Check, X } from "lucide-react";
import { sfx } from "@/lib/sounds";

export const MCP_URL = "https://orion-stellar-ai.lovable.app/mcp";

export function McpLinkButton() {
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(MCP_URL);
    } catch {
      const t = document.createElement("textarea");
      t.value = MCP_URL;
      document.body.appendChild(t);
      t.select();
      document.execCommand("copy");
      t.remove();
    }
    sfx.tap();
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <>
      <button
        onClick={() => { sfx.open(); setOpen(true); }}
        className="w-full tap btn-glass flex items-center gap-2 px-3 py-2.5 rounded-xl text-sm"
      >
        <Plug className="w-4 h-4 text-primary" /> Conectar agentes (MCP)
      </button>
      {open && (
        <div
          className="fixed inset-0 z-[60] flex items-center justify-center p-4 bg-foreground/30 backdrop-blur-sm"
          onClick={() => setOpen(false)}
        >
          <div
            className="liquid-glass w-full max-w-md rounded-2xl p-5 space-y-4"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2 font-semibold">
                <Plug className="w-4 h-4 text-primary" /> Enlace MCP de Orión
              </div>
              <button className="tap p-1.5 rounded-lg hover:bg-accent" onClick={() => setOpen(false)}>
                <X className="w-4 h-4" />
              </button>
            </div>
            <p className="text-sm text-muted-foreground">
              Pega este enlace en ChatGPT, Claude, Cursor u otro agente compatible con MCP. Te pedirá entrar con Google y aprobar la conexión.
            </p>
            <div className="flex items-center gap-2 rounded-xl bg-muted p-2">
              <code className="flex-1 text-xs break-all select-all px-1">{MCP_URL}</code>
              <button
                onClick={copy}
                className="tap btn-cosmic flex items-center gap-1 px-3 py-2 rounded-lg text-xs font-medium shrink-0"
              >
                {copied ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
                {copied ? "Copiado" : "Copiar"}
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
