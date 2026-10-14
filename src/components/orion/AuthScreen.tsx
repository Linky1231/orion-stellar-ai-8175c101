import { useState } from "react";
import { lovable } from "@/integrations/lovable/index";
import { OrionLogo } from "./OrionLogo";
import { Loader2 } from "lucide-react";
import { Link } from "@tanstack/react-router";
import { SiteFooter } from "./LegalPage";

export function AuthScreen() {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function google() {
    setErr(null);
    setBusy(true);
    const result = await lovable.auth.signInWithOAuth("google", { redirect_uri: window.location.origin });
    if (result.error) {
      setErr("No se pudo iniciar sesión con Google. Intenta de nuevo.");
      setBusy(false);
      return;
    }
    if (result.redirected) return;
    setBusy(false);
  }

  return (
    <div className="min-h-screen flex flex-col">
    <div className="flex-1 flex flex-col items-center justify-center px-4 py-10 gap-6">
      <section className="max-w-md text-center space-y-2">
        <h2 className="text-2xl font-semibold text-gradient-orion">Tu asistente de IA para crear videojuegos</h2>
        <p className="text-sm text-muted-foreground">Orión Estellar te ayuda con programación, arte, diseño de niveles, imágenes, búsquedas y documentos de PowerPoint, Excel, Word y PDF — y recuerda todo lo que le enseñas.</p>
        <p className="text-sm">Acceso de por vida por <b>$1 USD</b> (pago único). <Link to="/pricing" className="liquid-glass rounded-full px-2.5 py-0.5 text-xs font-medium inline-block transition-transform active:scale-[0.96]">Ver precios</Link></p>
      </section>
      <div className="w-full max-w-sm liquid-glass rounded-3xl p-7 space-y-6">
        <div className="flex flex-col items-center gap-3 text-center">
          <OrionLogo size={56} glow />
          <div>
            <h1 className="text-xl font-semibold">Orión Estellar</h1>
            <p className="text-xs text-muted-foreground mt-1">Inicia sesión con Google para continuar</p>
          </div>
        </div>


        <button
          type="button"
          onClick={google}
          disabled={busy}
          className="tap w-full h-12 rounded-xl liquid-glass flex items-center justify-center gap-2 text-sm font-medium hover:brightness-110 disabled:opacity-60"
        >
          {busy ? (
            <Loader2 className="w-4 h-4 animate-spin" />
          ) : (
            <svg className="w-4 h-4" viewBox="0 0 48 48" aria-hidden="true">
              <path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9 3.6l6.7-6.7C35.6 2.6 30.2 0 24 0 14.6 0 6.5 5.4 2.6 13.2l7.8 6.1C12.3 13.3 17.6 9.5 24 9.5z" />
              <path fill="#4285F4" d="M46.1 24.6c0-1.6-.1-3.1-.4-4.6H24v9h12.4c-.5 2.9-2.1 5.3-4.6 7l7.1 5.5c4.2-3.9 6.6-9.6 6.6-16.9z" />
              <path fill="#FBBC05" d="M10.4 28.7a14.6 14.6 0 0 1 0-9.4l-7.8-6.1a24 24 0 0 0 0 21.6l7.8-6.1z" />
              <path fill="#34A853" d="M24 48c6.2 0 11.5-2 15.3-5.5l-7.1-5.5c-2 1.4-4.6 2.2-8.2 2.2-6.4 0-11.7-3.8-13.6-9.8l-7.8 6.1C6.5 42.6 14.6 48 24 48z" />
            </svg>
          )}
          Continuar con Google
        </button>

        {err && <p className="text-xs text-destructive text-center">{err}</p>}

        <p className="text-[11px] text-muted-foreground text-center leading-relaxed">
          Tus chats y notas actuales se migran automáticamente a tu cuenta al iniciar sesión.
        </p>
      </div>
    </div>
    <SiteFooter />
    </div>
  );
}
