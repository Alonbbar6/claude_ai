import "server-only";
import { cert, getApps, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import type { Customer } from "../customers";
import type { Order } from "../orders";
import type { ListOpts, Store } from "./types";

/**
 * Firestore backend (the team's database).
 * Credentials, in order: FIREBASE_SERVICE_ACCOUNT (JSON or base64 JSON) → GOOGLE_APPLICATION_CREDENTIALS
 * file → FIRESTORE_EMULATOR_HOST (local emulator, project from FIREBASE_PROJECT_ID).
 * Documents follow docs/handoff/orders-contract.md; timestamps are ISO strings like orders.json.
 */

const ORDERS = process.env.FIRESTORE_ORDERS_COLLECTION?.trim() || "orders";
const CUSTOMERS = process.env.FIRESTORE_CUSTOMERS_COLLECTION?.trim() || "customers";
const COUNTER = process.env.FIRESTORE_COUNTER_DOC?.trim() || "counters/barmade_order_number";

function serviceAccount(): Record<string, string> | null {
  const raw = process.env.FIREBASE_SERVICE_ACCOUNT?.trim();
  if (!raw) return null;
  const text = raw.startsWith("{") ? raw : Buffer.from(raw, "base64").toString("utf8");
  const sa = JSON.parse(text);
  // Env vars often store the key with literal "\n"
  if (typeof sa.private_key === "string") sa.private_key = sa.private_key.replace(/\\n/g, "\n");
  return sa;
}

let fs: Firestore | null = null;
export function firestore(): Firestore {
  if (fs) return fs;
  const existing = getApps().find((a) => a.name === "barmade-web");
  let app: App;
  if (existing) app = existing;
  else {
    const sa = serviceAccount();
    const projectId = process.env.FIREBASE_PROJECT_ID?.trim() || sa?.project_id;
    app = initializeApp(sa ? { credential: cert(sa), projectId } : { projectId }, "barmade-web");
  }
  fs = getFirestore(app);
  fs.settings({ ignoreUndefinedProperties: true });
  return fs;
}

export function firestoreConfigured() {
  return Boolean(
    process.env.FIREBASE_SERVICE_ACCOUNT?.trim() ||
      process.env.FIRESTORE_EMULATOR_HOST?.trim() ||
      (process.env.GOOGLE_APPLICATION_CREDENTIALS?.trim() && process.env.FIREBASE_PROJECT_ID?.trim()),
  );
}

const isApp = (o: Partial<Order>) => o.source === "barmade-web";
const byPlacedDesc = (a: Order, b: Order) => (a.placed_at < b.placed_at ? 1 : a.placed_at > b.placed_at ? -1 : 0);

// Menu availability reads every app order; keep it to one query per couple of seconds.
let consumedCache: { at: number; value: Map<string, number> } | null = null;

export const firestoreStore: Store = {
  kind: "firestore",

  async ping() {
    await firestore().doc(COUNTER).get();
  },

  async nextOrderNumber() {
    const db = firestore();
    const ref = db.doc(COUNTER);
    return db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const n = Number(snap.get("value") ?? 1000) + 1;
      tx.set(ref, { value: n, updated_at: new Date().toISOString() }, { merge: true });
      return n;
    });
  },

  async insertOrder(order) {
    await firestore().collection(ORDERS).doc(order.id).create(order);
    consumedCache = null;
    return order;
  },

  async getOrder(id) {
    if (!id || id.includes("/")) return null;
    const snap = await firestore().collection(ORDERS).doc(id).get();
    return snap.exists ? (snap.data() as Order) : null;
  },

  async listOrders({ since, customerId, limit }: ListOpts) {
    // Single-field queries only, so no composite indexes need to be created in the team's project.
    const col = firestore().collection(ORDERS);
    let docs: Order[];
    if (customerId) docs = (await col.where("customer_id", "==", customerId).get()).docs.map((d) => d.data() as Order);
    else if (since) docs = (await col.where("updated_at", ">", since).get()).docs.map((d) => d.data() as Order);
    else docs = (await col.orderBy("placed_at", "desc").limit(limit * 4).get()).docs.map((d) => d.data() as Order);
    return docs
      .filter(isApp)
      .filter((o) => !since || o.updated_at > since)
      .sort(byPlacedDesc)
      .slice(0, limit);
  },

  async updateOrder(id, next) {
    if (!id || id.includes("/")) return null;
    const db = firestore();
    const ref = db.collection(ORDERS).doc(id);
    const result = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) return null;
      const current = snap.data() as Order;
      const patch = next(current);
      if (!patch) return current;
      tx.update(ref, patch);
      return { ...current, ...patch };
    });
    consumedCache = null;
    return result;
  },

  async consumedByApp() {
    if (consumedCache && Date.now() - consumedCache.at < 2000) return consumedCache.value;
    const snap = await firestore().collection(ORDERS).where("source", "==", "barmade-web").get();
    const used = new Map<string, number>();
    for (const d of snap.docs) {
      const o = d.data() as Order;
      if (o.status === "CANCELLED") continue;
      for (const c of o.consumed ?? []) used.set(c.ingredientId, (used.get(c.ingredientId) ?? 0) + Number(c.quantity));
    }
    consumedCache = { at: Date.now(), value: used };
    return used;
  },

  async insertCustomer(c: Customer) {
    await firestore().collection(CUSTOMERS).doc(c.id).create(c);
    return c;
  },

  async getCustomer(id) {
    const snap = await firestore().collection(CUSTOMERS).doc(id).get();
    return snap.exists ? (snap.data() as Customer) : null;
  },

  async saveCustomer(c) {
    await firestore()
      .collection(CUSTOMERS)
      .doc(c.id)
      .set({ display_name: c.display_name, language: c.language, taste: c.taste }, { merge: true });
    return c;
  },
};
