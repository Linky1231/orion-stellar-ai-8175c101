import { useEffect, useRef, useState, createContext, useContext, useCallback } from "react";
import ReactMarkdown from "react-markdown";
import { supabase } from "@/integrations/supabase/client";
import { getDeviceId } from "@/lib/device";
import { sfx } from "@/lib/sounds";
import { streamChat, streamSearch, generateImage, uploadAttachment, extractAndStoreMemory, type ChatMsg } from "@/lib/orion-api";

import { OrionLogo } from "./OrionLogo";
import { Sidebar } from "./Sidebar";
import { NotesPanel } from "./NotesPanel";
import { DebugPanel } from "./DebugPanel";

import { AdminPanel } from "./AdminPanel";

import { Menu, Send, Paperclip, ImagePlus, Search, User, Copy, Volume2, Square, X, AlertTriangle, Sparkles } from "lucide-react";

const SpeechCtx = createContext<{ speakingId: string | null; toggle: (id: string, text: string) => void }>({ speakingId: null, toggle: () => {} });

type DBMsg = {
  id: string; conversation_id: string; role: "user" | "assistant" | "system";
  content: string; attachments: any[]; created_at: string;
};

const ADMIN_TOKEN = "Admin7880";

export function ChatApp() {
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [notesOpen, setNotesOpen] = useState(false);
  const [debugOpen, setDebugOpen] = useState(false);
  
  const [adminOpen, setAdminOpen] = useState(false);
  
  const [convId, setConvId] = useState<string | null>(null);
  const [messages, setMessages] = useState<DBMsg[]>([]);
  const [input, setInput] = useState("");
  const [streaming, setStreaming] = useState(false);
  const [pending, setPending] = useState<{ url: string; type: string; name: string }[]>([]);
  const [imageMode, setImageMode] = useState(false);
  const [searchMode, setSearchMode] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);


  useEffect(() => { scrollRef.current?.scrollTo({ top: 1e9, behavior: "smooth" }); }, [messages, streaming]);





  async function loadMessages(id: string) {
    const { data } = await supabase
      .from("messages").select("*").eq("conversation_id", id).order("created_at");
    setMessages((data as DBMsg[]) || []);
  }

  useEffect(() => { if (convId) loadMessages(convId); else setMessages([]); }, [convId]);

  useEffect(() => {
    if (!convId) return;
    const ch = supabase
      .channel(`msg-${convId}`)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "messages", filter: `conversation_id=eq.${convId}` },
        (p) => setMessages((m) => (m.some(x => x.id === (p.new as any).id) ? m : [...m, p.new as DBMsg])))
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, [convId]);

  async function ensureConv(firstText: string): Promise<string> {
    if (convId) return convId;
    const did = getDeviceId();
    const title = firstText.slice(0, 50) || "Nueva conversación";
    const { data } = await supabase
      .from("conversations").insert({ device_id: did, title }).select().single();
    setConvId((data as any).id);
    return (data as any).id;
  }

  async function send() {
    if (streaming) return;
    const text = input.trim();
    if (!text && pending.length === 0) return;

    // Orión decide sola: si el usuario pide una imagen o una búsqueda, activa esa función.
    const wantsImage = !pending.length && detectImageRequest(text);
    const wantsSearch = !wantsImage && detectSearchRequest(text);
    if (wantsImage) setImageMode(true);
    if (wantsSearch) setSearchMode(true);
    const useImage = imageMode || wantsImage;
    const useSearch = !useImage && (searchMode || wantsSearch);

    // Admin trigger
    if (text === ADMIN_TOKEN) {
      sfx.open();
      setAdminOpen(true);
      setInput("");
      return;
    }

    sfx.send();
    setInput("");
    const atts = pending; setPending([]);

    const id = await ensureConv(text);

    // Save user message
    const userMsg = { conversation_id: id, role: "user" as const, content: text, attachments: atts };
    const { data: saved } = await supabase.from("messages").insert(userMsg).select().single();
    if (saved) setMessages((m) => (m.some(x => x.id === (saved as any).id) ? m : [...m, saved as DBMsg]));

    // Image generation mode
    if (useImage) {
      setStreaming(true);
      const tempId = "img-" + Date.now();
      setMessages((m) => [...m, { id: tempId, conversation_id: id, role: "assistant", content: "Preparando imagen…", attachments: [], created_at: new Date().toISOString() }]);
      try {
        const raw = await generateImage(cleanImagePrompt(text));
        let url = raw;
        if (raw.startsWith("data:")) {
          const blob = await (await fetch(raw)).blob();
          url = await uploadAttachment(new File([blob], `orion-${Date.now()}.png`, { type: blob.type || "image/png" }));
        }

        const { data: a } = await supabase.from("messages").insert({
          conversation_id: id, role: "assistant",
          content: `Aquí tienes tu imagen`,
          attachments: [{ url, type: "image/png", name: "generated.png" }],
        }).select().single();
        if (a) setMessages((m) => m.map(x => x.id === tempId ? (a as DBMsg) : x));
        sfx.receive();
      } catch (e: any) {
        sfx.error();
        setMessages((m) => m.map(x => x.id === tempId ? { ...x, content: "Error generando imagen: " + e.message } : x));
      }
      setStreaming(false);
      setImageMode(false);
      await supabase.from("conversations").update({ updated_at: new Date().toISOString() }).eq("id", id);
      return;
    }

    // Build chat history for AI (with multimodal content)
    const history: ChatMsg[] = messages.concat(saved ? [saved as DBMsg] : []).map((m) => {
      const imgs = (m.attachments || []).filter((a: any) => a.type?.startsWith("image"));
      const vids = (m.attachments || []).filter((a: any) => a.type?.startsWith("video"));
      if (m.role === "user" && (imgs.length || vids.length)) {
        return {
          role: "user",
          content: [
            {
              type: "text",
              text:
                (useSearch ? "[Buscar info actualizada en internet] " : "") +
                (m.content || "Analiza el contenido adjunto y descríbelo con detalle."),
            },
            ...imgs.map((a: any) => ({ type: "image_url", image_url: { url: a.url } })),
            ...vids.map((a: any) => ({ type: "video_url", video_url: { url: a.url } })),
          ] as any,
        };
      }
      return { role: m.role as any, content: m.content };
    });


    // Stream assistant
    setStreaming(true);
    let acc = "";
    const tempId = "tmp-" + Date.now();
    setMessages((m) => [...m, { id: tempId, conversation_id: id, role: "assistant", content: "", attachments: [], created_at: new Date().toISOString() }]);

    try {
      const onDelta = (delta: string) => {
        acc += delta;
        setMessages((m) => m.map(x => x.id === tempId ? { ...x, content: acc } : x));
      };
      const runner = useSearch ? streamSearch(text, history, onDelta) : streamChat(history, onDelta);
      await runner;
      const { data: a } = await supabase.from("messages")
        .insert({ conversation_id: id, role: "assistant", content: acc })
        .select().single();
      setMessages((m) => m.map(x => x.id === tempId ? (a as DBMsg) : x));
      sfx.receive();
      await supabase.from("conversations").update({ updated_at: new Date().toISOString() }).eq("id", id);
      window.setTimeout(() => extractAndStoreMemory(text), 2500);
    } catch (e: any) {
      sfx.error();
      setMessages((m) => m.map(x => x.id === tempId ? { ...x, content: "Error: " + e.message } : x));
    }
    setStreaming(false);
    setSearchMode(false);
  }

  async function onFile(f: File) {
    sfx.tap();
    if (f.size > 25 * 1024 * 1024) { sfx.error(); alert("El archivo es muy grande (máx. 25 MB)."); return; }
    try {
      const url = await uploadAttachment(f);
      setPending((p) => [...p, { url, type: f.type, name: f.name }]);
    } catch (e: any) { sfx.error(); alert(e.message); }
  }


  function newConv() { setConvId(null); setMessages([]); setSidebarOpen(false); }

  const [speakingId, setSpeakingId] = useState<string | null>(null);
  const toggleSpeak = useCallback((id: string, text: string) => {
    sfx.tap();
    if (speakingId === id) {
      window.speechSynthesis.cancel();
      setSpeakingId(null);
      return;
    }
    window.speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(text);
    u.lang = "es-ES";
    u.onend = () => setSpeakingId((cur) => (cur === id ? null : cur));
    u.onerror = () => setSpeakingId((cur) => (cur === id ? null : cur));
    window.speechSynthesis.speak(u);
    setSpeakingId(id);
  }, [speakingId]);

  useEffect(() => () => window.speechSynthesis.cancel(), []);

  return (
    <SpeechCtx.Provider value={{ speakingId, toggle: toggleSpeak }}>
    <div className="flex h-screen w-full overflow-hidden">
      <Sidebar
        open={sidebarOpen}
        onClose={() => setSidebarOpen(false)}
        currentId={convId}
        onSelect={setConvId}
        onNew={newConv}
        onOpenNotes={() => setNotesOpen(true)}
        onOpenDebug={() => setDebugOpen(true)}
        
        onCreateImage={() => { newConv(); setImageMode(true); }}
      />

      <main className="flex-1 flex flex-col min-w-0">
        {/* Header */}
        <header className="liquid-glass border-b border-border px-4 py-3 flex items-center gap-3 rounded-none">
          <button className="tap btn-glass p-2 rounded-xl md:hidden" onClick={() => { sfx.tap(); setSidebarOpen(true); }}>
            <Menu className="w-5 h-5" />
          </button>
          <button className="tap btn-glass hidden md:flex p-2 rounded-xl" onClick={() => { sfx.tap(); setSidebarOpen((v) => !v); }}>
            <Menu className="w-5 h-5" />
          </button>
          <OrionLogo size={36} glow={streaming} />
          <div className="flex-1 min-w-0">
            <div className="font-semibold tracking-tight leading-tight">Orión Estellar</div>
            <div className="text-[11px] text-muted-foreground">v5.0 · por Linky</div>
          </div>
        </header>





        {/* Messages */}
        <div ref={scrollRef} className="flex-1 overflow-y-auto px-4 py-6">
          <div className="max-w-3xl mx-auto space-y-5">
            {messages.length === 0 && <Welcome imageMode={imageMode} />}
            {messages.map((m) => <Bubble key={m.id} m={m} />)}
            {streaming && (() => {
              const last = messages[messages.length - 1];
              return !last || last.role !== "assistant" || !last.content?.trim();
            })() && <ThinkingIndicator />}
          </div>
        </div>

        {/* Composer */}
        <div className="px-4 pb-4 pt-2">
          <div className="max-w-3xl mx-auto">
            {pending.length > 0 && (
              <div className="flex gap-2 mb-2 flex-wrap">
                {pending.map((p, i) => (
                  <div key={i} className="relative bg-card border border-border rounded-xl p-1.5 pr-7 text-xs flex items-center gap-2">
                    {p.type.startsWith("image") ? <img src={p.url} className="w-8 h-8 rounded object-cover" /> : p.type.startsWith("video") ? <video src={p.url} className="w-8 h-8 rounded object-cover" muted /> : <Paperclip className="w-4 h-4" />}
                    <span className="max-w-[120px] truncate">{p.name}</span>
                    <button className="absolute right-1 top-1 p-0.5 hover:bg-accent rounded" onClick={() => setPending(pending.filter((_, j) => j !== i))}>
                      <X className="w-3 h-3" />
                    </button>
                  </div>
                ))}
              </div>
            )}
            {imageMode && (
              <div className="mb-2 flex gap-2 flex-wrap">
                <Tag onClose={() => setImageMode(false)}><Sparkles className="w-3 h-3" /> Modo imagen</Tag>
              </div>
            )}
            <div className="liquid-glass rounded-2xl p-2 flex items-end gap-1">
              <textarea
                value={input}
                onChange={(e) => setInput(e.target.value)}
                onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } }}
                placeholder={imageMode ? "Describe la imagen…" : "Escribe un mensaje…"}
                rows={1}
                className="flex-1 bg-transparent outline-none resize-none px-3 py-2 text-sm max-h-40 placeholder:text-muted-foreground"
              />
              <button onClick={() => { sfx.tap(); fileRef.current?.click(); }} className="tap btn-glass p-2 rounded-xl" title="Adjuntar imagen o video">
                <Paperclip className="w-4 h-4" />
              </button>
              <input
                ref={fileRef}
                type="file"
                accept="image/*,video/*"
                multiple
                className="hidden"
                onChange={(e) => {
                  const files = Array.from(e.target.files || []);
                  files.forEach((f) => onFile(f));
                  e.target.value = "";
                }}
              />
              <button onClick={send} disabled={streaming} className="tap btn-cosmic p-2 rounded-xl disabled:opacity-50" title="Enviar">
                <Send className="w-4 h-4" />
              </button>
            </div>
            <div className="text-[10px] text-center text-muted-foreground mt-2">Orión Estellar puede cometer errores. Verifica info importante.</div>
          </div>
        </div>
      </main>

      <NotesPanel open={notesOpen} onClose={() => setNotesOpen(false)} />
      <DebugPanel open={debugOpen} onClose={() => setDebugOpen(false)} />
      
      <AdminPanel open={adminOpen} onClose={() => setAdminOpen(false)} />
      
    </div>
    </SpeechCtx.Provider>
  );
}

function Tag({ children, onClose }: { children: any; onClose: () => void; color?: string }) {
  return (
    <span className="inline-flex items-center gap-1 text-xs px-2.5 py-1 rounded-full gradient-orion text-primary-foreground">
      {children}
      <button onClick={onClose}><X className="w-3 h-3" /></button>
    </span>
  );
}

function Welcome({ imageMode }: { imageMode: boolean }) {
  return (
    <div className="flex flex-col items-center text-center pt-12 pb-8 animate-fade-up">
      <OrionLogo size={84} glow />
      <h1 className="text-3xl md:text-4xl font-semibold tracking-tight mt-5">
        <span className="text-gradient-orion">Orión Estellar</span>
      </h1>
      <p className="text-sm text-muted-foreground mt-2 max-w-md">
        {imageMode ? "Describe la imagen que quieres crear y la generaré con precisión." : "La asistente esencial para creadores indie. Programación, arte, diseño de niveles y mucho más."}
      </p>
    </div>
  );
}

function Bubble({ m }: { m: DBMsg }) {
  const isUser = m.role === "user";
  const hasAttachments = (m.attachments || []).length > 0;
  if (!isUser && !m.content?.trim() && !hasAttachments) return null;
  return (
    <div className={`flex gap-3 animate-fade-up ${isUser ? "flex-row-reverse" : ""}`}>
      <div className="shrink-0">
        {isUser ? (
          <div className="w-8 h-8 rounded-full gradient-orion flex items-center justify-center text-primary-foreground">
            <User className="w-4 h-4" />
          </div>
        ) : (
          <OrionLogo size={32} />
        )}
      </div>
      <div className={`max-w-[85%] ${isUser ? "items-end" : "items-start"} flex flex-col gap-1.5`}>
        {(m.attachments || []).map((a: any, i) => (
          a.type?.startsWith("image") ? (
            <GeneratedImage key={i} src={a.url} />
          ) : a.type?.startsWith("video") ? (
            <video key={i} src={a.url} controls playsInline className="rounded-2xl max-h-80 border border-border shadow-soft" />
          ) : (
            <a key={i} href={a.url} target="_blank" className="text-xs underline">{a.name}</a>
          )

        ))}
        {m.content && (
          <div className={`px-4 py-2.5 rounded-2xl text-sm leading-relaxed
            ${isUser ? "btn-cosmic !rounded-2xl rounded-br-sm" : "liquid-glass rounded-bl-sm"}`}>
            {isUser ? (
              <div className="whitespace-pre-wrap relative z-10">{m.content}</div>
            ) : (
              <div className="prose prose-sm max-w-none dark:prose-invert prose-p:my-1.5 prose-pre:bg-muted prose-pre:text-foreground relative z-10">
                <ReactMarkdown>{m.content}</ReactMarkdown>
              </div>
            )}
          </div>
        )}
        {!isUser && m.content && (
          <div className="flex gap-1 opacity-50 hover:opacity-100 transition">
            <button onClick={() => { navigator.clipboard.writeText(m.content); sfx.tap(); }} className="tap p-1 rounded hover:bg-accent">
              <Copy className="w-3 h-3" />
            </button>
            <SpeakBtn id={m.id} text={m.content} />

          </div>
        )}
      </div>
    </div>
  );
}

function GeneratedImage({ src }: { src: string }) {
  const [url, setUrl] = useState(src);
  const [tries, setTries] = useState(0);
  const [failed, setFailed] = useState(false);

  function retry() {
    if (tries >= 2) {
      setFailed(true);
      return;
    }
    if (src.includes("image.pollinations.ai")) {
      window.setTimeout(() => setUrl(`${src}#retry-${Date.now()}`), 7000);
      setTries((n) => n + 1);
      return;
    }
    try {
      const next = new URL(src);
      next.searchParams.set("seed", String(Date.now()));
      setUrl(next.toString());
    } catch {
      setUrl(`${src}${src.includes("?") ? "&" : "?"}retry=${Date.now()}`);
    }
    setTries((n) => n + 1);
  }

  if (failed) {
    return <div className="liquid-glass rounded-2xl border border-border px-4 py-3 text-sm text-muted-foreground">El proveedor público está saturado ahora mismo. Espera unos segundos y vuelve a generar la imagen.</div>;
  }

  return <img src={url} alt="Imagen generada" onError={retry} className="rounded-2xl max-h-80 border border-border shadow-soft" />;
}

function SpeakBtn({ id, text }: { id: string; text: string }) {
  const { speakingId, toggle } = useContext(SpeechCtx);
  const active = speakingId === id;
  return (
    <button onClick={() => toggle(id, text)} className={`tap p-1 rounded hover:bg-accent ${active ? "text-primary" : ""}`} title={active ? "Detener" : "Leer"}>
      {active ? <Square className="w-3 h-3" /> : <Volume2 className="w-3 h-3" />}
    </button>
  );
}

function ThinkingIndicator() {
  return (
    <div className="flex items-center gap-3 animate-fade-in">
      <div className="relative">
        <OrionLogo size={28} glow />
        <span className="absolute inset-0 rounded-full bg-primary/30 blur-md animate-pulse" />
      </div>
      <div className="liquid-glass rounded-2xl rounded-bl-sm px-4 py-3 flex items-center gap-2 relative overflow-hidden">
        <span className="absolute inset-0 bg-gradient-to-r from-transparent via-primary/10 to-transparent -translate-x-full animate-[shimmer_1.8s_ease-in-out_infinite]" />
        <span className="relative w-2 h-2 rounded-full bg-primary animate-bounce" style={{ animationDelay: "0ms", animationDuration: "1s" }} />
        <span className="relative w-2 h-2 rounded-full bg-primary/80 animate-bounce" style={{ animationDelay: "150ms", animationDuration: "1s" }} />
        <span className="relative w-2 h-2 rounded-full bg-primary/60 animate-bounce" style={{ animationDelay: "300ms", animationDuration: "1s" }} />
        <span className="relative text-xs text-muted-foreground ml-1.5">Orión está pensando…</span>
      </div>
    </div>
  );
}

