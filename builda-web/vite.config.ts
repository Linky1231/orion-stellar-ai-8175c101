// Standalone static build of Orión for the Builda HTML5 platform (not the main app build).
import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "node:path";
import modelAsset from "./assets/model.asset.json";

const root = path.resolve(__dirname, "..");

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, root, "VITE_");
  return {
    root: __dirname,
    base: "./",
    envDir: root,
    plugins: [react(), tailwindcss(), {
      name: "bundle-orion-local-model",
      async generateBundle() {
        // Download at packaging time only; the Builda client reads the bundled file offline.
        const assetUrl = new URL(modelAsset.url, "http://localhost:8080");
        const response = await fetch(assetUrl);
        if (!response.ok) throw new Error(`Cannot package Orión model: ${response.status}`);
        const bytes = new Uint8Array(await response.arrayBuffer());
        if (bytes.byteLength !== modelAsset.size || new TextDecoder().decode(bytes.slice(0, 4)) !== "GGUF") {
          throw new Error("Cannot package Orión: missing or incomplete GGUF model");
        }
        this.emitFile({ type: "asset", fileName: "model.bin", source: bytes });
      },
    }],
    resolve: { alias: { "@": path.join(root, "src") } },
    define: {
      "process.env": JSON.stringify({}),
      ...Object.fromEntries(Object.entries(env).map(([k, v]) => [`import.meta.env.${k}`, JSON.stringify(v)])),
    },
    build: { outDir: "/tmp/builda-dist", emptyOutDir: true, sourcemap: false },
  };
});
