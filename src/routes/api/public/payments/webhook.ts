import { createFileRoute } from "@tanstack/react-router";
import { createHmac, timingSafeEqual } from "crypto";

function verify(body: string, header: string, secret: string | undefined) {
  if (!secret) return false;
  const parts = Object.fromEntries(header.split(";").map((p) => p.split("=") as [string, string]));
  const ts = parts["ts"];
  const h1 = parts["h1"];
  if (!ts || !h1) return false;
  const expected = createHmac("sha256", secret).update(`${ts}:${body}`).digest("hex");
  const a = Buffer.from(h1);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

export const Route = createFileRoute("/api/public/payments/webhook")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const body = await request.text();
        const sig = request.headers.get("paddle-signature") || "";
        let environment: "sandbox" | "live" | null = null;
        if (verify(body, sig, process.env["PAYMENTS_SANDBOX_WEBHOOK_SECRET"])) environment = "sandbox";
        else if (verify(body, sig, process.env["PAYMENTS_LIVE_WEBHOOK_SECRET"])) environment = "live";
        if (!environment) return new Response("Invalid signature", { status: 401 });

        const event: any = JSON.parse(body);
        if (event?.event_type === "transaction.completed" || event?.event_type === "transaction.paid") {
          const tx = event.data;
          const userId = tx?.custom_data?.userId;
          if (userId && typeof userId === "string") {
            const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
            await (supabaseAdmin.from("purchases" as any) as any).upsert(
              {
                user_id: userId,
                price_id: tx?.items?.[0]?.price?.import_meta?.external_id || tx?.items?.[0]?.price?.id || "orion_access_once",
                transaction_id: tx.id,
                environment,
                status: "paid",
              },
              { onConflict: "transaction_id" },
            );
          }
        }
        return new Response("ok");
      },
    },
  },
});
