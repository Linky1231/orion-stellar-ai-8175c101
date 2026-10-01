import { createFileRoute, redirect } from "@tanstack/react-router";
import { useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { lovable } from "@/integrations/lovable";

type OAuthApi = {
  getAuthorizationDetails: (id: string) => Promise<{ data: any; error: any }>;
  approveAuthorization: (id: string) => Promise<{ data: any; error: any }>;
  denyAuthorization: (id: string) => Promise<{ data: any; error: any }>;
};
const oauth = () => (supabase.auth as unknown as { oauth: OAuthApi }).oauth;

export const Route = createFileRoute("/.lovable/oauth/consent")({
  ssr: false,
  head: () => ({
    meta: [
      { title: "Conectar con Orión Estellar" },
      { name: "description", content: "Autoriza a un asistente a usar tu cuenta de Orión Estellar." },
      { property: "og:title", content: "Conectar con Orión Estellar" },
      { property: "og:description", content: "Autoriza a un asistente a usar tu cuenta de Orión Estellar." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  validateSearch: (s: Record<string, unknown>) => ({
    authorization_id: typeof s.authorization_id === "string" ? s.authorization_id : "",
  }),
  loader: async ({ location }) => {
    const id = new URLSearchParams(location.search).get("authorization_id");
    if (!id) throw new Error("Falta authorization_id");
    const { data: s } = await supabase.auth.getSession();
    if (!s.session) return { needsLogin: true as const, details: null };
    const { data, error } = await oauth().getAuthorizationDetails(id);
    if (error) throw new Error(error.message);
    const immediate = data?.redirect_url ?? data?.redirect_to;
    if (immediate && !data?.client) throw redirect({ href: immediate });
    return { needsLogin: false as const, details: data };
  },
  component: Consent,
  errorComponent: ({ error }) => (
    <main className="min-h-screen flex items-center justify-center p-6 text-center">
      No se pudo cargar la solicitud: {String((error as Error)?.message ?? error)}
    </main>
  ),
});

function Consent() {
  const { needsLogin, details } = Route.useLoaderData();
  const { authorization_id } = Route.useSearch();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const name = details?.client?.name ?? "una app";

  async function login() {
    setBusy(true);
    const r: any = await lovable.auth.signInWithOAuth("google", { redirect_uri: window.location.href });
    if (r?.error) { setBusy(false); setError(String(r.error.message ?? r.error)); }
  }

  async function decide(approve: boolean) {
    setBusy(true);
    const { data, error } = approve
      ? await oauth().approveAuthorization(authorization_id)
      : await oauth().denyAuthorization(authorization_id);
    if (error) { setBusy(false); setError(error.message); return; }
    const target = data?.redirect_url ?? data?.redirect_to;
    if (!target) { setBusy(false); setError("No se recibió dirección de retorno."); return; }
    window.location.href = target;
  }

  return (
    <main className="min-h-screen flex items-center justify-center p-6">
      <div className="liquid-glass rounded-2xl p-6 max-w-sm w-full space-y-4 text-center border border-border/60">
        <h1 className="text-xl font-semibold">
          {needsLogin ? "Inicia sesión para continuar" : `Conectar ${name} con Orión`}
        </h1>
        <p className="text-sm text-muted-foreground">
          {needsLogin
            ? "Entra con tu cuenta de Google para autorizar la conexión."
            : `${name} podrá leer tus chats, notas y memoria, y guardar recuerdos.`}
        </p>
        {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
        {needsLogin ? (
          <button disabled={busy} onClick={login} className="w-full rounded-xl bg-primary text-primary-foreground py-2 active:scale-95 transition">
            Entrar con Google
          </button>
        ) : (
          <div className="flex gap-2">
            <button disabled={busy} onClick={() => decide(false)} className="flex-1 rounded-xl border border-border py-2 active:scale-95 transition">Denegar</button>
            <button disabled={busy} onClick={() => decide(true)} className="flex-1 rounded-xl bg-primary text-primary-foreground py-2 active:scale-95 transition">Aprobar</button>
          </div>
        )}
      </div>
    </main>
  );
}
