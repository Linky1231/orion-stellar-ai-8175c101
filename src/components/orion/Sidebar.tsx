import { useEffect, useState } from "react";
import { localData as supabase } from "@/lib/local-data";
import { getDeviceId } from "@/lib/device";
import { sfx } from "@/lib/sounds";
import { Search, Plus, Trash2, Pencil, MessageSquare, StickyNote, X, ImagePlus, Bug } from "lucide-react";
import { OrionLogo } from "./OrionLogo";

type Conv = { id: string; title: string; updated_at: string };

export function Sidebar({
  open,
  onClose,
  currentId,
  onSelect,
  onNew,
  onOpenNotes,
  onOpenDebug,
  
  onCreateImage,
}: {
  open: boolean;
  onClose: () => void;
  currentId: string | null;
  onSelect: (id: string) => void;
  onNew: () => void;
  onOpenNotes: () => void;
  onOpenDebug: () => void;
  
  onCreateImage: () => void;
}) {
  const [convs, setConvs] = useState<Conv[]>([]);
  const [q, setQ] = useState("");
  const [editing, setEditing] = useState<string | null>(null);
  const [editTitle, setEditTitle] = useState("");

  async function load() {
    const did = getDeviceId();
    const { data } = await supabase
      .from("conversations")
      .select("id,title,updated_at")
      .eq("device_id", did)
      .order("updated_at", { ascending: false });
    setConvs((data as Conv[]) || []);
  }

  useEffect(() => { if (open) load(); }, [open, currentId]);

  useEffect(() => {
    let ch: ReturnType<typeof supabase.channel> | null = null;
    try {
      ch = supabase
        .channel("conv-list")
        .on("postgres_changes", { event: "*", schema: "public", table: "conversations" }, load)
        .subscribe();
    } catch { /* live updates unavailable (e.g. inside Builda) */ }
    return () => { if (ch) void supabase.removeChannel(ch); };
  }, []);

  const filtered = convs.filter((c) => c.title.toLowerCase().includes(q.toLowerCase()));

  async function rename(id: string) {
    await supabase.from("conversations").update({ title: editTitle || "Sin título" }).eq("id", id);
    setEditing(null);
    load();
  }

  async function remove(id: string) {
    sfx.tap();
    if (!confirm("¿Eliminar esta conversación?")) return;
    await supabase.from("messages" as any).delete().eq("conversation_id", id);
    await supabase.from("conversations").delete().eq("id", id);
    if (id === currentId) onNew();
    load();
  }

  async function removeAll() {
    sfx.tap();
    if (!convs.length) return;
    if (!confirm("¿Eliminar todas las conversaciones? Esta acción no se puede deshacer.")) return;
    const did = getDeviceId();
    const ids = convs.map((c) => c.id);
    await supabase.from("messages" as any).delete().in("conversation_id", ids);
    await supabase.from("conversations").delete().eq("device_id", did);
    onNew();
    load();
  }

  return (
    <>
      {open && (
        <div
          className="fixed inset-0 bg-foreground/20 backdrop-blur-sm z-40 md:hidden animate-fade-up"
          onClick={onClose}
        />
      )}
      <aside
        className={`fixed md:sticky top-0 left-0 h-dvh max-h-dvh w-[min(300px,100vw)] shrink-0 z-50 liquid-glass rounded-none border-r border-border flex flex-col min-h-0
          transition-transform duration-300 ease-out
          ${open ? "translate-x-0" : "-translate-x-full md:translate-x-0"}`}
      >
        <div className="flex shrink-0 items-center justify-between px-4 py-4 border-b border-border">
          <div className="flex items-center gap-2">
            <OrionLogo size={28} />
            <div>
              <div className="text-sm font-semibold tracking-tight">Conversaciones</div>
              <div className="text-[11px] text-muted-foreground">Orión Estellar v5.0</div>
            </div>
          </div>
          <button className="md:hidden tap p-1.5 rounded-lg hover:bg-accent" onClick={() => { sfx.tap(); onClose(); }}>
            <X className="w-4 h-4" />
          </button>
        </div>

        <div className="shrink-0 p-3 space-y-2">
          <button
            onClick={() => { sfx.tap(); onNew(); }}
            className="w-full tap btn-cosmic flex items-center gap-2 px-3 py-2.5 rounded-xl text-sm font-medium"
          >
            <Plus className="w-4 h-4" /> Nueva conversación
          </button>
          <button
            onClick={() => { sfx.tap(); onCreateImage(); }}
            className="w-full tap btn-glass flex items-center gap-2 px-3 py-2.5 rounded-xl text-sm"
          >
            <ImagePlus className="w-4 h-4 text-primary" /> Crear imagen con IA
          </button>
          <button
            onClick={() => { sfx.open(); onOpenNotes(); }}
            className="w-full tap btn-glass flex items-center gap-2 px-3 py-2.5 rounded-xl text-sm"
          >
            <StickyNote className="w-4 h-4 text-primary" /> Modo Notas
          </button>
          <button
            onClick={() => { sfx.open(); onOpenDebug(); }}
            className="w-full tap btn-glass flex items-center gap-2 px-3 py-2.5 rounded-xl text-sm"
          >
            <Bug className="w-4 h-4 text-primary" /> Modo Debug
          </button>
        </div>



        <div className="shrink-0 px-3 pb-2">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-muted-foreground" />
            <input
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="Buscar"
              className="w-full pl-9 pr-3 py-2 text-sm rounded-xl bg-muted border border-transparent focus:border-ring focus:bg-card outline-none transition"
            />
          </div>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-2 pb-3">
          <div className="px-2 py-1 flex items-center justify-between">
            <span className="text-[10px] uppercase tracking-wider text-muted-foreground">Recientes</span>
            {convs.length > 0 && (
              <button
                onClick={removeAll}
                className="tap text-[10px] flex items-center gap-1 px-2 py-1 rounded-lg text-destructive hover:bg-destructive/10 transition"
              >
                <Trash2 className="w-3 h-3" /> Eliminar todo
              </button>
            )}
          </div>
          {filtered.length === 0 && (
            <div className="px-3 py-6 text-center text-xs text-muted-foreground">Sin conversaciones</div>
          )}
          {filtered.map((c) => (
            <div
              key={c.id}
              onClick={() => { sfx.tap(); onSelect(c.id); onClose(); }}
              className={`group cursor-pointer px-3 py-2 rounded-xl mb-1 flex items-center gap-2 transition
                ${currentId === c.id ? "bg-accent" : "hover:bg-accent/60"}`}
            >
              <MessageSquare className="w-4 h-4 text-muted-foreground shrink-0" />
              {editing === c.id ? (
                <input
                  autoFocus
                  value={editTitle}
                  onChange={(e) => setEditTitle(e.target.value)}
                  onBlur={() => rename(c.id)}
                  onKeyDown={(e) => e.key === "Enter" && rename(c.id)}
                  className="flex-1 bg-card text-sm rounded px-2 py-0.5 border border-border outline-none"
                />
              ) : (
                <div className="flex-1 min-w-0">
                  <div className="text-sm truncate">{c.title}</div>
                  <div className="text-[10px] text-muted-foreground">
                    {new Date(c.updated_at).toLocaleString()}
                  </div>
                </div>
              )}
              <div className="opacity-0 group-hover:opacity-100 flex gap-1 transition">
                <button
                  className="p-1 rounded hover:bg-card"
                  onClick={(e) => { e.stopPropagation(); setEditing(c.id); setEditTitle(c.title); }}
                >
                  <Pencil className="w-3.5 h-3.5" />
                </button>
                <button
                  className="p-1 rounded hover:bg-destructive/10 text-destructive"
                  onClick={(e) => { e.stopPropagation(); remove(c.id); }}
                >
                  <Trash2 className="w-3.5 h-3.5" />
                </button>
              </div>
            </div>
          ))}
        </div>
      </aside>
    </>
  );
}

