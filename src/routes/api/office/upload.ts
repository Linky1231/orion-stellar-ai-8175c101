import { createFileRoute } from "@tanstack/react-router";

const MAP: Record<string, { id: string; env: string; mime: string }> = {
  pptx: { id: "microsoft_powerpoint", env: "MICROSOFT_POWERPOINT_API_KEY", mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation" },
  xlsx: { id: "microsoft_excel", env: "MICROSOFT_EXCEL_API_KEY", mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
  docx: { id: "microsoft_word", env: "MICROSOFT_WORD_API_KEY", mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
};

// Sube el archivo creado por Orión a OneDrive (carpeta "Orion") usando los conectores de Microsoft.
export const Route = createFileRoute("/api/office/upload")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const body = (await request.json().catch(() => ({}))) as { ext?: string; name?: string; base64?: string };
        const cfg = MAP[body.ext || ""];
        if (!cfg || !body.base64 || !body.name) return Response.json({ error: "Datos inválidos" }, { status: 400 });
        const lk = process.env["LOVABLE_API_KEY"];
        const ck = process.env[cfg.env];
        if (!lk || !ck) return Response.json({ error: "Conector no configurado" }, { status: 500 });
        const safe = body.name.replace(/[^\w\-. áéíóúñÁÉÍÓÚÑ]/g, "").slice(0, 80) || "orion";
        const bytes = Buffer.from(body.base64, "base64");
        if (bytes.length > 4_000_000) return Response.json({ error: "Archivo muy grande" }, { status: 413 });
        const path = encodeURIComponent(`Orion/${safe}.${body.ext}`).replace(/%2F/g, "/");
        const res = await fetch(`https://connector-gateway.lovable.dev/${cfg.id}/me/drive/root:/${path}:/content`, {
          method: "PUT",
          headers: { Authorization: `Bearer ${lk}`, "X-Connection-Api-Key": ck, "Content-Type": cfg.mime },
          body: bytes,
        });
        const txt = await res.text();
        if (!res.ok) {
          console.error(`OneDrive upload failed [${res.status}]: ${txt}`);
          return Response.json({ error: `Microsoft [${res.status}]: ${txt.slice(0, 200)}` }, { status: 502 });
        }
        const j: any = JSON.parse(txt);
        return Response.json({ webUrl: j.webUrl });
      },
    },
  },
});
