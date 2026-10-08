import "server-only";
import { randomInt } from "node:crypto";
import { loadCatalog, menuItem, round2, unitPrice, type LineInput } from "./catalog";
import { MODIFIERS } from "./content";
import { createOrder, getOrder, OrderError, type Fulfillment, type Order } from "./orders";
import { firestore, firestoreConfigured } from "./store/firestore";

/**
 * Group orders: friends share a code, each adds their own dishes, the host sends ONE order to the
 * kitchen and the app tells everyone what they owe (each their own, or split equally).
 * No online payment (out of scope in the PRD): people pay at the counter / table.
 * Stored in our own Firestore collection `group_orders/{code}` (in memory when running offline).
 */

const COLLECTION = process.env.FIRESTORE_GROUPS_COLLECTION?.trim() || "group_orders";
const MAX_MEMBERS = 12;
const MAX_QTY = 20;
const CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O/1/I
const TTL_MS = 6 * 60 * 60_000;

export type SplitMode = "by_item" | "equal";

export interface GroupMember {
  id: string;
  name: string;
  items: LineInput[];
  paid: boolean;
  joinedAt: string;
}

export interface Group {
  code: string;
  hostId: string;
  status: "open" | "placed";
  split: SplitMode;
  fulfillment: Fulfillment;
  tableNumber: string | null;
  members: GroupMember[];
  orderId: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface GroupView extends Group {
  bill: {
    total: number;
    perMember: { id: string; name: string; subtotal: number; owes: number; paid: boolean }[];
  };
  order: { id: string; order_number: number; status: Order["status"] } | null;
}

// ---- storage ---------------------------------------------------------------------

const memory = new Map<string, Group>();

async function load(code: string): Promise<Group | null> {
  if (!/^[A-Z2-9]{4}$/.test(code)) return null;
  if (!firestoreConfigured()) return memory.get(code) ?? null;
  const snap = await firestore().collection(COLLECTION).doc(code).get();
  return snap.exists ? (snap.data() as Group) : null;
}

/** Read-modify-write; `change` may throw OrderError to reject. */
async function update(code: string, change: (g: Group) => Group): Promise<Group> {
  if (!firestoreConfigured()) {
    const g = memory.get(code);
    if (!g) throw new OrderError("not_found", "group not found");
    const next = { ...change(structuredClone(g)), updatedAt: new Date().toISOString() };
    memory.set(code, next);
    return next;
  }
  const db = firestore();
  const ref = db.collection(COLLECTION).doc(code);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new OrderError("not_found", "group not found");
    const next = { ...change(snap.data() as Group), updatedAt: new Date().toISOString() };
    tx.set(ref, next);
    return next;
  });
}

async function insert(g: Group): Promise<boolean> {
  if (!firestoreConfigured()) {
    if (memory.has(g.code)) return false;
    memory.set(g.code, g);
    return true;
  }
  try {
    await firestore().collection(COLLECTION).doc(g.code).create(g);
    return true;
  } catch {
    return false; // code already taken
  }
}

// ---- operations ------------------------------------------------------------------

function cleanName(v: unknown) {
  return typeof v === "string" ? v.replace(/\s+/g, " ").trim().slice(0, 40) : "";
}

function member(g: Group, id: string) {
  return g.members.find((m) => m.id === id);
}

function requireOpen(g: Group) {
  if (g.status !== "open") throw new OrderError("bad_transition", "This group order was already sent to the kitchen.");
}

export async function createGroup(hostId: string, hostName: string): Promise<GroupView> {
  const name = cleanName(hostName);
  if (!hostId || !name) throw new OrderError("invalid", "customerId and name are required");
  const now = new Date().toISOString();
  for (let attempt = 0; attempt < 8; attempt++) {
    const code = Array.from({ length: 4 }, () => CODE_CHARS[randomInt(CODE_CHARS.length)]).join("");
    const g: Group = {
      code,
      hostId,
      status: "open",
      split: "by_item",
      fulfillment: "for_here",
      tableNumber: null,
      members: [{ id: hostId, name, items: [], paid: false, joinedAt: now }],
      orderId: null,
      createdAt: now,
      updatedAt: now,
    };
    if (await insert(g)) return view(g);
  }
  throw new OrderError("upstream", "Could not create a group code, please try again.");
}

export async function getGroup(code: string): Promise<GroupView | null> {
  const g = await load(code);
  if (!g || Date.now() - Date.parse(g.createdAt) > TTL_MS) return null;
  return view(g);
}

export async function joinGroup(code: string, id: string, rawName: string): Promise<GroupView> {
  const name = cleanName(rawName);
  if (!id || !name) throw new OrderError("invalid", "customerId and name are required");
  return view(
    await update(code, (g) => {
      if (member(g, id)) return g; // already in: joining twice is harmless
      requireOpen(g);
      if (g.members.length >= MAX_MEMBERS) throw new OrderError("invalid", `Groups are limited to ${MAX_MEMBERS} people.`);
      g.members.push({ id, name, items: [], paid: false, joinedAt: new Date().toISOString() });
      return g;
    }),
  );
}

/** Replaces this member's own dishes. Only real menu dishes; stock is checked when the host sends the order. */
export async function setMyItems(code: string, id: string, items: unknown): Promise<GroupView> {
  const catalog = await loadCatalog();
  const clean: LineInput[] = [];
  for (const raw of Array.isArray(items) ? items.slice(0, 30) : []) {
    const it = raw as Partial<LineInput>;
    const m = typeof it?.menuItemId === "string" ? menuItem(catalog, it.menuItemId) : undefined;
    const qty = Math.floor(Number(it?.quantity));
    if (!m || m.active === false || !(qty >= 1)) continue;
    const mods = [...new Set(Array.isArray(it.modifiers) ? it.modifiers : [])].filter((x) => m.modifierIds.includes(x) && MODIFIERS[x]).sort();
    const same = clean.find((c) => c.menuItemId === m.id && c.modifiers.join() === mods.join());
    if (same) same.quantity = Math.min(MAX_QTY, same.quantity + qty);
    else clean.push({ menuItemId: m.id, quantity: Math.min(MAX_QTY, qty), modifiers: mods });
  }
  return view(
    await update(code, (g) => {
      requireOpen(g);
      const me = member(g, id);
      if (!me) throw new OrderError("invalid", "Join the group first.");
      me.items = clean;
      return g;
    }),
  );
}

/** Host-only settings: how to split, to go / for here, table. */
export async function setOptions(code: string, id: string, opts: { split?: unknown; fulfillment?: unknown; tableNumber?: unknown }) {
  return view(
    await update(code, (g) => {
      if (g.hostId !== id) throw new OrderError("invalid", "Only the host can change this.");
      if (opts.split === "by_item" || opts.split === "equal") g.split = opts.split;
      if (g.status === "open") {
        if (opts.fulfillment === "to_go" || opts.fulfillment === "for_here") g.fulfillment = opts.fulfillment;
        if (typeof opts.tableNumber === "string" || opts.tableNumber === null)
          g.tableNumber = (opts.tableNumber ?? "").replace(/[^\w-]/g, "").slice(0, 8) || null;
      }
      return g;
    }),
  );
}

/** Host marks someone as paid (at the counter / table) or not. */
export async function setPaid(code: string, hostId: string, memberId: string, paid: boolean) {
  return view(
    await update(code, (g) => {
      if (g.hostId !== hostId) throw new OrderError("invalid", "Only the host can change this.");
      const m = member(g, memberId);
      if (!m) throw new OrderError("not_found", "member not found");
      m.paid = paid;
      return g;
    }),
  );
}

/** Host sends everyone's dishes to the kitchen as ONE order. */
export async function placeGroup(code: string, hostId: string): Promise<GroupView> {
  const g = await load(code);
  if (!g) throw new OrderError("not_found", "group not found");
  if (g.hostId !== hostId) throw new OrderError("invalid", "Only the host can send the order.");
  requireOpen(g);
  const merged: LineInput[] = [];
  for (const m of g.members)
    for (const it of m.items) {
      const same = merged.find((x) => x.menuItemId === it.menuItemId && x.modifiers.join() === it.modifiers.join());
      if (same) same.quantity += it.quantity;
      else merged.push({ ...it, modifiers: [...it.modifiers] });
    }
  if (!merged.length) throw new OrderError("invalid", "Nobody has added a dish yet.");
  for (const line of merged) if (line.quantity > MAX_QTY) throw new OrderError("invalid", "Too many of one dish for a single order (max 20).");

  const host = member(g, hostId)!;
  const people = g.members.filter((m) => m.items.length).length;
  // Claim the group first so a double tap can't send two orders.
  await update(code, (cur) => {
    requireOpen(cur);
    cur.status = "placed";
    return cur;
  });
  try {
    const order = await createOrder({
      customerId: hostId,
      customerName: `${host.name} · group of ${Math.max(people, g.members.length)}`.slice(0, 40),
      fulfillment: g.fulfillment,
      tableNumber: g.tableNumber,
      items: merged,
    });
    return view(await update(code, (cur) => ({ ...cur, orderId: order.id })));
  } catch (err) {
    await update(code, (cur) => ({ ...cur, status: "open" })); // let them fix it and retry
    throw err;
  }
}

// ---- bill --------------------------------------------------------------------------

async function view(g: Group): Promise<GroupView> {
  const catalog = await loadCatalog();
  const subtotals = g.members.map((m) =>
    round2(
      m.items.reduce((s, it) => {
        const row = menuItem(catalog, it.menuItemId);
        return s + (row ? unitPrice(row, it.modifiers) * it.quantity : 0);
      }, 0),
    ),
  );
  const total = round2(subtotals.reduce((a, b) => a + b, 0));
  // Equal split in cents; the first people absorb the leftover cents so it adds up exactly.
  const cents = Math.round(total * 100);
  const n = g.members.length;
  const equal = g.members.map((_, i) => (Math.floor(cents / n) + (i < cents % n ? 1 : 0)) / 100);

  let order: GroupView["order"] = null;
  if (g.orderId) {
    const o = await getOrder(g.orderId).catch(() => null);
    order = o ? { id: o.id, order_number: o.order_number, status: o.status } : { id: g.orderId, order_number: 0, status: "RECEIVED" };
  }
  return {
    ...g,
    bill: {
      total,
      perMember: g.members.map((m, i) => ({
        id: m.id,
        name: m.name,
        subtotal: subtotals[i],
        owes: g.split === "equal" ? equal[i] : subtotals[i],
        paid: m.paid,
      })),
    },
    order,
  };
}
