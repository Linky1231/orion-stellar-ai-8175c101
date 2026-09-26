import { useEffect, useState } from "react";
import { Loader2 } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";
import { getPaddleEnvironment, getPaddlePriceId, initializePaddle } from "@/lib/paddle";
import { OrionLogo } from "./OrionLogo";

export function useHasPaid() {
  const { user } = useAuth();
  const [paid, setPaid] = useState<boolean | null>(null);
  const check = async () => {
    if (!user) return;
    const { data } = await (supabase.from("purchases" as any) as any)
      .select("id").eq("user_id", user.id).eq("environment", getPaddleEnvironment()).limit(1);
    setPaid(!!data?.length);
  };
  useEffect(() => { void check(); }, [user?.id]);
  return { paid, check };
}

export function Paywall({ onPaid }: { onPaid: () => Promise<void> }) {
  const { user, signOut } = useAuth();
  const [busy, setBusy] = useState(false);
  const [waiting, setWaiting] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function pay() {
    if (!user) return;
    setErr(null); setBusy(true);
    try {
      await initializePaddle(() => {
        setWaiting(true);
        let n = 0;
        const t = setInterval(async () => {
          n++;
          await onPaid();
          if (n > 30) clearInterval(t);
        }, 2000);
      });
      const priceId = await getPaddlePriceId("orion_access_once");
      window.Paddle.Checkout.open({
        items: [{ priceId, quantity: 1 }],
        customer: user.email ? { email: user.email } : undefined,
        customData: { userId: user.id },
        settings: { displayMode: "overlay", successUrl: window.location.origin, allowLogout: false, variant: "one-page" },
      });
    } catch {
      setErr("No se pudo abrir el pago. Intenta de nuevo.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="min-h-screen flex flex-col">
      {getPaddleEnvironment() === "sandbox" && (
        <div className="w-full bg-accent text-accent-foreground px-4 py-2 text-center text-xs">
          Los pagos en la vista previa son de prueba.{" "}
          <a href="https://docs.lovable.dev/features/payments#test-and-live-environments" target="_blank" rel="noopener noreferrer" className="underline">Saber más</a>
        </div>
      )}
      <div className="flex-1 flex items-center justify-center px-4 py-10">
        <div className="w-full max-w-sm liquid-glass rounded-3xl p-7 space-y-6 text-center">
          <div className="flex flex-col items-center gap-3">
            <OrionLogo size={56} glow />
            <h1 className="text-xl font-semibold">Acceso a Orión Estellar</h1>
            <p className="text-sm text-muted-foreground">Un solo pago de <b className="text-foreground">$1</b> y entras para siempre.</p>
          </div>
          <button
            type="button"
            onClick={pay}
            disabled={busy || waiting}
            className="w-full h-12 rounded-xl bg-primary text-primary-foreground flex items-center justify-center gap-2 text-sm font-medium transition-transform active:scale-[0.96] disabled:opacity-60"
          >
            {(busy || waiting) && <Loader2 className="w-4 h-4 animate-spin" />}
            {waiting ? "Confirmando pago…" : "Pagar $1 y entrar"}
          </button>
          {err && <p className="text-xs text-destructive">{err}</p>}
          <button onClick={() => void signOut()} className="text-xs text-muted-foreground underline">Cerrar sesión ({user?.email})</button>
        </div>
      </div>
    </div>
  );
}
