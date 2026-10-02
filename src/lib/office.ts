import { aiText } from "@/lib/ai";
import type { ChatMsg } from "@/lib/orion-api";

export type OfficeKind = "pptx" | "xlsx" | "docx" | "pdf";

const RE: [OfficeKind, RegExp][] = [
  ["pptx", /\b(power ?point|pptx|presentaci[oó]n|diapositivas?|slides?)\b/i],
  ["xlsx", /\b(excel|xlsx|hoja de c[aá]lculo|tabla|planilla)\b/i],
  ["docx", /\b(word|docx|documento)\b/i],
  ["pdf", /\b(pdf)\b/i],
];
const VERB = /\b(cre(a|ar|ame)|haz(me)?|hac(er|eme)|gener(a|ar|ame)|elabor(a|ar)|arm(a|ar|ame)|prepar(a|ar|ame)|redact(a|ar|ame)|export(a|ar)|convi[eé]rt(e|elo)|pas(a|alo) a|dame|quiero)\b/i;

export function detectOfficeRequest(text: string): OfficeKind | null {
  if (!VERB.test(text)) return null;
  // PDF tiene prioridad si se menciona explícitamente
  if (RE[3][1].test(text)) return "pdf";
  for (const [k, r] of RE) if (r.test(text)) return k;
  return null;
}

const SCHEMA: Record<OfficeKind, string> = {
  pptx: `{"title":"...","slides":[{"title":"...","bullets":["..."],"notes":"..."}]} (6-10 diapositivas, 3-5 viñetas cortas cada una)`,
  xlsx: `{"title":"...","sheets":[{"name":"...","headers":["..."],"rows":[["...",123]]}]} (números como números, no texto)`,
  docx: `{"title":"...","sections":[{"heading":"...","paragraphs":["..."],"bullets":["..."]}]}`,
  pdf: `{"title":"...","sections":[{"heading":"...","paragraphs":["..."],"bullets":["..."]}],"table":{"headers":["..."],"rows":[["..."]]}} (table es opcional)`,
};

function parse(raw: string): any {
  const s = raw.indexOf("{"), e = raw.lastIndexOf("}");
  if (s < 0 || e <= s) throw new Error("La IA no devolvió el contenido del archivo");
  return JSON.parse(raw.slice(s, e + 1));
}

export async function buildOfficeSpec(kind: OfficeKind, request: string, history: ChatMsg[]) {
  const convo = history.slice(-10)
    .map((m) => `${m.role === "user" ? "Usuario" : "Orión"}: ${typeof m.content === "string" ? m.content : ""}`)
    .join("\n").slice(0, 6000);
  const out = await aiText([
    { role: "system", content: `Eres Orión. Crea el contenido completo y de calidad para un archivo. Responde SOLO con JSON válido con esta forma: ${SCHEMA[kind]}. Escribe en español salvo que se pida otro idioma. Usa la conversación como contexto.` },
    { role: "user", content: `Conversación:\n${convo || "(sin contexto)"}\n\nPetición: ${request}` },
  ]);
  return parse(out);
}

const C = { bg: "0B1026", accent: "8B7CF6", text: "F5F3FF", muted: "C4B5FD" };

async function makePptx(s: any): Promise<Blob> {
  const { default: P } = await import("pptxgenjs");
  const p = new P();
  p.layout = "LAYOUT_WIDE";
  const t = p.addSlide();
  t.background = { color: C.bg };
  t.addText(s.title || "Presentación", { x: 0.8, y: 2.6, w: 11.7, h: 1.5, fontSize: 48, bold: true, color: C.text, fontFace: "Georgia" });
  t.addText("Creado por Orión Estellar", { x: 0.8, y: 4.2, w: 11.7, h: 0.6, fontSize: 18, color: C.muted, italic: true });
  for (const sl of s.slides || []) {
    const x = p.addSlide();
    x.background = { color: "FAFAFF" };
    x.addShape("rect", { x: 0, y: 0, w: 0.25, h: 7.5, fill: { color: C.accent } });
    x.addText(sl.title || "", { x: 0.7, y: 0.4, w: 12, h: 1, fontSize: 36, bold: true, color: C.bg, fontFace: "Georgia" });
    x.addText((sl.bullets || []).map((b: string) => ({ text: b, options: { bullet: true, breakLine: true } })),
      { x: 0.9, y: 1.6, w: 11.5, h: 5.3, fontSize: 22, color: "222244", valign: "top", paraSpaceAfter: 10 });
    if (sl.notes) x.addNotes(sl.notes);
  }
  return (await p.write({ outputType: "blob" })) as Blob;
}

async function makeXlsx(s: any): Promise<Blob> {
  const XLSX = await import("xlsx");
  const wb = XLSX.utils.book_new();
  for (const sh of s.sheets || []) {
    const ws = XLSX.utils.aoa_to_sheet([sh.headers || [], ...(sh.rows || [])]);
    ws["!cols"] = (sh.headers || []).map(() => ({ wch: 20 }));
    XLSX.utils.book_append_sheet(wb, ws, String(sh.name || "Hoja").slice(0, 31));
  }
  if (!wb.SheetNames.length) XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet([[""]]), "Hoja1");
  const buf = XLSX.write(wb, { type: "array", bookType: "xlsx" });
  return new Blob([buf], { type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" });
}

async function makeDocx(s: any): Promise<Blob> {
  const d = await import("docx");
  const kids: any[] = [new d.Paragraph({ text: s.title || "Documento", heading: d.HeadingLevel.TITLE })];
  for (const sec of s.sections || []) {
    if (sec.heading) kids.push(new d.Paragraph({ text: sec.heading, heading: d.HeadingLevel.HEADING_1 }));
    for (const p of sec.paragraphs || []) kids.push(new d.Paragraph({ children: [new d.TextRun(p)], spacing: { after: 160 } }));
    for (const b of sec.bullets || []) kids.push(new d.Paragraph({ text: b, bullet: { level: 0 } }));
  }
  return d.Packer.toBlob(new d.Document({ sections: [{ children: kids }] }));
}

async function makePdf(s: any): Promise<Blob> {
  const { jsPDF } = await import("jspdf");
  const doc = new jsPDF({ unit: "pt", format: "a4" });
  const W = doc.internal.pageSize.getWidth(), H = doc.internal.pageSize.getHeight(), M = 56;
  let y = M;
  const need = (h: number) => { if (y + h > H - M) { doc.addPage(); y = M; } };
  const write = (txt: string, size: number, bold = false, indent = 0) => {
    doc.setFont("helvetica", bold ? "bold" : "normal"); doc.setFontSize(size);
    for (const line of doc.splitTextToSize(txt, W - 2 * M - indent)) { need(size * 1.4); doc.text(line, M + indent, y); y += size * 1.4; }
  };
  doc.setTextColor(40, 30, 90); write(s.title || "Documento", 24, true); y += 10; doc.setTextColor(30, 30, 30);
  for (const sec of s.sections || []) {
    if (sec.heading) { y += 8; write(sec.heading, 16, true); }
    for (const p of sec.paragraphs || []) { write(p, 11); y += 4; }
    for (const b of sec.bullets || []) write("•  " + b, 11, false, 10);
  }
  if (s.table?.headers?.length) {
    y += 12;
    const cols = s.table.headers.length, cw = (W - 2 * M) / cols;
    const row = (cells: any[], bold: boolean) => {
      need(20); doc.setFont("helvetica", bold ? "bold" : "normal"); doc.setFontSize(10);
      cells.forEach((c, i) => doc.text(doc.splitTextToSize(String(c ?? ""), cw - 6)[0] || "", M + i * cw + 3, y));
      y += 6; doc.line(M, y, W - M, y); y += 12;
    };
    row(s.table.headers, true);
    for (const r of s.table.rows || []) row(r, false);
  }
  return doc.output("blob");
}

const MIME: Record<OfficeKind, string> = {
  pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  pdf: "application/pdf",
};

export async function makeOfficeFile(kind: OfficeKind, spec: any): Promise<File> {
  const blob = kind === "pptx" ? await makePptx(spec) : kind === "xlsx" ? await makeXlsx(spec) : kind === "docx" ? await makeDocx(spec) : await makePdf(spec);
  const name = String(spec.title || "orion").replace(/[\\/:*?"<>|]/g, "").slice(0, 60) || "orion";
  return new File([blob], `${name}.${kind}`, { type: MIME[kind] });
}

/** Guarda una copia en OneDrive con el conector de Microsoft (no aplica a PDF). */
export async function saveToOneDrive(kind: OfficeKind, file: File): Promise<string | null> {
  if (kind === "pdf") return null;
  try {
    const buf = new Uint8Array(await file.arrayBuffer());
    let bin = ""; for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
    const res = await fetch("/api/office/upload", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ext: kind, name: file.name.replace(/\.\w+$/, ""), base64: btoa(bin) }),
    });
    const j: any = await res.json().catch(() => null);
    return j?.webUrl || null;
  } catch { return null; }
}
