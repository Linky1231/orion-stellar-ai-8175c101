/// <reference types="bun" />
import { test, expect } from "bun:test";
import { buildaTableKey, installBuildaStorage } from "./storage";
import { localData } from "../src/lib/local-data";

test("Builda saves and reads chat through SDK bytes without a login", async () => {
  const saved = new Map<string, Uint8Array>();
  Object.assign(globalThis, { window: { Builda: { privateKV: {
    get: async (key: string) => ({ ok: true, data: saved.get(key) ?? null }),
    set: async (key: string, bytes: Uint8Array) => { saved.set(key, bytes); return { ok: true }; },
  } } } });
  installBuildaStorage();
  const result = await localData.from("conversations").insert({ title: "Hola Builda", device_id: "builda-player" }).select().single();
  expect(result.data.id).toBeString();
  expect(saved.get("orion_local_conversations_v1")).toBeInstanceOf(Uint8Array);
  expect((await localData.from("conversations").select().single()).data.title).toBe("Hola Builda");
  expect(() => buildaTableKey("invalid.key")).toThrow();
  await expect(Promise.resolve(localData.from("messages").insert({ content: "x".repeat(33 * 1024) }))).rejects.toThrow("límite de Builda");
  expect(saved.has("orion_local_messages_v1")).toBe(false);
});