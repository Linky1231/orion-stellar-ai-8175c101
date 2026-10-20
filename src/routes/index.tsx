import { createFileRoute, Link } from "@tanstack/react-router";
import { ChatApp } from "@/components/orion/ChatApp";
import { Button } from "@/components/ui/button";
import { BookOpen } from "lucide-react";

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
  component: ChatPage,
});

function ChatPage() {
  return <ChatApp headerAction={<Button asChild variant="ghost" size="icon" title="Guía de herramientas de IA"><Link to="/blog/ai-tools-for-game-development" aria-label="Guía de herramientas de IA"><BookOpen /></Link></Button>} />;
}
