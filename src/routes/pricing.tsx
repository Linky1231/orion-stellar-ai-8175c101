import { createFileRoute, Link } from "@tanstack/react-router";
import { LegalPage } from "@/components/orion/LegalPage";

const URL = "https://orion-stellar-ai.lovable.app/pricing";

export const Route = createFileRoute("/pricing")({
  head: () => ({
    meta: [
      { title: "Precios — Orión Estellar" },
      { name: "description", content: "Acceso de por vida a Orión Estellar con un único pago de $1 USD." },
      { property: "og:title", content: "Precios — Orión Estellar" },
      { property: "og:description", content: "Un solo pago de $1 y accedes para siempre." },
      { property: "og:type", content: "website" },
      { property: "og:url", content: URL },
      { name: "twitter:card", content: "summary" },
    ],
    links: [{ rel: "canonical", href: URL }],
  }),
  component: Pricing,
});

function Pricing() {
  return (
    <LegalPage title="Precios">
      <div className="rounded-2xl border border-border p-6 text-center space-y-3">
        <p className="text-sm text-muted-foreground">Acceso completo</p>
        <p className="text-4xl font-semibold">$1 <span className="text-base font-normal text-muted-foreground">USD, pago único</span></p>
        <ul className="text-left inline-block">
          <li>Chat ilimitado con Orión, con memoria propia</li>
          <li>Generación de imágenes y búsqueda en internet</li>
          <li>Creación de PowerPoint, Excel, Word y PDF</li>
          <li>Análisis de imágenes y videos</li>
          <li>Garantía de devolución de 30 días</li>
        </ul>
        <div><Link to="/" className="inline-flex h-11 px-6 items-center rounded-xl bg-primary text-primary-foreground font-medium">Empezar</Link></div>
      </div>
      <p className="text-xs text-muted-foreground">Impuestos aplicables calculados al pagar. Pagos procesados por Paddle, Comerciante Registrado.</p>
    </LegalPage>
  );
}
