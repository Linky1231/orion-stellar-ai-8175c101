import { resolvePaddlePrice } from "@/lib/payments.functions";

const clientToken = import.meta.env.VITE_PAYMENTS_CLIENT_TOKEN as string | undefined;

declare global {
  interface Window {
    Paddle: any;
  }
}

export function getPaddleEnvironment(): "sandbox" | "live" {
  return clientToken?.startsWith("test_") ? "sandbox" : "live";
}

let ready: Promise<void> | null = null;

export function initializePaddle(onComplete?: () => void) {
  if (ready) return ready;
  if (!clientToken) throw new Error("VITE_PAYMENTS_CLIENT_TOKEN is not set");
  ready = new Promise<void>((resolve, reject) => {
    const script = document.createElement("script");
    script.src = "https://cdn.paddle.com/paddle/v2/paddle.js";
    script.onload = () => {
      window.Paddle.Environment.set(getPaddleEnvironment() === "sandbox" ? "sandbox" : "production");
      window.Paddle.Initialize({
        token: clientToken,
        eventCallback: (e: any) => {
          if (e?.name === "checkout.completed") onComplete?.();
        },
      });
      resolve();
    };
    script.onerror = reject;
    document.head.appendChild(script);
  });
  return ready;
}

export async function getPaddlePriceId(priceId: string) {
  return resolvePaddlePrice({ data: { priceId, environment: getPaddleEnvironment() } });
}
