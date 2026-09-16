import { createFileRoute } from "@tanstack/react-router";

type Hit = { title: string; url: string; snippet: string };

function decode(s: string) {
  return s
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#x27;/g, "'")
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function realUrl(href: string) {
  try {
    if (href.startsWith("//")) href = "https:" + href;
    const u = new URL(href);
    const target = u.searchParams.get("uddg");
    return target ? decodeURIComponent(target) : u.toString();
  } catch {
    return href;
  }
}

async function duckduckgo(query: string): Promise<Hit[]> {
  const res = await fetch("https://html.duckduckgo.com/html/?q=" + encodeURIComponent(query), {
    headers: {
      "User-Agent":
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
      "Accept-Language": "es-ES,es;q=0.9,en;q=0.8",
    },
  });
  if (!res.ok) return [];
  const html = await res.text();
  const hits: Hit[] = [];
  const re = /<a[^>]+class="[^"]*result__a[^"]*"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/g;
  const snipRe = /class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)<\/a>/g;
  const snippets: string[] = [];
  let sm: RegExpExecArray | null;
  while ((sm = snipRe.exec(html))) snippets.push(decode(sm[1]));
  let m: RegExpExecArray | null;
  let i = 0;
  while ((m = re.exec(html)) && hits.length < 8) {
    const title = decode(m[2]);
    if (!title) continue;
    hits.push({ title, url: realUrl(m[1]), snippet: snippets[i] || "" });
    i++;
  }
  return hits;
}

export const Route = createFileRoute("/api/ai/search")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const { query } = (await request.json().catch(() => ({}))) as { query?: string };
        if (!query) return Response.json({ error: "Falta la consulta." }, { status: 400 });
        try {
          const results = await duckduckgo(query);
          return Response.json({ results });
        } catch (e: any) {
          return Response.json({ results: [], error: String(e?.message || e) }, { status: 200 });
        }
      },
    },
  },
});
