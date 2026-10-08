import "server-only";
import { firestore, firestoreConfigured } from "./store/firestore";

/**
 * The team's BarMade backend (Express + Firestore on Render) owns the restaurant:
 * menu, recipes, batch inventory, orders and their status. When BARMADE_API_URL is set:
 *  - orders are created with POST {BARMADE_API_URL}/api/orders (it computes consumption,
 *    deducts inventory FIFO by batch and records the movement),
 *  - menu + stock are read live (Firestore read-only when credentials exist, else the API),
 *  - order status is read from the backend; transitions are validated there.
 */

const STATE = process.env.BARMADE_STATE_PATH?.trim() || "barmade/state";
// Firestore free tier allows ~50k reads/day for the whole team: cache live reads.
const LIVE_TTL_MS = 15_000;
const WARMUP_EVERY_MS = 4 * 60_000;

export function barmadeApiUrl(): string | null {
  return process.env.BARMADE_API_URL?.trim().replace(/\/$/, "") || null;
}

export function barmadeMode() {
  return barmadeApiUrl() !== null;
}

export class BarmadeError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public details?: unknown,
  ) {
    super(message);
  }
}

export interface LiveMenuItem {
  id: string;
  name: string;
  price: number;
  ingredients: { ingredientId: string; quantity: number }[];
  category?: string;
}

export interface LiveInventoryItem {
  id: string;
  name: string;
  unit: string;
  reorderPoint?: number;
  batches: { batchId?: string; quantity: number; expiresAt?: string }[];
}

export interface LiveOrder {
  id: string;
  status: string;
  createdAt?: string;
  items: { menuItemId: string; name: string; quantity: number; unitPrice: number; lineTotal: number }[];
  total: number;
  consumed?: { ingredientId: string; quantity: number }[];
  [extra: string]: unknown;
}

// ---- HTTP --------------------------------------------------------------------

async function call<T>(method: "GET" | "POST", path: string, body?: unknown, timeoutMs = 60_000): Promise<T> {
  const base = barmadeApiUrl();
  if (!base) throw new BarmadeError(500, "NOT_CONFIGURED", "BARMADE_API_URL is not set");
  const res = await fetch(base + path, {
    method,
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    // Render's free tier can take ~50 s to wake up.
    signal: AbortSignal.timeout(timeoutMs),
    cache: "no-store",
  });
  const json = (await res.json().catch(() => ({}))) as { data?: T; error?: { code?: string; message?: string; details?: unknown } };
  if (!res.ok) {
    throw new BarmadeError(
      res.status,
      json.error?.code ?? "HTTP_ERROR",
      json.error?.message ?? `BarMade API returned ${res.status}`,
      json.error?.details,
    );
  }
  return (json.data ?? json) as T;
}

let lastWarmup = 0;
/** Fire-and-forget ping so the Render service is awake before someone orders. */
export function warmup() {
  if (!barmadeMode() || Date.now() - lastWarmup < WARMUP_EVERY_MS) return;
  lastWarmup = Date.now();
  call("GET", "/api/menu", undefined, 70_000).catch(() => {
    lastWarmup = 0;
  });
}

// ---- Live menu + inventory ------------------------------------------------------

let liveCache: { at: number; value: { menu: LiveMenuItem[]; inventory: LiveInventoryItem[] } } | null = null;
let lastGood: { menu: LiveMenuItem[]; inventory: LiveInventoryItem[] } | null = null;
// After a failure (e.g. quota exhausted, where the SDK retries for ~8 s) skip the backend for a minute.
let failedUntil = 0;

/** Live menu + inventory; on errors (e.g. quota) serves the last good copy if there is one. */
export async function readLive(): Promise<{ menu: LiveMenuItem[]; inventory: LiveInventoryItem[] }> {
  if (liveCache && Date.now() - liveCache.at < LIVE_TTL_MS) return liveCache.value;
  if (Date.now() < failedUntil && !lastGood) throw new BarmadeError(503, "BACKEND_UNAVAILABLE", "BarMade backend recently failed");
  try {
    const value = await fetchLive();
    lastGood = value;
    liveCache = { at: Date.now(), value };
    warmup();
    return value;
  } catch (err) {
    failedUntil = Date.now() + 60_000;
    if (!lastGood) throw err;
    console.error("BarMade live read failed, serving last good copy", err instanceof Error ? err.message : err);
    liveCache = { at: Date.now(), value: lastGood }; // don't hammer a failing backend
    return lastGood;
  }
}

async function fetchLive(): Promise<{ menu: LiveMenuItem[]; inventory: LiveInventoryItem[] }> {
  let value: { menu: LiveMenuItem[]; inventory: LiveInventoryItem[] };
  if (firestoreConfigured()) {
    const db = firestore();
    const [menu, inventory] = await Promise.all([
      db.collection(`${STATE}/menu`).get(),
      db.collection(`${STATE}/inventory`).get(),
    ]);
    value = {
      menu: menu.docs.map((d) => ({ id: d.id, ...d.data() }) as LiveMenuItem),
      inventory: inventory.docs.map((d) => ({ id: d.id, ...d.data() }) as LiveInventoryItem),
    };
  } else {
    const [menu, inventory] = await Promise.all([
      call<LiveMenuItem[]>("GET", "/api/menu"),
      call<LiveInventoryItem[]>("GET", "/api/inventory"),
    ]);
    value = { menu, inventory };
  }
  return value;
}

/** Usable stock per ingredient: sum of non-expired batches. */
export function liveStock(inventory: LiveInventoryItem[], now = Date.now()): Map<string, number> {
  return new Map(
    inventory.map((i) => [
      i.id,
      (i.batches ?? [])
        .filter((b) => !b.expiresAt || Date.parse(b.expiresAt) > now)
        .reduce((s, b) => s + Number(b.quantity || 0), 0),
    ]),
  );
}

// ---- Orders ---------------------------------------------------------------------

export async function createRemoteOrder(body: Record<string, unknown>): Promise<LiveOrder> {
  const order = await call<LiveOrder>("POST", "/api/orders", body);
  liveCache = null; // stock just changed
  return order;
}

export async function getRemoteOrder(id: string): Promise<LiveOrder | null> {
  if (!id || id.includes("/")) return null;
  if (firestoreConfigured()) {
    const snap = await firestore().collection(`${STATE}/orders`).doc(id).get();
    return snap.exists ? ({ id: snap.id, ...snap.data() } as LiveOrder) : null;
  }
  try {
    return await call<LiveOrder>("GET", `/api/orders/${encodeURIComponent(id)}`);
  } catch (err) {
    if (err instanceof BarmadeError && err.status === 404) return null;
    throw err;
  }
}

export async function getRemoteOrders(ids: string[]): Promise<Map<string, LiveOrder>> {
  const out = new Map<string, LiveOrder>();
  if (!ids.length) return out;
  if (firestoreConfigured()) {
    const col = firestore().collection(`${STATE}/orders`);
    const snaps = await firestore().getAll(...ids.map((id) => col.doc(id)));
    for (const s of snaps) if (s.exists) out.set(s.id, { id: s.id, ...s.data() } as LiveOrder);
    return out;
  }
  await Promise.all(ids.map(async (id) => {
    const o = await getRemoteOrder(id);
    if (o) out.set(id, o);
  }));
  return out;
}

/** Backend timestamps may come without a zone ("2026-10-06T12:15:00"); they are UTC. */
export function utcIso(v: unknown): string | undefined {
  if (typeof v !== "string" || !v) return undefined;
  return /[zZ]|[+-]\d\d:?\d\d$/.test(v) ? new Date(v).toISOString() : new Date(v + "Z").toISOString();
}
