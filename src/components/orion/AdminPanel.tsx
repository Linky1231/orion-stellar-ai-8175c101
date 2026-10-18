import { useEffect, useState } from "react";
import { localData as supabase } from "@/lib/local-data";
import { sfx } from "@/lib/sounds";
import { uploadAttachment } from "@/lib/orion-api";
import { X, Plus, Trash2, Save, Upload, Image as ImageIcon, Pencil, Code2 } from "lucide-react";

type KB = { id: string; title: string; content: string };
type Ref = { id: string; name: string; url: string; description: string };
type Builda = { id: string; title: string; description: string | null; code: string };

export function AdminPanel({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [tab, setTab] = useState<"config" | "kb" | "refs" | "builda">("config");

  const [cfg, setCfg] = useState<any>(null);
  const [kb, setKb] = useState<KB[]>([]);
  const [refs, setRefs] = useState<Ref[]>([]);
  const [builda, setBuilda] = useState<Builda[]>([]);
  const [newKb, setNewKb] = useState({ title: "", content: "" });
  const [editKbId, setEditKbId] = useState<string | null>(null);
  const [editKbDraft, setEditKbDraft] = useState({ title: "", content: "" });
  const [newRefName, setNewRefName] = useState("");
  const [newRefDesc, setNewRefDesc] = useState("");
  const [newBuilda, setNewBuilda] = useState({ title: "", description: "", code: "" });
  const [editBuildaId, setEditBuildaId] = useState<string | null>(null);
  const [editBuildaDraft, setEditBuildaDraft] = useState({ title: "", description: "", code: "" });

  async function load() {
    const [c, k, r, b] = await Promise.all([
      supabase.from("orion_config").select("*").eq("id", 1).single(),
      supabase.from("orion_knowledge").select("*").order("created_at", { ascending: false }),
      supabase.from("orion_reference_images").select("*").order("created_at", { ascending: false }),
      supabase.from("orion_builda_scripts" as any).select("*").order("created_at", { ascending: false }),
    ]);
    setCfg(c.data);
    setKb((k.data as KB[]) || []);
    setRefs((r.data as Ref[]) || []);
    setBuilda(((b.data as unknown) as Builda[]) || []);
  }
  useEffect(() => { if (open) load(); }, [open]);

  async function saveCfg() {
    sfx.tap();
    await supabase.from("orion_config").update({
      personality: cfg.personality, behavior: cfg.behavior, context: cfg.context,
      updated_at: new Date().toISOString(),
    }).eq("id", 1);
  }

  async function addKb() {
    if (!newKb.title || !newKb.content) return;
    await supabase.from("orion_knowledge").insert(newKb);
    setNewKb({ title: "", content: "" });
    load();
  }
  async function delKb(id: string) {
    await supabase.from("orion_knowledge").delete().eq("id", id);
    load();
  }
  function startEditKb(k: KB) {
    setEditKbId(k.id);
    setEditKbDraft({ title: k.title, content: k.content });
  }
  async function saveEditKb() {
    if (!editKbId) return;
    sfx.tap();
    await supabase.from("orion_knowledge").update({
      title: editKbDraft.title, content: editKbDraft.content,
    }).eq("id", editKbId);
    setEditKbId(null);
    load();
  }

  async function addRef(file: File) {
    if (!newRefName) { alert("Pon un nombre"); return; }
    const url = await uploadAttachment(file, "orion-references");
    await supabase.from("orion_reference_images").insert({ name: newRefName, url, description: newRefDesc });
    setNewRefName(""); setNewRefDesc("");
    load();
  }
  async function delRef(id: string) {
    await supabase.from("orion_reference_images").delete().eq("id", id);
    load();
  }

  async function addBuilda() {
    if (!newBuilda.title.trim() || !newBuilda.code.trim()) return;
    await supabase.from("orion_builda_scripts" as any).insert(newBuilda);
    setNewBuilda({ title: "", description: "", code: "" });
    load();
  }
  async function delBuilda(id: string) {
    await supabase.from("orion_builda_scripts" as any).delete().eq("id", id);
    load();
  }
  function startEditBuilda(b: Builda) {
    setEditBuildaId(b.id);
    setEditBuildaDraft({ title: b.title, description: b.description || "", code: b.code });
  }
  async function saveEditBuilda() {
    if (!editBuildaId) return;
    sfx.tap();
    await supabase.from("orion_builda_scripts" as any).update(editBuildaDraft).eq("id", editBuildaId);
    setEditBuildaId(null);
    load();
  }

  if (!open) return null;
  return (
    <div className="fixed inset-0 z-[70] flex items-center justify-center p-4 bg-foreground/30 backdrop-blur-md animate-fade-up" onClick={onClose}>
      <div onClick={(e) => e.stopPropagation()} className="glass-strong w-full max-w-3xl h-[85vh] rounded-3xl shadow-glow border border-border flex flex-col overflow-hidden">
        <div className="px-5 py-4 border-b border-border flex items-center justify-between">
          <div>
            <div className="text-xs text-muted-foreground">Acceso restringido</div>
            <div className="text-lg font-semibold tracking-tight">Panel de Administración · Orión</div>
          </div>
          <button onClick={onClose} className="tap p-2 rounded-lg hover:bg-accent"><X className="w-4 h-4" /></button>
        </div>
        <div className="px-5 pt-3 flex gap-2 flex-wrap">
          {[
            ["config", "Comportamiento"],
            ["kb", "Conocimiento"],
            ["refs", "Imágenes"],
            ["builda", "Code (Builda)"],
          ].map(([k, l]) => (
            <button
              key={k}
              onClick={() => { sfx.tap(); setTab(k as any); }}
              className={`tap px-3 py-1.5 rounded-full text-sm border ${tab === k ? "bg-primary text-primary-foreground border-transparent" : "bg-card border-border hover:bg-accent"}`}
            >{l}</button>
          ))}
        </div>

        <div className="flex-1 overflow-y-auto p-5">
          {tab === "config" && cfg && (
            <div className="space-y-4">

              {(["context", "personality", "behavior"] as const).map((k) => (
                <div key={k}>
                  <div className="text-xs uppercase tracking-wider text-muted-foreground mb-1">{k}</div>
                  <textarea
                    value={cfg[k] || ""}
                    onChange={(e) => setCfg({ ...cfg, [k]: e.target.value })}
                    rows={5}
                    className="w-full p-3 rounded-xl bg-card border border-border outline-none focus:border-ring text-sm"
                  />
                </div>
              ))}
              <button onClick={saveCfg} className="tap px-4 py-2 rounded-xl gradient-orion text-primary-foreground text-sm font-medium flex items-center gap-2">
                <Save className="w-4 h-4" /> Guardar
              </button>
            </div>
          )}

          {tab === "kb" && (
            <div className="space-y-4">
              <div className="rounded-2xl bg-card border border-border p-4 space-y-2">
                <input
                  placeholder="Título"
                  value={newKb.title}
                  onChange={(e) => setNewKb({ ...newKb, title: e.target.value })}
                  className="w-full px-3 py-2 rounded-lg bg-muted outline-none"
                />
                <textarea
                  placeholder="Contenido (admite párrafos largos)"
                  value={newKb.content}
                  onChange={(e) => setNewKb({ ...newKb, content: e.target.value })}
                  rows={6}
                  className="w-full px-3 py-2 rounded-lg bg-muted outline-none resize-y"
                />
                <button onClick={addKb} className="tap px-3 py-1.5 rounded-lg bg-primary text-primary-foreground text-sm flex items-center gap-1">
                  <Plus className="w-4 h-4" /> Añadir entrada
                </button>
              </div>
              {kb.map((k) => (
                <div key={k.id} className="rounded-xl bg-card border border-border p-4">
                  {editKbId === k.id ? (
                    <div className="space-y-2">
                      <input
                        value={editKbDraft.title}
                        onChange={(e) => setEditKbDraft({ ...editKbDraft, title: e.target.value })}
                        className="w-full px-3 py-2 rounded-lg bg-muted outline-none font-semibold"
                      />
                      <textarea
                        value={editKbDraft.content}
                        onChange={(e) => setEditKbDraft({ ...editKbDraft, content: e.target.value })}
                        rows={6}
                        className="w-full px-3 py-2 rounded-lg bg-muted outline-none resize-y text-sm"
                      />
                      <div className="flex gap-2">
                        <button onClick={saveEditKb} className="tap px-3 py-1.5 rounded-lg bg-primary text-primary-foreground text-sm flex items-center gap-1">
                          <Save className="w-3.5 h-3.5" /> Guardar
                        </button>
                        <button onClick={() => setEditKbId(null)} className="tap px-3 py-1.5 rounded-lg bg-muted text-sm">Cancelar</button>
                      </div>
                    </div>
                  ) : (
                    <>
                      <div className="flex justify-between items-start gap-2">
                        <div className="font-semibold">{k.title}</div>
                        <div className="flex gap-1">
                          <button onClick={() => startEditKb(k)} className="p-1 hover:bg-accent rounded"><Pencil className="w-4 h-4" /></button>
                          <button onClick={() => delKb(k.id)} className="text-destructive p-1"><Trash2 className="w-4 h-4" /></button>
                        </div>
                      </div>
                      <p className="text-sm text-muted-foreground whitespace-pre-wrap mt-1">{k.content}</p>
                    </>
                  )}
                </div>
              ))}
              {kb.length === 0 && <div className="text-center text-sm text-muted-foreground py-8">Base vacía</div>}
            </div>
          )}

          {tab === "refs" && (
            <div className="space-y-4">
              <div className="rounded-2xl bg-card border border-border p-4 space-y-2">
                <input
                  placeholder="Nombre"
                  value={newRefName}
                  onChange={(e) => setNewRefName(e.target.value)}
                  className="w-full px-3 py-2 rounded-lg bg-muted outline-none"
                />
                <input
                  placeholder="Descripción (opcional)"
                  value={newRefDesc}
                  onChange={(e) => setNewRefDesc(e.target.value)}
                  className="w-full px-3 py-2 rounded-lg bg-muted outline-none"
                />
                <label className="tap inline-flex items-center gap-2 px-3 py-2 rounded-lg bg-primary text-primary-foreground text-sm cursor-pointer">
                  <Upload className="w-4 h-4" /> Subir imagen
                  <input type="file" accept="image/*" hidden onChange={(e) => e.target.files?.[0] && addRef(e.target.files[0])} />
                </label>
              </div>
              <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
                {refs.map((r) => (
                  <div key={r.id} className="rounded-xl bg-card border border-border overflow-hidden">
                    <img src={r.url} alt={r.name} className="w-full aspect-square object-cover" />
                    <div className="p-2">
                      <div className="text-xs font-semibold truncate">{r.name}</div>
                      <div className="text-[10px] text-muted-foreground truncate">{r.description}</div>
                      <button onClick={() => delRef(r.id)} className="text-destructive text-xs mt-1 flex items-center gap-1">
                        <Trash2 className="w-3 h-3" /> Eliminar
                      </button>
                    </div>
                  </div>
                ))}
                {refs.length === 0 && (
                  <div className="col-span-full text-center text-muted-foreground text-sm py-8 flex flex-col items-center gap-2">
                    <ImageIcon className="w-6 h-6" /> Sin imágenes
                  </div>
                )}
              </div>
            </div>
          )}

          {tab === "builda" && (
            <div className="space-y-4">
              <div className="text-xs text-muted-foreground flex items-center gap-2">
                <Code2 className="w-3.5 h-3.5" /> Scripts de Builda. Orión los usará como referencia cuando elijas "builda" en el Modo Code.
              </div>
              <div className="rounded-2xl bg-card border border-border p-4 space-y-2">
                <input
                  placeholder="Título (ej: bucle for, declarar variable…)"
                  value={newBuilda.title}
                  onChange={(e) => setNewBuilda({ ...newBuilda, title: e.target.value })}
                  className="w-full px-3 py-2 rounded-lg bg-muted outline-none"
                />
                <input
                  placeholder="Descripción breve (opcional)"
                  value={newBuilda.description}
                  onChange={(e) => setNewBuilda({ ...newBuilda, description: e.target.value })}
                  className="w-full px-3 py-2 rounded-lg bg-muted outline-none"
                />
                <textarea
                  placeholder="Código Builda…"
                  value={newBuilda.code}
                  onChange={(e) => setNewBuilda({ ...newBuilda, code: e.target.value })}
                  rows={8}
                  className="w-full px-3 py-2 rounded-lg bg-muted outline-none resize-y font-mono text-xs"
                />
                <button onClick={addBuilda} className="tap px-3 py-1.5 rounded-lg bg-primary text-primary-foreground text-sm flex items-center gap-1">
                  <Plus className="w-4 h-4" /> Añadir script
                </button>
              </div>
              {builda.map((b) => (
                <div key={b.id} className="rounded-xl bg-card border border-border p-4">
                  {editBuildaId === b.id ? (
                    <div className="space-y-2">
                      <input
                        value={editBuildaDraft.title}
                        onChange={(e) => setEditBuildaDraft({ ...editBuildaDraft, title: e.target.value })}
                        className="w-full px-3 py-2 rounded-lg bg-muted outline-none font-semibold"
                      />
                      <input
                        value={editBuildaDraft.description}
                        onChange={(e) => setEditBuildaDraft({ ...editBuildaDraft, description: e.target.value })}
                        className="w-full px-3 py-2 rounded-lg bg-muted outline-none text-sm"
                      />
                      <textarea
                        value={editBuildaDraft.code}
                        onChange={(e) => setEditBuildaDraft({ ...editBuildaDraft, code: e.target.value })}
                        rows={8}
                        className="w-full px-3 py-2 rounded-lg bg-muted outline-none resize-y font-mono text-xs"
                      />
                      <div className="flex gap-2">
                        <button onClick={saveEditBuilda} className="tap px-3 py-1.5 rounded-lg bg-primary text-primary-foreground text-sm flex items-center gap-1">
                          <Save className="w-3.5 h-3.5" /> Guardar
                        </button>
                        <button onClick={() => setEditBuildaId(null)} className="tap px-3 py-1.5 rounded-lg bg-muted text-sm">Cancelar</button>
                      </div>
                    </div>
                  ) : (
                    <>
                      <div className="flex justify-between items-start gap-2">
                        <div>
                          <div className="font-semibold text-sm">{b.title}</div>
                          {b.description && <div className="text-xs text-muted-foreground">{b.description}</div>}
                        </div>
                        <div className="flex gap-1">
                          <button onClick={() => startEditBuilda(b)} className="p-1 hover:bg-accent rounded"><Pencil className="w-4 h-4" /></button>
                          <button onClick={() => delBuilda(b.id)} className="text-destructive p-1"><Trash2 className="w-4 h-4" /></button>
                        </div>
                      </div>
                      <pre className="text-xs font-mono bg-muted rounded-lg p-3 mt-2 overflow-x-auto whitespace-pre">{b.code}</pre>
                    </>
                  )}
                </div>
              ))}
              {builda.length === 0 && <div className="text-center text-sm text-muted-foreground py-8">Sin scripts de Builda</div>}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
