export type PaddleEnv = "sandbox" | "live";

export function gatewayFetch(env: PaddleEnv, path: string, init: RequestInit = {}) {
  const lk = process.env["LOVABLE_API_KEY"];
  const pk = env === "sandbox" ? process.env["PADDLE_SANDBOX_API_KEY"] : process.env["PADDLE_LIVE_API_KEY"];
  if (!lk || !pk) throw new Error("Pagos no configurados");
  return fetch(`https://connector-gateway.lovable.dev/paddle${path}`, {
    ...init,
    headers: {
      "Lovable-API-Key": lk,
      "X-Connection-Api-Key": pk,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
}
