import "../src/styles.css";
import { createRoot } from "react-dom/client";
import { Loader2 } from "lucide-react";
import { ChatApp } from "@/components/orion/ChatApp";
import { AuthScreen } from "@/components/orion/AuthScreen";
import { AuthProvider, useAuth } from "@/lib/auth";

// The Builda build is static: send Orión's server calls to the published app.
const API_ORIGIN = "https://orion-stellar-ai.lovable.app";
const nativeFetch = window.fetch.bind(window);
window.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
  if (typeof input === "string" && input.startsWith("/api/")) input = API_ORIGIN + input;
  return nativeFetch(input, init);
};

function Gate() {
  const { user, loading } = useAuth();
  if (loading)
    return (
      <div className="min-h-screen flex items-center justify-center">
        <Loader2 className="w-6 h-6 animate-spin text-primary" />
      </div>
    );
  return user ? <ChatApp key={user.id} /> : <AuthScreen />;
}

createRoot(document.getElementById("root")!).render(
  <AuthProvider>
    <Gate />
  </AuthProvider>,
);
