import { Smartphone, Loader2, CheckCircle2, AlertTriangle, Hand } from "lucide-react";
import type { PhoneProgress } from "@/lib/agi";

export function PhoneTaskCard({ p }: { p: PhoneProgress }) {
  const Icon =
    p.phase === "done"
      ? CheckCircle2
      : p.phase === "error"
        ? AlertTriangle
        : p.phase === "paused"
          ? Hand
          : Loader2;
  const spin = p.phase === "checking" || p.phase === "starting" || p.phase === "running";

  return (
    <div className="liquid-glass rounded-2xl p-4 space-y-3 border border-border/60">
      <div className="flex items-center gap-3">
        <div className="relative">
          <Smartphone className="w-5 h-5 text-primary" />
          {spin && <span className="absolute -inset-1 rounded-full animate-ping bg-primary/20" />}
        </div>
        <div className="flex-1 min-w-0">
          <div className="text-sm font-medium truncate">{p.label}</div>
          <div className="text-[11px] text-muted-foreground">Control de pantalla</div>
        </div>
        <Icon className={`w-4 h-4 text-muted-foreground ${spin ? "animate-spin" : ""}`} />
      </div>

      {p.steps.length > 0 && (
        <ol className="space-y-1 max-h-40 overflow-y-auto pr-1">
          {p.steps.slice(-8).map((s, i) => (
            <li key={i} className="text-xs text-muted-foreground leading-snug">
              • {s}
            </li>
          ))}
        </ol>
      )}

      {p.screenshot && (
        <img
          src={p.screenshot}
          alt="Pantalla del teléfono"
          className="w-full max-w-[220px] rounded-xl border border-border/60 mx-auto"
        />
      )}
    </div>
  );
}
