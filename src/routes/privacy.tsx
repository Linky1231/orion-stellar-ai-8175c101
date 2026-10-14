import { createFileRoute } from "@tanstack/react-router";
import { LegalPage } from "@/components/orion/LegalPage";

const URL = "https://orion-stellar-ai.lovable.app/privacy";

export const Route = createFileRoute("/privacy")({
  head: () => ({
    meta: [
      { title: "Aviso de Privacidad — Orión Estellar" },
      { name: "description", content: "Cómo Gilma Reyes recopila, usa y protege tus datos personales en Orión Estellar." },
      { property: "og:title", content: "Aviso de Privacidad — Orión Estellar" },
      { property: "og:description", content: "Información sobre el tratamiento de datos personales en Orión Estellar." },
      { property: "og:type", content: "article" },
      { property: "og:url", content: URL },
      { name: "twitter:card", content: "summary" },
    ],
    links: [{ rel: "canonical", href: URL }],
  }),
  component: Privacy,
});

function Privacy() {
  return (
    <LegalPage title="Aviso de Privacidad" updated="14 de octubre de 2026">
      <h2>1. Responsable del tratamiento</h2>
      <p><b>Gilma Reyes</b> es la responsable (controladora) de los datos personales tratados a través de Orión Estellar y decide sus fines y medios. Contacto: linkyteam989@gmail.com.</p>

      <h2>2. Datos que recopilamos y para qué</h2>
      <ul>
        <li><b>Datos de cuenta</b> (nombre, correo, identificador de Google): crear y administrar tu cuenta. Base legal: ejecución del contrato.</li>
        <li><b>Contenido</b> (mensajes, notas, memoria, imágenes, videos y documentos que subes o generas): prestar el Servicio. Base legal: ejecución del contrato.</li>
        <li><b>Datos técnicos y de uso</b> (dirección IP, identificadores de dispositivo, navegador, registros de errores): seguridad, prevención de fraude y mejora del producto. Base legal: interés legítimo.</li>
        <li><b>Mensajes de soporte</b>: atender tus consultas. Base legal: ejecución del contrato e interés legítimo.</li>
        <li><b>Comunicaciones de marketing</b>, solo si las aceptas. Base legal: consentimiento.</li>
      </ul>

      <h2>3. Con quién compartimos datos</h2>
      <ul>
        <li><b>Proveedores de servicios</b>: alojamiento y base de datos, proveedores de modelos de IA que procesan tus mensajes para generar respuestas, y almacenamiento de archivos (por ejemplo, Microsoft OneDrive cuando creas documentos).</li>
        <li><b>Paddle</b>, como Comerciante Registrado, para la venta del producto, pagos, cumplimiento fiscal y facturación.</li>
        <li><b>Asesores profesionales</b> (legales y contables).</li>
        <li><b>Autoridades</b>, cuando la ley lo exija.</li>
      </ul>
      <p>No vendemos tus datos personales.</p>

      <h2>4. Transferencias internacionales</h2>
      <p>Algunos proveedores procesan datos fuera de tu país. Cuando aplica, usamos salvaguardas adecuadas como cláusulas contractuales tipo.</p>

      <h2>5. Conservación</h2>
      <p>Conservamos los datos mientras tu cuenta esté activa o sea necesario para prestar el Servicio y cumplir obligaciones legales. Después se eliminan o anonimizan.</p>

      <h2>6. Tus derechos</h2>
      <p>Puedes solicitar acceso, rectificación, eliminación, limitación, portabilidad u oposición al tratamiento, y retirar tu consentimiento en cualquier momento. También puedes presentar una queja ante la autoridad de protección de datos competente. Responderemos en un plazo máximo de un mes escribiendo a linkyteam989@gmail.com.</p>

      <h2>7. Seguridad</h2>
      <p>Aplicamos medidas técnicas y organizativas adecuadas, como cifrado en tránsito, controles de acceso y separación de datos por usuario.</p>

      <h2>8. Cookies y almacenamiento local</h2>
      <p>Usamos únicamente almacenamiento esencial para mantener tu sesión iniciada y tus preferencias. No usamos cookies de publicidad. Puedes borrarlos desde la configuración de tu navegador, aunque tendrás que volver a iniciar sesión.</p>
    </LegalPage>
  );
}
