import { Link } from "@tanstack/react-router";
import type { ReactNode } from "react";
import { OrionLogo } from "./OrionLogo";

export function SiteFooter() {
  return (
    <footer className="w-full px-4 py-6 text-center text-xs text-muted-foreground space-x-4">
      <Link to="/pricing" className="underline">Precios</Link>
      <Link to="/terms" className="underline">Términos</Link>
      <Link to="/privacy" className="underline">Privacidad</Link>
      <Link to="/refund" className="underline">Reembolsos</Link>
      <span>© {new Date().getFullYear()} Gilma Reyes</span>
    </footer>
  );
}

export function LegalPage({ title, updated, children }: { title: string; updated?: string; children: ReactNode }) {
  return (
    <div className="min-h-screen flex flex-col">
      <header className="px-4 py-4 max-w-3xl w-full mx-auto">
        <Link to="/" className="inline-flex items-center gap-2 font-semibold">
          <OrionLogo size={32} /> Orión Estellar
        </Link>
      </header>
      <main className="flex-1 px-4 pb-10 max-w-3xl w-full mx-auto">
        <article className="liquid-glass rounded-3xl p-6 md:p-8 space-y-4 text-sm leading-relaxed [&_h2]:text-base [&_h2]:font-semibold [&_h2]:mt-6 [&_ul]:list-disc [&_ul]:pl-5 [&_ul]:space-y-1 [&_a]:underline">
          <h1 className="text-2xl font-semibold">{title}</h1>
          {updated && <p className="text-xs text-muted-foreground">Última actualización: {updated}</p>}
          {children}
        </article>
      </main>
      <SiteFooter />
    </div>
  );
}
