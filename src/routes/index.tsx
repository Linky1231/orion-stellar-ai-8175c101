import { createFileRoute } from "@tanstack/react-router";
import { ChatApp } from "@/components/orion/ChatApp";
import { AuthScreen } from "@/components/orion/AuthScreen";
import { AuthProvider, useAuth } from "@/lib/auth";
import { Loader2 } from "lucide-react";
const Spinner = () => (
  <div className="min-h-screen flex items-center justify-center">
    <Loader2 className="w-6 h-6 animate-spin text-primary" />
  </div>
);

function Gate() {
  const { user, loading } = useAuth();
  if (loading) return <Spinner />;
  // Cobro desactivado temporalmente: acceso directo al chat tras iniciar sesión.
  return user ? <ChatApp key={user.id} /> : <AuthScreen />;
}

export const Route = createFileRoute("/")({
  ssr: false,
  head: () => ({
    meta: [
      { title: "Orión Estellar v5.0 — Asistente de IA" },
      { name: "description", content: "Orión Estellar: la asistente de IA con personalidad propia para creadores de videojuegos. Programación, arte y diseño de niveles." },
      { property: "og:title", content: "Orión Estellar v5.0 — Asistente de IA" },
      { property: "og:description", content: "La asistente de IA con personalidad propia para creadores de videojuegos." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: () => (
    <AuthProvider>
      <Gate />
    </AuthProvider>
  ),
});
