import { Link } from "@tanstack/react-router";
import type { ReactNode } from "react";
import { OrionLogo } from "./OrionLogo";

export function SiteFooter() {
  return (
    <footer className="w-full px-4 py-6 text-center">
      <div className="liquid-glass rounded-full inline-flex flex-wrap items-center justify-center gap-x-4 gap-y-1 px-5 py-2 text-xs text-muted-foreground">
        <Link to="/pricing" className="hover:text-foreground transition-colors">Precios</Link>
        <Link to="/terms" className="hover:text-foreground transition-colors">Términos</Link>
        <Link to="/privacy" className="hover:text-foreground transition-colors">Privacidad</Link>
        <Link to="/refund" className="hover:text-foreground transition-colors">Reembolsos</Link>
        <span>© {new Date().getFullYear()} Gilma Reyes</span>
      </div>
    </footer>
  );
}

export function LegalPage({ title, updated, children }: { title: string; updated?: string; children: ReactNode }) {
  return (
    <div className="min-h-screen flex flex-col">
      <header className="px-4 py-4 max-w-3xl w-full mx-auto">
        <Link to="/" className="liquid-glass rounded-full inline-flex items-center gap-2 px-4 py-2 font-semibold transition-transform active:scale-[0.97]">
          <OrionLogo size={24} /> <span className="text-gradient-orion">Orión Estellar</span>
        </Link>
      </header>
      <main className="flex-1 px-4 pb-10 max-w-3xl w-full mx-auto">
        <article className="liquid-glass rounded-3xl p-6 md:p-8 space-y-4 text-sm leading-relaxed [&_h2]:text-base [&_h2]:font-semibold [&_h2]:mt-6 [&_ul]:list-disc [&_ul]:pl-5 [&_ul]:space-y-1 [&_a]:underline">
          <h1 className="text-2xl font-semibold text-gradient-orion">{title}</h1>
          {updated && <p className="text-xs text-muted-foreground">Última actualización: {updated}</p>}
          {children}
        </article>
      </main>
      <SiteFooter />
    </div>
  );
}
