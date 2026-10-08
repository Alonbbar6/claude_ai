#!/usr/bin/env node
// A tiny stand-in for the BarMade API (same routes and JSON shapes, checked
// against https://barmade-riw5.onrender.com on 2026-10-08) so the iPhone apps
// can be tried in the Simulator without placing real orders on the team's
// kitchen. In-memory only; restart to reset.
//
//   node ios/scripts/barmade-stub.mjs            # http://127.0.0.1:8787
//   PORT=9000 node ios/scripts/barmade-stub.mjs

import { createServer } from "node:http";

const PORT = Number(process.env.PORT) || 8787;

const inventory = [
  ing("ING-001", "Tomato Sauce", "Sauces", "ml", 10000, [["TS-001", 5000, "2026-10-10"], ["TS-002", 12000, "2026-10-14"]]),
  ing("ING-002", "Mozzarella Cheese", "Dairy", "g", 5000, [["MZ-001", 3500, "2026-10-08"], ["MZ-002", 8000, "2026-10-12"]]),
  ing("ING-003", "Pizza Dough", "Bakery", "units", 10, [["PD-001", 3, "2026-10-09"]]),
  ing("ING-004", "Pepperoni", "Meat", "slices", 200, [["PP-001", 400, "2026-10-20"]]),
  ing("ING-005", "Pasta (Spaghetti)", "Dry goods", "g", 2000, [["PA-001", 6000, "2027-01-01"]]),
  ing("ING-006", "Alfredo Sauce", "Sauces", "ml", 2000, [["AS-001", 4000, "2026-10-11"]]),
  ing("ING-007", "Parmesan Cheese", "Dairy", "g", 500, [["PM-001", 1200, "2026-11-01"]]),
  ing("ING-008", "Olive Oil", "Pantry", "ml", 1000, [["OO-001", 3000, "2027-03-01"]]),
  ing("ING-009", "Chicken", "Meat", "g", 2000, [["CH-001", 5000, "2026-10-09"]]),
  ing("ING-010", "Garlic", "Produce", "g", 200, [["GA-001", 600, "2026-10-20"]]),
  ing("ING-011", "Basil", "Produce", "g", 100, [["BA-001", 250, "2026-10-09"]]),
  ing("ING-012", "Coca-Cola", "Beverages", "cans", 24, [["CC-001", 48, "2027-06-01"]]),
];

const menu = [
  dish("MENU-001", "Margherita Pizza", 15.99, [["ING-003", 1], ["ING-001", 200], ["ING-002", 150], ["ING-011", 5], ["ING-008", 10]]),
  dish("MENU-002", "Pepperoni Pizza", 17.99, [["ING-003", 1], ["ING-001", 200], ["ING-002", 150], ["ING-004", 30]]),
  dish("MENU-003", "Chicken Alfredo", 21.99, [["ING-005", 150], ["ING-006", 200], ["ING-009", 180], ["ING-007", 20], ["ING-010", 5]]),
  dish("MENU-004", "Spaghetti Marinara", 14.99, [["ING-005", 150], ["ING-001", 250], ["ING-010", 5], ["ING-011", 3], ["ING-008", 10]]),
  dish("MENU-005", "Coca-Cola", 2.99, [["ING-012", 1]]),
];

const orders = [
  {
    id: "ORD-001", status: "COMPLETED", createdAt: "2026-10-06T12:15:00",
    items: [{ menuItemId: "MENU-001", name: "Margherita Pizza", quantity: 2, unitPrice: 15.99, lineTotal: 31.98 }],
    total: 31.98, consumed: [],
  },
];
let seq = orders.length;
const alerts = [];

const NEXT = { RECEIVED: ["PREPARING", "CANCELLED"], PREPARING: ["READY", "CANCELLED"], READY: ["COMPLETED"], COMPLETED: [], CANCELLED: [] };

function ing(id, name, category, unit, reorderPoint, batches) {
  return {
    id, name, category, unit, reorderPoint,
    batches: batches.map(([batchId, quantity, exp]) => ({ batchId, quantity, arrivedAt: "2026-10-03T08:00:00", expiresAt: `${exp}T23:59:59`, status: "FRESH" })),
  };
}
function dish(id, name, price, lines) {
  return {
    id, name, price,
    ingredients: lines.map(([ingredientId, quantity]) => {
      const i = inventory.find((x) => x.id === ingredientId);
      return { ingredientId, quantity, ingredientName: i.name, unit: i.unit };
    }),
  };
}
const usable = (i) => i.batches.reduce((s, b) => s + b.quantity, 0);
function inventoryView(i) {
  const totalQuantity = usable(i);
  return {
    ...i, totalQuantity, expiredQuantity: 0,
    status: totalQuantity <= 0 ? "OUT_OF_STOCK" : totalQuantity <= i.reorderPoint ? "LOW_STOCK" : "IN_STOCK",
  };
}

function placeOrder(body) {
  const lines = Array.isArray(body.items) ? body.items : [];
  if (!lines.length) throw [400, "VALIDATION_ERROR", "items is empty"];
  const need = new Map();
  const items = lines.map((l) => {
    const m = menu.find((x) => x.id === l.menuItemId);
    const qty = Math.floor(Number(l.quantity));
    if (!m || !(qty >= 1)) throw [400, "VALIDATION_ERROR", `bad line ${l.menuItemId}`];
    for (const r of m.ingredients) need.set(r.ingredientId, (need.get(r.ingredientId) ?? 0) + r.quantity * qty);
    return { menuItemId: m.id, item_id: m.id, name: m.name, quantity: qty, modifiers: [], unitPrice: m.price, lineTotal: round2(m.price * qty) };
  });
  for (const [id, q] of need) {
    const i = inventory.find((x) => x.id === id);
    if (usable(i) < q) throw [409, "INSUFFICIENT_STOCK", `Not enough ${i.name}`];
  }
  const consumed = [];
  for (const [id, q] of need) {
    const i = inventory.find((x) => x.id === id);
    let left = q;
    const batches = [];
    for (const b of i.batches) {
      if (left <= 0) break;
      const take = Math.min(b.quantity, left);
      b.quantity -= take;
      left -= take;
      if (take > 0) batches.push({ batchId: b.batchId, quantity: take });
    }
    consumed.push({ ingredientId: id, ingredientName: i.name, unit: i.unit, quantity: q, batches });
  }
  const now = new Date().toISOString();
  const total = round2(items.reduce((s, i) => s + i.lineTotal, 0));
  const order = {
    id: `ORD-${String(++seq).padStart(3, "0")}`, status: "RECEIVED", channel: "barmade",
    placed_at: now, business_date: now.slice(0, 10), createdAt: now, items, total, gross_total: total,
    channel_fee_rate: 0.05, channel_fee: round2(total * 0.05), net_total: round2(total * 0.95), consumed,
    source: typeof body.source === "string" ? body.source : null,
    fulfillment: body.fulfillment === "for_here" ? "for_here" : "to_go",
    tableNumber: typeof body.tableNumber === "string" ? body.tableNumber : null,
    customerName: typeof body.customerName === "string" ? body.customerName : null,
    orderNumber: 1000 + seq, updatedAt: now, statusHistory: [{ status: "RECEIVED", at: now }],
  };
  orders.unshift(order);
  return order;
}

function setStatus(id, status) {
  const o = orders.find((x) => x.id === id);
  if (!o) throw [404, "NOT_FOUND", `Order ${id} not found`];
  if (!NEXT[o.status]?.includes(status)) throw [409, "INVALID_TRANSITION", `Cannot go from ${o.status} to ${status}`];
  const at = new Date().toISOString();
  o.status = status;
  o.updatedAt = at;
  (o.statusHistory ??= []).push({ status, at });
  if (status === "CANCELLED") for (const c of o.consumed) for (const b of c.batches) {
    const batch = inventory.find((i) => i.id === c.ingredientId).batches.find((x) => x.batchId === b.batchId);
    if (batch) batch.quantity += b.quantity;
  }
  return o;
}

const round2 = (n) => Math.round(n * 100) / 100;

createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const path = url.pathname.replace(/\/+$/, "");
  const send = (code, body) => {
    res.writeHead(code, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
    res.end(JSON.stringify(body));
  };
  const ok = (data) => send(200, Array.isArray(data) ? { count: data.length, data } : { data });
  try {
    let body = {};
    if (req.method === "POST" || req.method === "PATCH") {
      let raw = "";
      for await (const chunk of req) raw += chunk;
      body = raw ? JSON.parse(raw) : {};
    }
    const m = (re) => path.match(re);
    if (req.method === "GET" && path === "") return ok({ name: "BarMade API (stub)", status: "ok" });
    if (req.method === "GET" && path === "/api/menu") return ok(menu);
    if (req.method === "GET" && path === "/api/inventory") return ok(inventory.map(inventoryView));
    if (req.method === "GET" && path === "/api/alerts") return ok(alerts);
    if (req.method === "GET" && path === "/api/orders") return ok(orders);
    if (req.method === "POST" && path === "/api/orders") return send(201, { data: placeOrder(body) });
    let hit;
    if (req.method === "GET" && (hit = m(/^\/api\/orders\/([^/]+)$/))) {
      const o = orders.find((x) => x.id === hit[1]);
      return o ? ok(o) : send(404, { error: { code: "NOT_FOUND", message: `Order ${hit[1]} not found` } });
    }
    if (req.method === "PATCH" && (hit = m(/^\/api\/orders\/([^/]+)\/status$/))) return ok(setStatus(hit[1], body.status));
    send(404, { error: { code: "ROUTE_NOT_FOUND", message: path } });
  } catch (e) {
    if (Array.isArray(e)) return send(e[0], { error: { code: e[1], message: e[2] } });
    send(500, { error: { code: "INTERNAL", message: String(e) } });
  }
}).listen(PORT, () => console.log(`BarMade stub listening on http://127.0.0.1:${PORT}`));
