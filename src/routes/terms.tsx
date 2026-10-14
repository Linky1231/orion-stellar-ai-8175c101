import { createFileRoute } from "@tanstack/react-router";
import { LegalPage } from "@/components/orion/LegalPage";

const URL = "https://orion-stellar-ai.lovable.app/terms";

export const Route = createFileRoute("/terms")({
  head: () => ({
    meta: [
      { title: "Términos y Condiciones — Orión Estellar" },
      { name: "description", content: "Términos y condiciones de uso de Orión Estellar, asistente de IA ofrecido por Gilma Reyes." },
      { property: "og:title", content: "Términos y Condiciones — Orión Estellar" },
      { property: "og:description", content: "Condiciones de uso del asistente de IA Orión Estellar." },
      { property: "og:type", content: "article" },
      { property: "og:url", content: URL },
      { name: "twitter:card", content: "summary" },
    ],
    links: [{ rel: "canonical", href: URL }],
  }),
  component: Terms,
});

function Terms() {
  return (
    <LegalPage title="Términos y Condiciones" updated="14 de octubre de 2026">
      <p>Estos términos regulan el uso de Orión Estellar (el "Servicio"), un asistente de inteligencia artificial para creadores de videojuegos que genera texto, imágenes, documentos y analiza contenido. El Servicio es ofrecido por <b>Gilma Reyes</b> ("nosotros"). Al usar el Servicio, usted celebra un contrato con Gilma Reyes.</p>

      <h2>1. Aceptación</h2>
      <p>Al acceder o seguir usando el Servicio, usted acepta estos términos. Si no está de acuerdo, no use el Servicio. Debe ser mayor de edad o tener autorización para obligar a la organización que representa.</p>

      <h2>2. Cuenta</h2>
      <p>Debe proporcionar información veraz, mantener la confidencialidad de sus credenciales y es responsable de toda actividad realizada con su cuenta.</p>

      <h2>3. Licencia y restricciones</h2>
      <p>Le otorgamos un derecho limitado, no exclusivo e intransferible de usar el Servicio. No puede realizar ingeniería inversa, revender, redistribuir ni eludir límites técnicos del Servicio.</p>

      <h2>4. Uso indebido</h2>
      <p>No puede usar el Servicio para:</p>
      <ul>
        <li>Actividades ilegales, fraude o spam.</li>
        <li>Infringir derechos de propiedad intelectual de terceros.</li>
        <li>Interferir con la seguridad: malware, sondeo de vulnerabilidades, scraping o ataques.</li>
        <li>Generar contenido ilegal, deepfakes engañosos, discurso de odio, acoso, contenido sexual con menores o código malicioso.</li>
        <li>Intentar evadir los filtros o salvaguardas del modelo ("jailbreaking").</li>
      </ul>

      <h2>5. Contenido generado por IA</h2>
      <ul>
        <li>Usted es responsable de sus instrucciones (prompts), de los archivos que sube y de tener los derechos necesarios sobre ellos.</li>
        <li>Usted es responsable de cómo usa los resultados y de verificar su exactitud.</li>
        <li>Los resultados pueden ser inexactos o incompletos y no sustituyen asesoría profesional (legal, médica, financiera) sin supervisión humana.</li>
        <li>En la medida que lo permita la ley, usted conserva los derechos sobre sus entradas y los resultados generados. Nos otorga una licencia limitada para alojar y procesar su contenido únicamente para prestar el Servicio.</li>
        <li>Los titulares de derechos pueden reportar infracciones escribiendo al contacto indicado abajo; retiraremos el contenido infractor y podremos suspender cuentas con infracciones repetidas.</li>
        <li>Podemos eliminar o restringir contenido, filtrar o rechazar resultados y suspender cuentas que incumplan estos términos.</li>
      </ul>

      <h2>6. Propiedad intelectual</h2>
      <p>Gilma Reyes conserva la propiedad del Servicio y de toda su propiedad intelectual, incluido el software, la documentación y la marca "Orión Estellar".</p>

      <h2>7. Nivel de servicio</h2>
      <p>No garantizamos que el Servicio funcione de forma ininterrumpida o libre de errores. El Servicio se ofrece "tal cual", sin garantías implícitas de comerciabilidad o idoneidad para un fin particular, en la máxima medida permitida por la ley.</p>

      <h2>8. Pagos</h2>
      <p>Nuestro proceso de pedidos es realizado por nuestro revendedor en línea Paddle.com. Paddle.com es el Comerciante Registrado (Merchant of Record) de todos nuestros pedidos. Paddle brinda la atención al cliente relacionada con pagos y gestiona las devoluciones. Los pagos, facturación, impuestos, cancelaciones y reembolsos se rigen por los <a href="https://www.paddle.com/legal/checkout-buyer-terms" target="_blank" rel="noopener noreferrer">Términos del Comprador de Paddle</a> y nuestra <a href="/refund">Política de Reembolsos</a>.</p>

      <h2>9. Suspensión y terminación</h2>
      <p>Podemos suspender o terminar su acceso por incumplimiento grave de estos términos, falta de pago, riesgo de seguridad o fraude, o violaciones repetidas o graves de las políticas. Al terminar, sus datos podrán eliminarse tras un periodo razonable.</p>

      <h2>10. Responsabilidad</h2>
      <p>No seremos responsables por daños indirectos, consecuentes o especiales (pérdida de beneficios, datos o reputación). Nuestra responsabilidad total se limita a lo que usted haya pagado en los 12 meses anteriores, salvo en casos de fraude, muerte o lesiones personales donde la ley no permita limitarla.</p>

      <h2>11. Ley aplicable</h2>
      <p>Estos términos se rigen por las leyes de El Salvador. Cualquier controversia se someterá a los tribunales competentes de dicho país.</p>

      <h2>12. Contacto</h2>
      <p>Para consultas sobre estos términos, contacte a Gilma Reyes en linkyteam989@gmail.com.</p>
    </LegalPage>
  );
}
