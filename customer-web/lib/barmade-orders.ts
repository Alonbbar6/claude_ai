import "server-only";
import { BarmadeError, createRemoteOrder, getRemoteOrder, getRemoteOrders, utcIso, type LiveOrder } from "./barmade";
import { round2 } from "./catalog";
import { TRATTORIA_ID } from "./content";
import { firestore, firestoreConfigured } from "./store/firestore";
import { OrderError, type Fulfillment, type Order, type OrderStatus } from "./orders";

/**
 * Orders in BarMade mode. The backend is the source of truth (items, totals, consumption, status).
 * The customer-facing details it may not store yet (name, to go / for here, table) are also kept in
 * our own collection `customer_app_orders/{orderId}` and merged when reading.
 */

const META = process.env.FIRESTORE_ORDER_META_COLLECTION?.trim() || "customer_app_orders";

interface Meta {
  id: string;
  customer_id: string | null;
  customer_name: string;
  fulfillment: Fulfillment;
  table_number: string | null;
  channel: "barmade";
  source: "barmade-web";
  placed_at: string;
  business_date: string;
  channel_fee_rate: number;
}

// Fallback when Firestore isn't configured (local dev against the API only).
const memoryMeta = new Map<string, Meta>();

async function saveMeta(m: Meta) {
  if (firestoreConfigured()) await firestore().collection(META).doc(m.id).set(m);
  else memoryMeta.set(m.id, m);
}

async function loadMeta(id: string): Promise<Meta | null> {
  if (!firestoreConfigured()) return memoryMeta.get(id) ?? null;
  const snap = await firestore().collection(META).doc(id).get();
  return snap.exists ? (snap.data() as Meta) : null;
}

export interface BarmadeOrderInput {
  customerId: string | null;
  customerName: string;
  fulfillment: Fulfillment;
  tableNumber: string | null;
  items: Order["items"];
  channelFeeRate: number;
  placedAt: Date;
  businessDate: string;
}

export async function createBarmadeOrder(input: BarmadeOrderInput): Promise<Order> {
  let remote: LiveOrder;
  try {
    remote = await createRemoteOrder({
      items: input.items.map((i) => ({ menuItemId: i.menuItemId, quantity: i.quantity })),
      // Extra fields for the merchant ticket; the backend may store or ignore them.
      channel: "barmade",
      source: "barmade-web",
      fulfillment: input.fulfillment,
      tableNumber: input.tableNumber,
      customerName: input.customerName,
      customerId: input.customerId,
    });
  } catch (err) {
    if (err instanceof BarmadeError && err.status === 409) {
      const names = input.items.map((i) => i.name);
      throw new OrderError("sold_out", err.message, soldOutNames(err.details, input.items) ?? names);
    }
    if (err instanceof BarmadeError && err.status >= 400 && err.status < 500)
      throw new OrderError("invalid", err.message, err.details);
    console.error("BarMade API order failed", err);
    throw new OrderError("upstream", "The restaurant system didn't answer. Please try again.");
  }

  const meta: Meta = {
    id: remote.id,
    customer_id: input.customerId,
    customer_name: input.customerName,
    fulfillment: input.fulfillment,
    table_number: input.tableNumber,
    channel: "barmade",
    source: "barmade-web",
    placed_at: utcIso(remote.createdAt) ?? input.placedAt.toISOString(),
    business_date: input.businessDate,
    channel_fee_rate: input.channelFeeRate,
  };
  try {
    await saveMeta(meta);
  } catch (err) {
    // The order exists in the backend; losing the extra details must not fail the customer.
    console.error("could not save customer-app order details", err);
    memoryMeta.set(meta.id, meta);
  }
  return toOrder(remote, meta);
}

export async function getBarmadeOrder(id: string): Promise<Order | null> {
  const [remote, meta] = await Promise.all([getRemoteOrder(id), loadMeta(id).catch(() => memoryMeta.get(id) ?? null)]);
  return remote ? toOrder(remote, meta) : null;
}

export async function listBarmadeOrders(opts: { since?: string; customerId?: string; limit: number }): Promise<Order[]> {
  let metas: Meta[];
  if (firestoreConfigured()) {
    const col = firestore().collection(META);
    const snap = opts.customerId
      ? await col.where("customer_id", "==", opts.customerId).get()
      : await col.orderBy("placed_at", "desc").limit(opts.limit).get();
    metas = snap.docs.map((d) => d.data() as Meta);
  } else {
    metas = [...memoryMeta.values()].filter((m) => !opts.customerId || m.customer_id === opts.customerId);
  }
  metas.sort((a, b) => (a.placed_at < b.placed_at ? 1 : -1));
  metas = metas.slice(0, opts.limit);
  const remote = await getRemoteOrders(metas.map((m) => m.id));
  return metas
    .filter((m) => remote.has(m.id))
    .map((m) => toOrder(remote.get(m.id)!, m))
    .filter((o) => !opts.since || o.updated_at > opts.since);
}

const STATUS_MAP: Record<string, OrderStatus> = {
  RECEIVED: "RECEIVED",
  PENDING: "RECEIVED",
  NEW: "RECEIVED",
  PLACED: "RECEIVED",
  CONFIRMED: "RECEIVED",
  PREPARING: "PREPARING",
  IN_PROGRESS: "PREPARING",
  PREPARE: "PREPARING",
  READY: "READY",
  COMPLETED: "COMPLETED",
  PICKED_UP: "COMPLETED",
  DELIVERED: "COMPLETED",
  SERVED: "COMPLETED",
  CANCELLED: "CANCELLED",
  CANCELED: "CANCELLED",
};

function toOrder(r: LiveOrder, meta: Meta | null): Order {
  const status = STATUS_MAP[String(r.status ?? "RECEIVED").toUpperCase()] ?? "RECEIVED";
  const placedAt = meta?.placed_at ?? utcIso(r.createdAt) ?? new Date().toISOString();
  const updatedAt = utcIso(r.updatedAt) ?? utcIso(r.updated_at) ?? placedAt;
  const history = (r.statusHistory ?? r.status_history) as { status: string; at: string }[] | undefined;
  const total = Number(r.total ?? 0);
  const rate = meta?.channel_fee_rate ?? 0.05;
  const fee = round2(total * rate);
  const str = (v: unknown) => (typeof v === "string" && v ? v : null);
  return {
    id: r.id,
    order_number: Number(String(r.id).match(/\d+/g)?.join("") ?? 0),
    restaurant_id: TRATTORIA_ID,
    status,
    channel: "barmade",
    source: "barmade-web",
    fulfillment: meta?.fulfillment ?? ((r.fulfillment as Fulfillment) || "to_go"),
    table_number: meta?.table_number ?? str(r.tableNumber),
    customer_id: meta?.customer_id ?? str(r.customerId),
    customer_name: meta?.customer_name ?? str(r.customerName) ?? "",
    placed_at: placedAt,
    business_date: meta?.business_date ?? placedAt.slice(0, 10),
    items: (r.items ?? []).map((i) => ({
      menuItemId: i.menuItemId,
      item_id: i.menuItemId,
      name: i.name,
      quantity: Number(i.quantity),
      modifiers: [],
      unitPrice: Number(i.unitPrice),
      lineTotal: Number(i.lineTotal),
    })),
    total,
    gross_total: total,
    channel_fee_rate: rate,
    channel_fee: fee,
    net_total: round2(total - fee),
    consumed: (r.consumed ?? []).map((c) => ({ ingredientId: c.ingredientId, quantity: Number(c.quantity) })),
    status_history: history?.length
      ? history.map((h) => ({ status: STATUS_MAP[String(h.status).toUpperCase()] ?? "RECEIVED", at: utcIso(h.at) ?? placedAt }))
      : [
          { status: "RECEIVED", at: placedAt },
          ...(status !== "RECEIVED" ? [{ status, at: updatedAt }] : []),
        ],
    updated_at: updatedAt,
  };
}

function soldOutNames(details: unknown, items: Order["items"]): string[] | null {
  // Backend 409 details may name ingredients or menu items; map menu ids back to names when we can.
  const text = JSON.stringify(details ?? "");
  const hits = items.filter((i) => text.includes(i.menuItemId)).map((i) => i.name);
  return hits.length ? hits : null;
}
