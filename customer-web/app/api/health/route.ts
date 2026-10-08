import { json } from "@/lib/http";
import { store } from "@/lib/store";
import { barmadeMode } from "@/lib/barmade";
import { aiProvider } from "@/lib/ai";

export const dynamic = "force-dynamic";

export async function GET() {
  try {
    await store().ping();
    return json({
      ok: true,
      db: store().kind,
      orders: barmadeMode() ? "barmade-api" : "local",
      ai: aiProvider() ?? false,
    });
  } catch (err) {
    console.error("health check failed", err);
    return json({ ok: false, db: store().kind, error: "database unavailable" }, 503);
  }
}
