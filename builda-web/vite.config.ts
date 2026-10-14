// Standalone static build of Orión for the Builda HTML5 platform (not the main app build).
import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "node:path";

const root = path.resolve(__dirname, "..");

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, root, "VITE_");
  return {
    root: __dirname,
    base: "./",
    envDir: root,
    plugins: [react(), tailwindcss()],
    resolve: { alias: { "@": path.join(root, "src") } },
    define: {
      "process.env": JSON.stringify({}),
      ...Object.fromEntries(Object.entries(env).map(([k, v]) => [`import.meta.env.${k}`, JSON.stringify(v)])),
    },
    build: { outDir: "/tmp/builda-dist", emptyOutDir: true, sourcemap: false },
  };
});
