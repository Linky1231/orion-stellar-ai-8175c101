import { configureLocalStorage } from "../src/lib/local-data";
import { setAccountScope } from "../src/lib/device";

type KVResult = { ok: boolean; data?: unknown; error?: { message?: string } };
type BuildaStorage = {
  get: (key: string) => Promise<KVResult>;
  set: (key: string, value: Uint8Array) => Promise<KVResult>;
};
function storage(): BuildaStorage {
  const sdk = (window as unknown as { Builda?: { privateKV?: BuildaStorage } }).Builda;
  if (!sdk?.privateKV) throw new Error("Builda no pudo abrir tus datos. Cierra el juego y vuelve a entrar.");
  return sdk.privateKV;
}
export function buildaTableKey(table: string) {
  const key = `orion_local_${table}_v1`;
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(key)) throw new Error("Nombre de guardado no válido.");
  return key;
}

export function installBuildaStorage() {
  // The SDK scopes saved data to the player; there is no separate login or identity request.
  setAccountScope("builda-player");
  configureLocalStorage({
    async read(table) {
      const result = await storage().get(buildaTableKey(table));
      if (!result.ok) throw new Error(result.error?.message || "No se pudo leer el guardado de Builda.");
      if (result.data == null) return undefined;
      if (!(result.data instanceof Uint8Array)) throw new Error("El guardado de Builda no es válido. No se sobrescribió.");
      const rows = JSON.parse(new TextDecoder().decode(result.data));
      if (!Array.isArray(rows)) throw new Error("El guardado de Builda no es válido. No se sobrescribió.");
      return rows;
    },
    async write(table, rows) {
      const bytes = new TextEncoder().encode(JSON.stringify(rows));
      if (bytes.length > 30 * 1024) {
        throw new Error("Este guardado alcanzó el límite de Builda. Exporta o elimina datos antiguos antes de guardar más.");
      }
      const result = await storage().set(buildaTableKey(table), bytes);
      if (!result.ok) throw new Error(result.error?.message || "No se pudo guardar en Builda.");
    },
  });
}