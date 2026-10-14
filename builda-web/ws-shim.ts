// Builda's iOS webview forbids WebSockets; never let that crash the app (realtime is optional).
const Native = window.WebSocket;
class SafeWebSocket extends EventTarget {
  static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3;
  readyState = 3; url: string; protocol = ""; extensions = ""; bufferedAmount = 0; binaryType = "blob";
  onopen: any = null; onclose: any = null; onerror: any = null; onmessage: any = null;
  constructor(url: string | URL, protocols?: string | string[]) {
    super();
    this.url = String(url);
    try {
      return new (Native as any)(url, protocols);
    } catch {
      setTimeout(() => { this.onerror?.(new Event("error")); this.onclose?.({ code: 1006, reason: "blocked" }); }, 0);
    }
  }
  send() {}
  close() {}
}
try { (window as any).WebSocket = SafeWebSocket; } catch {}
export {};
