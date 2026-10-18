import { describe, expect, test } from "bun:test";
import { applyLocalQuery } from "./local-data";

describe("local personal data", () => {
  test("stores a new conversation and reads it without an account", () => {
    const conversation = { id: "local-chat", title: "Hola", device_id: "device" };
    const inserted = applyLocalQuery([], "insert", [conversation], []);
    expect(applyLocalQuery(inserted.rows, "select", [], [(row) => row.id === "local-chat"]).selected).toEqual([conversation]);
  });
  test("deleting chats leaves notes untouched", () => {
    const notes = [{ id: "note", content: "Conservar" }];
    const chats = [{ id: "chat" }];
    expect(applyLocalQuery(chats, "delete", [], []).rows).toEqual([]);
    expect(applyLocalQuery(notes, "select", [], []).selected).toEqual([{ id: "note", content: "Conservar" }]);
  });
  test("updates and filters only matching local messages", () => {
    const rows = [{ id: "a", content: "antes" }, { id: "b", content: "conservar" }];
    expect(applyLocalQuery(rows, "update", [{ content: "después" }], [(row) => row.id === "a"]).rows).toEqual([{ id: "a", content: "después" }, { id: "b", content: "conservar" }]);
  });
});