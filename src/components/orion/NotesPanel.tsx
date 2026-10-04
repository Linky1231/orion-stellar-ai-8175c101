import { useEffect, useMemo, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { getDeviceId } from "@/lib/device";
import { sfx } from "@/lib/sounds";
import { classifyNote, analyzeProject } from "@/lib/orion-api";
import { OrionLogo } from "./OrionLogo";
import {
  X, Plus, Trash2, Save, Folder, FolderPlus, Sparkles, Brain,
  ArrowLeft, Wand2, Loader2, NotebookPen, Wrench,
  Gamepad2, BookOpen, LayoutDashboard, Network, Wallet,
  Volume2, Bug, Palette, Code, Pin, FolderInput, CheckSquare, Square,
} from "lucide-react";

type Note = {
  id: string;
  title: string;
  content: string;
  updated_at: string;
  last_activity: string;
  folder_id: string | null;
  section: string;
  category: string | null;
  status: string;
  ai_summary: string | null;
};

type FolderRow = {
  id: string;
  name: string;
  section: string;
  status: string;
  color: string;
};

const SECTIONS = [
  { id: "main", label: "Notas", Icon: NotebookPen },
  { id: "dev", label: "Desarrollo", Icon: Wrench },
] as const;

const STATUS = {
  stable:      { label: "Estable",       color: "text-green-400",  dotClass: "bg-green-500",  bg: "bg-green-500/10" },
  development: { label: "En desarrollo", color: "text-yellow-400", dotClass: "bg-yellow-500", bg: "bg-yellow-500/10" },
  problematic: { label: "Problemático",  color: "text-red-400",    dotClass: "bg-red-500",    bg: "bg-red-500/10" },
  abandoned:   { label: "Abandonado",    color: "text-zinc-400",   dotClass: "bg-zinc-500",   bg: "bg-zinc-500/10" },
} as const;

const CATEGORY_ICON: Record<string, any> = {
  gameplay: Gamepad2, lore: BookOpen, ui: LayoutDashboard, multiplayer: Network, economia: Wallet,
  audio: Volume2, bugs: Bug, arte: Palette, programacion: Code, otros: Pin,
};

function StatusDot({ status, className = "" }: { status: string; className?: string }) {
  const st = STATUS[status as keyof typeof STATUS] || STATUS.development;
  return <span className={`inline-block w-2 h-2 rounded-full ${st.dotClass} ${className}`} />;
}

function CategoryIcon({ category, className = "w-3.5 h-3.5" }: { category: string | null | undefined; className?: string }) {
  if (!category) return null;
  const Icon = CATEGORY_ICON[category] || Pin;
  return <Icon className={className} />;
}

export function NotesPanel({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [folders, setFolders] = useState<FolderRow[]>([]);
  const [notes, setNotes] = useState<Note[]>([]);
  const [section, setSection] = useState<"main" | "dev">("main");
  const [activeFolder, setActiveFolder] = useState<FolderRow | null>(null);
  const [active, setActive] = useState<Note | null>(null);
  const [classifying, setClassifying] = useState(false);
  const [analysis, setAnalysis] = useState<string | null>(null);
  const [analyzing, setAnalyzing] = useState(false);
  const [selectMode, setSelectMode] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [moveOpen, setMoveOpen] = useState(false);

  async function load() {
    const did = getDeviceId();
    const [f, n] = await Promise.all([
      supabase.from("note_folders" as any).select("*").eq("device_id", did).order("created_at"),
      supabase.from("notes").select("*").eq("device_id", did).order("updated_at", { ascending: false }),
    ]);
    setFolders((f.data as any) || []);
    setNotes((n.data as any) || []);
  }
  useEffect(() => { if (open) load(); }, [open]);

  const visibleFolders = useMemo(() => folders.filter((f) => f.section === section), [folders, section]);
  const visibleNotes = useMemo(() => {
    if (activeFolder) return notes.filter((n) => n.folder_id === activeFolder.id);
    return notes.filter((n) => n.section === section && !n.folder_id);
  }, [notes, activeFolder, section]);

  function toggleSelect(id: string) {
    setSelected((s) => {
      const n = new Set(s);
      n.has(id) ? n.delete(id) : n.add(id);
      return n;
    });
  }
  function exitSelect() { setSelectMode(false); setSelected(new Set()); setMoveOpen(false); }

  async function moveSelectedTo(folderId: string | null) {
    if (selected.size === 0) return;
    const ids = Array.from(selected);
    const updates: any = { folder_id: folderId, last_activity: new Date().toISOString() };
    if (folderId) {
      const target = folders.find((f) => f.id === folderId);
      if (target) updates.section = target.section;
    }
    await supabase.from("notes").update(updates).in("id", ids);
    sfx.tap();
    exitSelect();
    load();
  }

  async function createFolder() {
    sfx.tap();
    const name = prompt("Nombre de la carpeta:");
    if (!name) return;
    const did = getDeviceId();
    await supabase.from("note_folders" as any).insert({ device_id: did, name, section });
    load();
  }

  async function deleteFolder(id: string) {
    if (!confirm("¿Eliminar carpeta? Las notas dentro quedarán sin carpeta.")) return;
    await supabase.from("note_folders" as any).delete().eq("id", id);
    if (activeFolder?.id === id) setActiveFolder(null);
    load();
  }

  async function setFolderStatus(id: string, status: string) {
    await supabase.from("note_folders" as any).update({ status }).eq("id", id);
    load();
  }

  async function createNote() {
    sfx.tap();
    const did = getDeviceId();
    const { data } = await supabase.from("notes")
      .insert({
        device_id: did,
        title: "Nueva nota",
        content: "",
        section,
        folder_id: activeFolder?.id || null,
      })
      .select().single();
    if (data) { setActive(data as Note); load(); }
  }

  async function save() {
    if (!active) return;
    sfx.tap();
    await supabase.from("notes").update({
      title: active.title,
      content: active.content,
      updated_at: new Date().toISOString(),
      last_activity: new Date().toISOString(),
    }).eq("id", active.id);
    load();
  }

  async function classify() {
    if (!active) return;
    setClassifying(true);
    try {
      const r = await classifyNote(active.title, active.content);
      const updated = {
        ...active,
        category: r.category || active.category,
        status: r.status || active.status,
        // La IA no puede mover la nota de sección (antes parecía que se eliminaba)
        section: active.section,
        ai_summary: r.summary || active.ai_summary,
      };
      await supabase.from("notes").update({
        category: updated.category,
        status: updated.status,
        ai_summary: updated.ai_summary,
        last_activity: new Date().toISOString(),
      }).eq("id", active.id);
      setActive(updated);
      load();
    } catch (e) { console.error(e); }
    setClassifying(false);
  }

  async function runAnalysis() {
    setAnalyzing(true);
    setAnalysis(null);
    try {
      const r = await analyzeProject(notes.slice(0, 30));
      setAnalysis(r);
    } catch (e: any) { setAnalysis("Error: " + e.message); }
    setAnalyzing(false);
  }

  async function remove(id: string) {
    await supabase.from("notes").delete().eq("id", id);
    if (active?.id === id) setActive(null);
    load();
  }

  if (!open) return null;
  return (
    <div className="fixed inset-0 z-[60] bg-background animate-fade-up flex flex-col">
      {/* Header */}
      <header className="glass border-b border-border px-4 py-3 flex items-center gap-3">
        <button onClick={onClose} className="tap p-2 rounded-lg hover:bg-accent"><X className="w-5 h-5" /></button>
        <OrionLogo size={32} />
        <div className="flex-1 min-w-0">
          <div className="font-semibold tracking-tight">Modo Notas</div>
          <div className="text-[11px] text-muted-foreground">Notas inteligentes con análisis del proyecto</div>
        </div>
        <button
          onClick={runAnalysis}
          disabled={analyzing || notes.length === 0}
          className="tap px-3 py-1.5 rounded-lg gradient-orion text-primary-foreground text-sm flex items-center gap-1.5 disabled:opacity-50 shadow-glow"
        >
          {analyzing ? <Loader2 className="w-4 h-4 animate-spin" /> : <Brain className="w-4 h-4" />}
          <span className="hidden sm:inline">Analizar proyecto</span>
        </button>
      </header>

      {/* Section tabs */}
      <div className="border-b border-border px-3 flex gap-1">
        {SECTIONS.map((s) => {
          const Icon = s.Icon;
          const isActive = section === s.id;
          return (
            <button
              key={s.id}
              onClick={() => { sfx.tap(); setSection(s.id as any); setActiveFolder(null); setActive(null); exitSelect(); }}
              className={`tap px-4 py-2.5 text-sm border-b-2 transition flex items-center gap-1.5 ${isActive ? "border-primary text-foreground" : "border-transparent text-muted-foreground hover:text-foreground"}`}
            >
              <Icon className="w-4 h-4" /> {s.label}
            </button>
          );
        })}
      </div>

      <div className="flex-1 flex overflow-hidden">
        {/* Sidebar: folders + notes — hidden on mobile when a note or analysis is open */}
        <aside className={`${(active || analysis !== null) ? "hidden md:flex" : "flex"} w-full md:w-80 border-r border-border flex-col`}>
          {/* Breadcrumb */}
          <div className="p-3 flex items-center gap-2 border-b border-border">
            {activeFolder ? (
              <>
                <button onClick={() => { setActiveFolder(null); exitSelect(); }} className="tap p-1 rounded hover:bg-accent"><ArrowLeft className="w-4 h-4" /></button>
                <span className="text-sm truncate flex items-center gap-1.5">
                  <StatusDot status={activeFolder.status} /> {activeFolder.name}
                </span>
              </>
            ) : (
              <span className="text-sm text-muted-foreground">Carpetas y notas</span>
            )}
            <div className="ml-auto flex gap-1">
              <button
                onClick={() => { sfx.tap(); selectMode ? exitSelect() : setSelectMode(true); }}
                title={selectMode ? "Cancelar selección" : "Seleccionar notas"}
                className={`tap p-1.5 rounded-lg ${selectMode ? "bg-primary text-primary-foreground" : "hover:bg-accent"}`}
              >
                <CheckSquare className="w-4 h-4" />
              </button>
              {!activeFolder && !selectMode && (
                <button onClick={createFolder} title="Nueva carpeta" className="tap p-1.5 rounded-lg hover:bg-accent"><FolderPlus className="w-4 h-4" /></button>
              )}
              {!selectMode && (
                <button onClick={createNote} title="Nueva nota" className="tap p-1.5 rounded-lg bg-primary text-primary-foreground"><Plus className="w-4 h-4" /></button>
              )}
            </div>
          </div>

          {selectMode && (
            <div className="px-3 py-2 border-b border-border bg-accent/30 flex items-center gap-2 relative animate-fade-up">
              <span className="text-xs text-muted-foreground">{selected.size} seleccionada{selected.size === 1 ? "" : "s"}</span>
              <button
                disabled={selected.size === 0}
                onClick={() => setMoveOpen((v) => !v)}
                className="tap ml-auto px-2.5 py-1 rounded-lg bg-primary text-primary-foreground text-xs flex items-center gap-1 disabled:opacity-40"
              >
                <FolderInput className="w-3 h-3" /> Mover a…
              </button>
              {moveOpen && (
                <div className="absolute top-full right-2 mt-1 z-10 w-56 bg-card border border-border rounded-xl shadow-soft p-1 max-h-72 overflow-y-auto animate-panel-in">
                  <button onClick={() => moveSelectedTo(null)} className="w-full text-left text-xs px-2.5 py-1.5 rounded-lg hover:bg-accent flex items-center gap-2">
                    <Folder className="w-3.5 h-3.5 text-muted-foreground" /> Sin carpeta
                  </button>
                  {folders.length === 0 && <div className="text-[11px] text-muted-foreground px-2.5 py-2">Sin carpetas. Crea una primero.</div>}
                  {folders.map((f) => (
                    <button key={f.id} onClick={() => moveSelectedTo(f.id)} className="w-full text-left text-xs px-2.5 py-1.5 rounded-lg hover:bg-accent flex items-center gap-2">
                      <Folder className="w-3.5 h-3.5" style={{ color: f.color }} />
                      <span className="truncate">{f.name}</span>
                      <span className="ml-auto text-[10px] text-muted-foreground">{f.section}</span>
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}

          <div className="flex-1 overflow-y-auto p-2">
            {/* Folders grid */}
            {!activeFolder && visibleFolders.length > 0 && (
              <div key={`${section}-folders`} className="grid grid-cols-2 gap-2 mb-3">
                {visibleFolders.map((f, i) => {
                  const st = STATUS[f.status as keyof typeof STATUS] || STATUS.development;
                  const count = notes.filter((n) => n.folder_id === f.id).length;
                  return (
                    <div key={f.id} style={{ animationDelay: `${Math.min(i, 8) * 60}ms` }}
                      className={`group relative ${st.bg} border border-border rounded-xl p-3 cursor-pointer hover-scale shadow-soft animate-soft-rise`}
                      onClick={() => { sfx.tap(); setActiveFolder(f); setActive(null); }}>
                      <div className="flex items-center gap-2">
                        <Folder className="w-5 h-5" style={{ color: f.color }} />
                        <StatusDot status={f.status} />
                      </div>
                      <div className="text-sm font-medium mt-1.5 truncate">{f.name}</div>
                      <div className="text-[10px] text-muted-foreground">{count} nota{count !== 1 ? "s" : ""}</div>
                      <select
                        value={f.status}
                        onClick={(e) => e.stopPropagation()}
                        onChange={(e) => setFolderStatus(f.id, e.target.value)}
                        className="absolute bottom-1 right-1 text-[9px] bg-transparent opacity-0 group-hover:opacity-100"
                      >
                        {Object.entries(STATUS).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
                      </select>
                      <button
                        onClick={(e) => { e.stopPropagation(); deleteFolder(f.id); }}
                        title="Eliminar carpeta"
                        className="absolute top-1 right-1 p-1 rounded-md bg-destructive/10 text-destructive hover:bg-destructive/20"
                      ><Trash2 className="w-3.5 h-3.5" /></button>
                    </div>
                  );
                })}
              </div>
            )}

            {/* Notes list */}
            <div key={`${section}-${activeFolder?.id ?? "root"}-notes`} className="space-y-1">
              {visibleNotes.map((n, i) => {
                const isSel = selected.has(n.id);
                return (
                  <div key={n.id}
                    onClick={() => {
                      sfx.tap();
                      if (selectMode) toggleSelect(n.id);
                      else setActive(n);
                    }}
                    style={{ animationDelay: `${Math.min(i, 12) * 40}ms` }}
                    className={`group cursor-pointer px-3 py-2 rounded-xl flex items-start gap-2 animate-fade-up transition-smooth ${(!selectMode && active?.id === n.id) || isSel ? "bg-accent" : "hover:bg-accent/60 hover:translate-x-0.5"}`}>
                    {selectMode ? (
                      isSel ? <CheckSquare className="w-4 h-4 mt-0.5 text-primary shrink-0" /> : <Square className="w-4 h-4 mt-0.5 text-muted-foreground shrink-0" />
                    ) : (
                      <StatusDot status={n.status} className="mt-1.5" />
                    )}
                    <div className="flex-1 min-w-0">
                      <div className="text-sm truncate flex items-center gap-1.5">
                        {n.category && <CategoryIcon category={n.category} />}
                        {n.title}
                      </div>
                      <div className="text-[10px] text-muted-foreground truncate">
                        {n.ai_summary || new Date(n.updated_at).toLocaleDateString()}
                      </div>
                    </div>
                    {!selectMode && (
                      <button
                        onClick={(e) => { e.stopPropagation(); if (confirm("¿Eliminar nota?")) remove(n.id); }}
                        title="Eliminar nota"
                        className="p-1.5 rounded-md bg-destructive/10 text-destructive hover:bg-destructive/20 shrink-0"
                      >
                        <Trash2 className="w-3.5 h-3.5" />
                      </button>
                    )}
                  </div>
                );
              })}
              {visibleNotes.length === 0 && !activeFolder && visibleFolders.length === 0 && (
                <div className="text-center text-xs text-muted-foreground py-12">
                  Sin notas. Crea una carpeta o nota nueva.
                </div>
              )}
            </div>
          </div>
        </aside>

        {/* Editor / analysis */}
        <section className={`${(active || analysis !== null) ? "flex" : "hidden md:flex"} flex-1 flex-col min-w-0`}>
          {analysis !== null ? (
            <div className="flex-1 overflow-y-auto p-6">
              <div className="max-w-3xl mx-auto">
                <div className="flex items-center justify-between mb-4">
                  <div className="flex items-center gap-2">
                    <OrionLogo size={36} glow />
                    <div>
                      <div className="font-semibold">Análisis del proyecto</div>
                      <div className="text-xs text-muted-foreground">Detectado por Orión</div>
                    </div>
                  </div>
                  <button onClick={() => setAnalysis(null)} className="tap p-2 rounded-lg hover:bg-accent"><X className="w-4 h-4" /></button>
                </div>
                <div className="glass-strong rounded-2xl p-5 whitespace-pre-wrap text-sm leading-relaxed animate-panel-in">
                  {analysis}
                </div>
              </div>
            </div>
          ) : active ? (
            <div key={active.id} className="flex-1 flex flex-col min-h-0 animate-panel-in">
              <div className="p-3 border-b border-border flex items-center gap-2 flex-wrap">
                <button onClick={() => setActive(null)} className="md:hidden tap p-1 rounded-lg hover:bg-accent"><ArrowLeft className="w-4 h-4" /></button>
                <span className="text-xs text-muted-foreground">Estado:</span>
                <select
                  value={active.status}
                  onChange={(e) => setActive({ ...active, status: e.target.value })}
                  className="text-xs bg-card border border-border rounded-lg px-2 py-1"
                >
                  {Object.entries(STATUS).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
                </select>
                {active.category && (
                  <span className="text-xs px-2 py-1 rounded-lg bg-primary/10 text-primary flex items-center gap-1">
                    <CategoryIcon category={active.category} className="w-3 h-3" /> {active.category}
                  </span>
                )}
                <button
                  onClick={classify}
                  disabled={classifying || !active.content}
                  className="tap ml-auto px-2.5 py-1 rounded-lg bg-secondary text-secondary-foreground text-xs flex items-center gap-1 disabled:opacity-50"
                >
                  {classifying ? <Loader2 className="w-3 h-3 animate-spin" /> : <Wand2 className="w-3 h-3" />}
                  Clasificar
                </button>
                <button onClick={save} className="tap px-2.5 py-1 rounded-lg bg-primary text-primary-foreground text-xs flex items-center gap-1">
                  <Save className="w-3 h-3" /> Guardar
                </button>
              </div>
              <div className="flex-1 flex flex-col p-4 gap-3 overflow-y-auto">
                <input
                  value={active.title}
                  onChange={(e) => setActive({ ...active, title: e.target.value })}
                  className="text-2xl font-semibold bg-transparent outline-none border-b border-border pb-2"
                />
                {active.ai_summary && (
                  <div className="text-xs text-muted-foreground italic flex items-start gap-1.5 animate-fade-up">
                    <Sparkles className="w-3 h-3 mt-0.5 text-primary shrink-0" />
                    {active.ai_summary}
                  </div>
                )}
                <textarea
                  value={active.content}
                  onChange={(e) => setActive({ ...active, content: e.target.value })}
                  placeholder="Escribe tus ideas, mecánicas, bugs, diálogos, sistemas, mapas, tareas, inspiración… Orión detectará el contexto automáticamente."
                  className="flex-1 bg-transparent outline-none resize-none text-sm leading-relaxed min-h-[300px]"
                />
              </div>
            </div>
          ) : (
            <div className="flex-1 flex flex-col items-center justify-center text-muted-foreground text-sm gap-3 p-8 text-center">
              <OrionLogo size={64} />
              <div>Selecciona o crea una nota para empezar</div>
              <div className="text-xs max-w-md">
                Las notas se clasifican automáticamente. Usa <strong>Analizar proyecto</strong> para que Orión detecte tareas abandonadas, scope creep y prioridades rotas.
              </div>
            </div>
          )}
        </section>
      </div>
    </div>
  );
}
