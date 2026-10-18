// Browser-only persistence; no account or network connection is required.
type Row = Record<string, any>;
type Result = { data: any; error: null };
const DATABASE = "orion-local-v1";
let database: Promise<IDBDatabase> | undefined;
const listeners = new Set<{ table: string; callback: (payload: any) => void }>();

function openDatabase() {
  if (!database) database = new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open(DATABASE, 1);
    request.onupgradeneeded = () => request.result.createObjectStore("tables");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => { database = undefined; reject(new Error("No se pudo abrir el almacenamiento de este dispositivo.")); };
  });
  return database;
}

export function applyLocalQuery(rows: Row[], action: string, values: Row[], filters: ((row: Row) => boolean)[]) {
  const matches = (row: Row) => filters.every((filter) => filter(row));
  const selected = rows.filter(matches);
  if (action === "insert") return { rows: [...rows, ...values], selected: values };
  if (action === "update") {
    const updated = selected.map((row) => ({ ...row, ...values[0] }));
    return { rows: rows.map((row) => matches(row) ? { ...row, ...values[0] } : row), selected: updated };
  }
  if (action === "delete") return { rows: rows.filter((row) => !matches(row)), selected };
  return { rows, selected };
}

class LocalQuery implements PromiseLike<Result> {
  private action = "select";
  private values: Row[] = [];
  private filters: ((row: Row) => boolean)[] = [];
  private sorting?: { field: string; ascending: boolean };
  private one = false;
  private maximum?: number;
  constructor(private table: string) {}
  select(_columns?: string) { return this; }
  insert(input: Row | Row[]) {
    this.action = "insert";
    const now = new Date().toISOString();
    this.values = (Array.isArray(input) ? input : [input]).map((row) => ({
      id: crypto.randomUUID(), created_at: now, updated_at: now, attachments: [],
      section: "main", status: "development", folder_id: null, ...row,
    }));
    return this;
  }
  update(values: Row) { this.action = "update"; this.values = [values]; return this; }
  delete() { this.action = "delete"; return this; }
  eq(field: string, value: unknown) { this.filters.push((row) => row[field] === value); return this; }
  in(field: string, values: unknown[]) { this.filters.push((row) => values.includes(row[field])); return this; }
  order(field: string, options?: { ascending?: boolean }) { this.sorting = { field, ascending: options?.ascending !== false }; return this; }
  limit(maximum: number) { this.maximum = maximum; return this; }
  single() { this.one = true; return this; }
  maybeSingle() { this.one = true; return this; }
  then<TResult1 = Result, TResult2 = never>(fulfilled?: ((value: Result) => TResult1 | PromiseLike<TResult1>) | null, rejected?: ((reason: any) => TResult2 | PromiseLike<TResult2>) | null): PromiseLike<TResult1 | TResult2> {
    return this.execute().then(fulfilled, rejected);
  }
  private async execute(): Promise<Result> {
    const db = await openDatabase();
    return new Promise((resolve, reject) => {
      const transaction = db.transaction("tables", "readwrite");
      const store = transaction.objectStore("tables");
      const request = store.get(this.table);
      let data: any;
      request.onsuccess = () => {
        const initial = this.table === "orion_config" ? [{ id: 1, personality: "", behavior: "", context: "" }] : [];
        const rows = (Array.isArray(request.result) ? request.result : initial).filter((row: unknown) => row && typeof row === "object");
        const result = applyLocalQuery(rows, this.action, this.values, this.filters);
        if (this.action !== "select") store.put(result.rows, this.table);
        if (this.sorting) {
          const { field, ascending } = this.sorting;
          result.selected.sort((a, b) => String(a[field] ?? "").localeCompare(String(b[field] ?? "")) * (ascending ? 1 : -1));
        }
        const selected = this.maximum === undefined ? result.selected : result.selected.slice(0, this.maximum);
        data = this.one ? selected[0] ?? null : selected;
        if (this.table === "note_folders" && this.action === "delete") {
          const notes = store.get("notes");
          notes.onsuccess = () => store.put((notes.result || []).map((note: Row) => result.selected.some((folder) => folder.id === note.folder_id) ? { ...note, folder_id: null } : note), "notes");
        }
      };
      transaction.oncomplete = () => {
        resolve({ data, error: null });
        if (this.action !== "select") {
          for (const listener of listeners) {
            if (listener.table === this.table) listener.callback({ new: this.one ? data : data?.[0], eventType: this.action.toUpperCase() });
          }
        }
      };
      transaction.onabort = transaction.onerror = () => reject(new Error("No se pudo guardar. Revisa el espacio disponible y los permisos de almacenamiento del dispositivo."));
    });
  }
}

class LocalChannel {
  private listener?: { table: string; callback: (payload: any) => void };
  on(_event: string, filter: { table: string; event?: string }, callback: (payload: any) => void) {
    // Chat inserts already update React state; conversation-list changes need a reload.
    if (filter.table === "conversations") this.listener = { table: filter.table, callback };
    return this;
  }
  subscribe() { if (this.listener) listeners.add(this.listener); return this; }
  unsubscribe() { if (this.listener) listeners.delete(this.listener); }
}

export const localData = {
  from: (table: string) => new LocalQuery(table),
  channel: (_name: string) => new LocalChannel(),
  removeChannel: async (channel: LocalChannel) => { channel.unsubscribe(); },
};