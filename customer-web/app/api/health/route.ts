import { json } from "@/lib/http";
import { store } from "@/lib/store";
import { barmadeMode } from "@/lib/barmade";

export const dynamic = "force-dynamic";

export async function GET() {
  try {
    await store().ping();
    return json({
      ok: true,
      db: store().kind,
      orders: barmadeMode() ? "barmade-api" : "local",
      ai: Boolean(process.env.ANTHROPIC_API_KEY),
    });
  } catch (err) {
    console.error("health check failed", err);
    return json({ ok: false, db: store().kind, error: "database unavailable" }, 503);
  }
}
