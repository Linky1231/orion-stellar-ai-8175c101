import { createFileRoute } from "@tanstack/react-router";
import { LegalPage } from "@/components/orion/LegalPage";

const URL = "https://orion-stellar-ai.lovable.app/refund";

export const Route = createFileRoute("/refund")({
  head: () => ({
    meta: [
      { title: "Política de Reembolsos — Orión Estellar" },
      { name: "description", content: "Garantía de devolución de 30 días para Orión Estellar." },
      { property: "og:title", content: "Política de Reembolsos — Orión Estellar" },
      { property: "og:description", content: "Reembolso completo dentro de 30 días desde tu compra." },
      { property: "og:type", content: "article" },
      { property: "og:url", content: URL },
      { name: "twitter:card", content: "summary" },
    ],
    links: [{ rel: "canonical", href: URL }],
  }),
  component: Refund,
});

function Refund() {
  return (
    <LegalPage title="Política de Reembolsos" updated="14 de octubre de 2026">
      <p>Ofrecemos una <b>garantía de devolución de 30 días</b>. Si no estás satisfecho con tu compra de Orión Estellar, puedes solicitar un reembolso completo dentro de los 30 días posteriores a la fecha de tu pedido, sin necesidad de dar explicaciones.</p>
      <h2>Cómo solicitarlo</h2>
      <p>Los reembolsos son procesados por nuestro proveedor de pagos, Paddle, que es el Comerciante Registrado de todos nuestros pedidos. Para solicitarlo, visita <a href="https://paddle.net" target="_blank" rel="noopener noreferrer">paddle.net</a> e ingresa el correo de tu compra, o escríbenos a linkyteam989@gmail.com y lo gestionaremos por ti.</p>
      <p>Más información en la <a href="https://www.paddle.com/legal/refund-policy" target="_blank" rel="noopener noreferrer">política de reembolsos de Paddle</a>.</p>
    </LegalPage>
  );
}
