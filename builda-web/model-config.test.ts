/// <reference types="bun" />
import { test, expect } from "bun:test";
import { LOCAL_MODEL } from "./model-config";
import asset from "./assets/model.asset.json";

test("the accepted lighter model is complete Gemma rather than the previous 135M model", () => {
  expect(LOCAL_MODEL.name).toBe("Gemma 3 270M Instruct");
  expect(asset.size).toBe(184517664);
  expect(asset.size).toBeLessThan(200 * 1024 * 1024);
});