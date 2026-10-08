#!/usr/bin/env node
// Synthetic training / evaluation dataset for BarMade's inventory forecasting
// (run-out, expiry, restock) and the kitchen ready-time model.
//
// Deterministic (seeded) simulation of one restaurant over N days, using the
// team's own catalog (customer-web/data/barmade: 30 ingredients with
// suppliers, pack sizes, delivery days and shelf life; 17 recipes), so ids,
// units and shapes match the live BarMade API.
//
//   node datasets/barmade-forecast/generate.mjs                # 180 days, seed 42 -> out/
//   node datasets/barmade-forecast/generate.mjs --days 365 --seed 7 --out /tmp/ds
//
// Nothing here is real: no customers, no production records.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const args = Object.fromEntries(process.argv.slice(2).map((a, i, all) => (a.startsWith("--") ? [a.slice(2), all[i + 1]] : [])).filter((x) => x.length));
const DAYS = Number(args.days ?? 180);
const SEED = Number(args.seed ?? 42);
const OUT = resolve(args.out ?? join(here, "out"));
const CATALOG = resolve(args.catalog ?? join(here, "../../customer-web/data/barmade"));
const START = new Date(Date.UTC(2026, 3, 10, 0, 0, 0)); // 2026-04-10, so 180 days ends 2026-10-06
const TZ_OFFSET_H = -4; // America/New_York (EDT) for business_date and hours

// ---- deterministic randomness ------------------------------------------------

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rnd = mulberry32(SEED);
const uniform = (a, b) => a + (b - a) * rnd();
const normal = (mu = 0, sd = 1) => {
  const u = 1 - rnd(), v = rnd();
  return mu + sd * Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
};
const exponential = (mean) => -Math.log(1 - rnd()) * mean;
const poisson = (lambda) => {
  const L = Math.exp(-lambda);
  let k = 0, p = 1;
  do { k++; p *= rnd(); } while (p > L);
  return k - 1;
};
const pick = (weights) => {
  const total = weights.reduce((s, [, w]) => s + w, 0);
  let r = rnd() * total;
  for (const [v, w] of weights) { r -= w; if (r <= 0) return v; }
  return weights[weights.length - 1][0];
};
const round2 = (n) => Math.round(n * 100) / 100;
const r1 = (n) => Math.round(n * 10) / 10;

// ---- catalog --------------------------------------------------------------------

const inventoryIn = JSON.parse(readFileSync(join(CATALOG, "inventory.json"), "utf8"));
const menuIn = JSON.parse(readFileSync(join(CATALOG, "menu.json"), "utf8"));

const ingredients = inventoryIn.map((i) => ({
  id: i.id, name: i.name, category: i.category, unit: i.unit, kind: i.kind ?? "purchased",
  minimum_stock: i.reorderPoint,
  batch_prefix: i.batchPrefix ?? i.id.replace("ING-", "B"),
  supplier: i.supplier ?? "Local Market",
  pack_size: i.packSize ?? i.reorderPoint,
  pack_label: i.packLabel ?? `${i.reorderPoint} ${i.unit}`,
  delivery_days: i.deliveryDays ?? [1, 4], // 0 = Sunday
  shelf_life_days: i.shelfLifeDays ?? 30,
  target_days: i.targetDays ?? 7,
  lead_time_days: i.leadTimeDays ?? (i.supplier ? 2 : 1),
}));
const ING = new Map(ingredients.map((i) => [i.id, i]));
const menu = menuIn.filter((m) => m.active !== false).map((m) => ({ ...m, modifierIds: m.modifierIds ?? [] }));
const MENU = new Map(menu.map((m) => [m.id, m]));

// Popularity: pizzas and pastas sell most; drinks attach to orders.
const POPULARITY = { Pizza: 5, Pasta: 4, Entree: 2.5, Sandwich: 2, Salad: 1.5, Appetizer: 2, Dessert: 1.5, Beverage: 0.5 };
const food = menu.filter((m) => m.category !== "Beverage");
const drinks = menu.filter((m) => m.category === "Beverage");
const CHANNELS = [["barmade", 35], ["dine_in", 25], ["takeout", 15], ["website", 10], ["doordash", 8], ["uber_eats", 7]];
const FEE = { barmade: 0.05, website: 0.029, doordash: 0.25, uber_eats: 0.3, dine_in: 0, takeout: 0 };
const MODIFIERS = { extra_cheese: 2, no_cheese: 0, add_chicken: 5 };

/// Same prep-time prior as the iOS ReadyTimeModel, so its calibration can be measured here.
const prepPrior = (m) => {
  const drinkUnits = ["can", "cans", "bottle", "bottles", "glass"];
  if (m.ingredients.length && m.ingredients.every((l) => drinkUnits.includes(ING.get(l.ingredientId)?.unit?.toLowerCase()))) return 1;
  return Math.min(25, 8 + 1.5 * m.ingredients.length);
};
const isRush = (h) => (h >= 11 && h <= 13) || (h >= 18 && h <= 20);

/// Ingredient usage for one serving, with the same modifier math as the web app.
function recipeFor(m, mods) {
  const use = new Map(m.ingredients.map((l) => [l.ingredientId, l.quantity]));
  if (mods.includes("no_cheese")) use.delete("ING-002");
  else if (mods.includes("extra_cheese") && use.has("ING-002")) use.set("ING-002", use.get("ING-002") * 1.5);
  if (mods.includes("add_chicken")) use.set("ING-009", (use.get("ING-009") ?? 0) + 120);
  return use;
}

// ---- time helpers ---------------------------------------------------------------

const dayStartUTC = (d) => new Date(START.getTime() + d * 86400_000 - TZ_OFFSET_H * 3600_000); // local midnight in UTC
const businessDate = (d) => new Date(START.getTime() + d * 86400_000).toISOString().slice(0, 10);
const localHour = (t) => ((t.getUTCHours() + TZ_OFFSET_H) % 24 + 24) % 24;
const weekdayOf = (d) => new Date(START.getTime() + d * 86400_000).getUTCDay();
const iso = (t) => t.toISOString();

// ---- scenario -------------------------------------------------------------------

const stories = {
  festival: { day: Math.floor(DAYS * 0.55), orders_multiplier: 2.3, note: "Little Italy street festival" },
  storm: { day: Math.floor(DAYS * 0.3), orders_multiplier: 0.35, note: "Tropical storm, most people stayed home" },
  // A slower cook for three weeks: a learning ready-time model should notice.
  slow_kitchen: { from: Math.floor(DAYS * 0.65), to: Math.floor(DAYS * 0.65) + 21, factor: 1.3 },
  // The manager forgets to order on these days: run-outs follow.
  forgot_to_order: [],
  short_shipments: [],
};

const BASE_ORDERS = { 0: 85, 1: 68, 2: 66, 3: 70, 4: 76, 5: 98, 6: 112 }; // by weekday

function ordersForDay(d) {
  let n = BASE_ORDERS[weekdayOf(d)] * (1 + 0.0008 * d); // slow growth
  if (d === stories.festival.day) n *= stories.festival.orders_multiplier;
  if (d === stories.storm.day) n *= stories.storm.orders_multiplier;
  return poisson(n * uniform(0.9, 1.1));
}

// ---- state ----------------------------------------------------------------------

const batches = []; // {batch_id, ingredient_id, quantity, quantity_in, arrived_at, expires_at, consumed, wasted}
const movements = [];
const orders = [];
const kitchenRows = [];
const dailyRows = [];
const daily = []; // per day per ingredient aggregates
let batchSeq = Object.fromEntries(ingredients.map((i) => [i.id, 0]));
let movSeq = 0;
let orderSeq = 0;
// Daily *demand* (sale + prep + what couldn't be made), for the manager's naive forecast:
// a real manager notices empty shelves and orders more, not less.
const demandHistory = new Map(ingredients.map((i) => [i.id, []]));

/// Expected daily usage per ingredient from the menu mix, for opening stock and
/// the first order before there is any history.
function expectedDailyUsage() {
  const perOrder = new Map(ingredients.map((i) => [i.id, 0]));
  const N = 2000;
  for (let k = 0; k < N; k++) {
    for (const { m, qty, mods } of drawLines()) {
      for (const [ing, q] of recipeFor(m, mods)) perOrder.set(ing, perOrder.get(ing) + q * qty);
    }
  }
  const meanOrders = Object.values(BASE_ORDERS).reduce((a, b) => a + b, 0) / 7;
  return new Map([...perOrder].map(([id, q]) => [id, (q / N) * meanOrders]));
}

/// What one order contains (food lines + maybe a drink).
function drawLines() {
  const lines = [];
  const nFood = pick([[1, 45], [2, 35], [3, 15], [4, 5]]);
  for (let k = 0; k < nFood; k++) {
    const m = pick(food.map((x) => [x, POPULARITY[x.category] ?? 1]));
    const mods = [];
    if (m.modifierIds.includes("extra_cheese") && rnd() < 0.15) mods.push("extra_cheese");
    else if (m.modifierIds.includes("no_cheese") && rnd() < 0.03) mods.push("no_cheese");
    if (m.modifierIds.includes("add_chicken") && rnd() < 0.1) mods.push("add_chicken");
    lines.push({ m, qty: rnd() < 0.85 ? 1 : 2, mods });
  }
  if (rnd() < 0.5) lines.push({ m: pick(drinks.map((x) => [x, 1])), qty: pick([[1, 70], [2, 30]]), mods: [] });
  return lines;
}

/// Days from `weekday` to the next delivery weekday (1..7).
function daysToNextDelivery(i, weekday) {
  for (let g = 1; g <= 7; g++) if (i.delivery_days.includes((weekday + g) % 7)) return g;
  return 7;
}

const stock = (ingId, at) =>
  batches.filter((b) => b.ingredient_id === ingId && b.quantity > 0 && b.expires_at > at).reduce((s, b) => s + b.quantity, 0);

function move(ingId, change, reason, at, extra = {}) {
  const i = ING.get(ingId);
  movements.push({
    id: `MOV-${String(++movSeq).padStart(6, "0")}`, ingredient_id: ingId, ingredient: i.name, change: r1(change), unit: i.unit,
    reason, order_id: extra.order_id ?? "", batch_id: extra.batch_id ?? "", timestamp: iso(at), business_date: businessDate(extra.day),
    balance_after: r1(stock(ingId, at)), note: extra.note ?? "",
  });
}

function deliver(ingId, packs, day, note) {
  const i = ING.get(ingId);
  const at = new Date(dayStartUTC(day).getTime() + 8 * 3600_000); // 08:00 local
  const qty = packs * i.pack_size;
  const id = `${i.batch_prefix}-${String(++batchSeq[ingId]).padStart(3, "0")}`;
  const expires = new Date(dayStartUTC(day + i.shelf_life_days).getTime() + (23 * 3600 + 59 * 60 + 59) * 1000);
  batches.push({ batch_id: id, ingredient_id: ingId, quantity: qty, quantity_in: qty, arrived_at: iso(at), expires_at: expires, consumed: 0, wasted: 0 });
  move(ingId, qty, "delivery", at, { batch_id: id, day, note });
  return qty;
}

/// FIFO by expiry, skipping expired batches. Returns the batch uses, or null if short.
function consume(ingId, qty, at, reason, order_id, day) {
  const usable = batches.filter((b) => b.ingredient_id === ingId && b.quantity > 0 && b.expires_at > at).sort((a, b) => a.expires_at - b.expires_at);
  if (usable.reduce((s, b) => s + b.quantity, 0) < qty - 1e-9) return null;
  let left = qty;
  const uses = [];
  for (const b of usable) {
    if (left <= 0) break;
    const take = Math.min(b.quantity, left);
    b.quantity -= take; b.consumed += take; left -= take;
    uses.push({ batchId: b.batch_id, quantity: r1(take) });
  }
  move(ingId, -qty, reason, at, { order_id, day });
  return uses;
}

// Opening stock: about a week of expected usage per ingredient.
const EXPECTED = expectedDailyUsage();
for (const i of ingredients) {
  deliver(i.id, Math.max(1, Math.ceil((EXPECTED.get(i.id) * 7 + i.minimum_stock * 0.5) / i.pack_size)), 0, "opening stock");
}

// ---- simulate -------------------------------------------------------------------

let openTickets = []; // {ready_at}
const kitchenFactor = (d) => (d >= stories.slow_kitchen.from && d < stories.slow_kitchen.to ? stories.slow_kitchen.factor : 1.0);

for (let d = 0; d < DAYS; d++) {
  const weekday = weekdayOf(d);
  const dayStart = dayStartUTC(d);
  const opening = new Map(ingredients.map((i) => [i.id, stock(i.id, dayStart)]));
  const delivered = new Map(ingredients.map((i) => [i.id, 0]));
  const saleUse = new Map(ingredients.map((i) => [i.id, 0]));
  const prepUse = new Map(ingredients.map((i) => [i.id, 0]));
  const waste = new Map(ingredients.map((i) => [i.id, 0]));
  const lostDemand = new Map(ingredients.map((i) => [i.id, 0]));
  let lostSales = 0, revenue = 0, nOrders = 0;

  // 1. Expired batches are discarded at opening.
  for (const b of batches) {
    if (b.quantity > 0 && b.expires_at <= dayStart) {
      waste.set(b.ingredient_id, waste.get(b.ingredient_id) + b.quantity);
      b.wasted += b.quantity;
      move(b.ingredient_id, -b.quantity, "waste", dayStart, { batch_id: b.batch_id, day: d, note: "expired" });
      b.quantity = 0;
    }
  }

  // 2. Deliveries: on each supplier's delivery day the manager tops up to cover the gap
  //    to the next delivery (plus lead time and a day of safety) from a naive 7-day
  //    average of demand — sometimes forgetting, sometimes short-shipped. Perishables
  //    are never ordered beyond their shelf life.
  for (const i of ingredients) {
    if (!i.delivery_days.includes(weekday) || d === 0) continue;
    const hist = demandHistory.get(i.id).slice(-7);
    const avg = hist.length ? hist.reduce((a, b) => a + b, 0) / hist.length : EXPECTED.get(i.id);
    const have = stock(i.id, dayStart);
    const cover = Math.min(i.shelf_life_days, daysToNextDelivery(i, weekday) + i.lead_time_days + 1);
    const need = avg * cover + i.minimum_stock * 0.5 - have;
    if (need <= 0) continue;
    if (rnd() < 0.06) { stories.forgot_to_order.push({ date: businessDate(d), ingredient_id: i.id }); continue; }
    let packs = Math.ceil(need / i.pack_size);
    let note = "";
    if (rnd() < 0.04) { packs = Math.max(1, Math.floor(packs / 2)); note = "short-shipped"; stories.short_shipments.push({ date: businessDate(d), ingredient_id: i.id }); }
    delivered.set(i.id, delivered.get(i.id) + deliver(i.id, packs, d, note));
  }

  // 3. Prep usage (sauces, dough made from flour, etc.): a small daily draw.
  for (const i of ingredients) {
    if (!["Sauces", "Dairy", "Bakery", "Produce"].includes(i.category)) continue;
    const q = r1(i.minimum_stock * uniform(0.005, 0.02));
    const at = new Date(dayStart.getTime() + 9 * 3600_000);
    if (consume(i.id, q, at, "prep_usage", "", d)) prepUse.set(i.id, prepUse.get(i.id) + q);
  }

  // 4. Orders through the day.
  const n = ordersForDay(d);
  const times = Array.from({ length: n }, () => {
    const period = pick([["lunch", 40], ["dinner", 50], ["other", 10]]);
    const h = period === "lunch" ? uniform(11, 14.5) : period === "dinner" ? uniform(17, 21.5) : uniform(14.5, 17);
    return new Date(dayStart.getTime() + h * 3600_000);
  }).sort((a, b) => a - b);

  for (const placedAt of times) {
    const id = `ORD-${String(++orderSeq).padStart(6, "0")}`;
    const channel = pick(CHANNELS);
    const lines = drawLines();

    // Stock check per line: what the kitchen can't make is a lost sale (and demand the manager sees).
    const items = [], consumed = [];
    let total = 0;
    for (const { m, qty, mods } of lines) {
      const need = recipeFor(m, mods);
      const ok = [...need].every(([ing, q]) => stock(ing, placedAt) >= q * qty);
      const price = round2(m.price + mods.reduce((s, x) => s + (MODIFIERS[x] ?? 0), 0));
      if (!ok) {
        lostSales += price * qty;
        for (const [ing, q] of need) lostDemand.set(ing, lostDemand.get(ing) + q * qty);
        continue;
      }
      for (const [ing, q] of need) {
        const uses = consume(ing, q * qty, placedAt, "sale", id, d);
        saleUse.set(ing, saleUse.get(ing) + q * qty);
        const i = ING.get(ing);
        consumed.push({ ingredientId: ing, ingredientName: i.name, unit: i.unit, quantity: r1(q * qty), batches: uses });
      }
      items.push({ menuItemId: m.id, item_id: m.key, name: m.name, quantity: qty, modifiers: mods, unitPrice: price, lineTotal: round2(price * qty) });
      total = round2(total + price * qty);
    }
    if (!items.length) continue;
    nOrders++; revenue += total;

    // Kitchen timing: the same generative process the old server's model was trained on,
    // scaled by how this kitchen is running (slow-cook period), plus forgotten tickets.
    openTickets = openTickets.filter((t) => t.ready_at > placedAt);
    const busy = openTickets.length;
    const hour = localHour(placedAt);
    const prep = Math.max(...items.map((it) => prepPrior(MENU.get(it.menuItemId))));
    const itemCount = items.reduce((s, it) => s + it.quantity, 0);
    const base = prep <= 3
      ? prep + 0.5 * (itemCount - 1)
      : prep + 1.2 * itemCount + 1.8 * busy + (isRush(hour) ? 2 : 0) + (weekday === 0 || weekday === 6 ? 1 : 0);
    let readyMin = Math.max(prep <= 3 ? 0.5 : 4, (base + normal(0, 1.5) + exponential(1.5)) * kitchenFactor(d));
    const forgotten = rnd() < 0.02;
    const cancelled = rnd() < 0.02;
    const prepMin = Math.min(readyMin * 0.4, uniform(0.5, 4));
    const readyAt = new Date(placedAt.getTime() + readyMin * 60_000);
    openTickets.push({ ready_at: readyAt });
    const recordedReadyMin = forgotten ? readyMin + uniform(45, 180) : readyMin;
    const completedMin = recordedReadyMin + uniform(0.5, 12);
    const history = [{ status: "RECEIVED", at: iso(placedAt) }];
    let status = "COMPLETED";
    if (cancelled) {
      status = "CANCELLED";
      history.push({ status: "CANCELLED", at: iso(new Date(placedAt.getTime() + uniform(0.5, 6) * 60_000)) });
      // Stock goes back.
      for (const c of consumed) for (const u of c.batches) {
        const b = batches.find((x) => x.batch_id === u.batchId);
        if (b) { b.quantity += u.quantity; b.consumed -= u.quantity; }
        saleUse.set(c.ingredientId, saleUse.get(c.ingredientId) - u.quantity);
      }
      for (const c of consumed) move(c.ingredientId, c.quantity, "cancel", new Date(placedAt.getTime() + 60_000), { order_id: id, day: d });
    } else {
      history.push({ status: "PREPARING", at: iso(new Date(placedAt.getTime() + prepMin * 60_000)) });
      history.push({ status: "READY", at: iso(new Date(placedAt.getTime() + recordedReadyMin * 60_000)) });
      history.push({ status: "COMPLETED", at: iso(new Date(placedAt.getTime() + completedMin * 60_000)) });
    }
    const fee = round2(total * FEE[channel]);
    orders.push({
      id, status, channel, source: channel === "barmade" ? (rnd() < 0.7 ? "barmade-web" : "barmade-ios") : null,
      fulfillment: channel === "dine_in" ? "for_here" : "to_go",
      tableNumber: channel === "dine_in" ? String(1 + Math.floor(rnd() * 20)) : null,
      customerName: null, orderNumber: 1000 + orderSeq,
      placed_at: iso(placedAt), business_date: businessDate(d), createdAt: iso(placedAt),
      items, total, gross_total: total, channel_fee_rate: FEE[channel], channel_fee: fee, net_total: round2(total - fee),
      consumed: cancelled ? [] : consumed, statusHistory: history,
      updatedAt: history[history.length - 1].at,
    });
    kitchenRows.push({
      order_id: id, placed_at: iso(placedAt), business_date: businessDate(d), hour, weekday, is_rush: isRush(hour) ? 1 : 0,
      is_weekend: weekday === 0 || weekday === 6 ? 1 : 0, item_count: itemCount, prep_prior_min: prep, busy_open_tickets: busy,
      kitchen_factor: kitchenFactor(d), minutes_to_preparing: cancelled ? "" : r1(prepMin),
      minutes_to_ready: cancelled ? "" : r1(recordedReadyMin), true_minutes_to_ready: cancelled ? "" : r1(readyMin),
      forgotten: forgotten ? 1 : 0, cancelled: cancelled ? 1 : 0,
    });
  }

  // 5. Random spoilage of perishables (dropped tray, fridge left open).
  for (const i of ingredients) {
    if (!["Dairy", "Meat", "Produce"].includes(i.category) || rnd() > 0.03) continue;
    const q = r1(stock(i.id, dayStart) * uniform(0.05, 0.2));
    const at = new Date(dayStart.getTime() + 22 * 3600_000);
    if (q > 0 && consume(i.id, q, at, "waste", "", d)) waste.set(i.id, waste.get(i.id) + q);
  }

  // 6. Day summary rows.
  const dayEnd = new Date(dayStart.getTime() + 86400_000 - 1000);
  for (const i of ingredients) {
    demandHistory.get(i.id).push(saleUse.get(i.id) + prepUse.get(i.id) + lostDemand.get(i.id));
    daily.push({
      day: d, date: businessDate(d), weekday, ingredient_id: i.id, ingredient: i.name, unit: i.unit, category: i.category,
      supplier: i.supplier, pack_size: i.pack_size, lead_time_days: i.lead_time_days, shelf_life_days: i.shelf_life_days,
      minimum_stock: i.minimum_stock,
      opening_stock: r1(opening.get(i.id)), delivered: r1(delivered.get(i.id)), usage_sale: r1(saleUse.get(i.id)),
      usage_prep: r1(prepUse.get(i.id)), waste: r1(waste.get(i.id)), closing_stock: r1(stock(i.id, dayEnd)),
      expiring_within_7d_qty: r1(batches.filter((b) => b.ingredient_id === i.id && b.quantity > 0 && b.expires_at > dayEnd
        && b.expires_at <= new Date(dayEnd.getTime() + 7 * 86400_000)).reduce((s, b) => s + b.quantity, 0)),
      lost_demand: r1(lostDemand.get(i.id)),
      is_festival: d === stories.festival.day ? 1 : 0, is_storm: d === stories.storm.day ? 1 : 0,
    });
  }
  dailyRows.push({ date: businessDate(d), weekday, orders: nOrders, revenue: round2(revenue), lost_sales: round2(lostSales),
    is_festival: d === stories.festival.day ? 1 : 0, is_storm: d === stories.storm.day ? 1 : 0 });
}

// ---- labels (need the future) ----------------------------------------------------

const byIng = new Map();
for (const row of daily) (byIng.get(row.ingredient_id) ?? byIng.set(row.ingredient_id, []).get(row.ingredient_id)).push(row);
const lostByDay = new Map(dailyRows.map((r) => [r.date, r.lost_sales]));
for (const rows of byIng.values()) {
  for (let k = 0; k < rows.length; k++) {
    const r = rows[k];
    const past = rows.slice(Math.max(0, k - 13), k + 1).map((x) => x.usage_sale + x.usage_prep);
    const past7 = past.slice(-7);
    r.avg_usage_7d = r1(past7.reduce((a, b) => a + b, 0) / past7.length);
    r.avg_usage_14d = r1(past.reduce((a, b) => a + b, 0) / past.length);
    const next = rows.slice(k + 1, k + 8);
    r.usage_next_7d = next.length === 7 ? r1(next.reduce((s, x) => s + x.usage_sale + x.usage_prep, 0)) : "";
    r.waste_next_7d = next.length === 7 ? r1(next.reduce((s, x) => s + x.waste, 0)) : "";
    // Days until the closing stock would hit zero at the actual future usage, with no further deliveries.
    let left = r.closing_stock, days = 0, ran = false;
    for (let j = k + 1; j < rows.length && days < 30; j++) {
      left -= rows[j].usage_sale + rows[j].usage_prep + rows[j].waste;
      days++;
      if (left <= 0) { ran = true; break; }
    }
    r.days_to_runout = ran ? days : rows.length - k - 1 < 30 ? "" : "30+";
    r.runout_within_7d = r.days_to_runout === "" ? "" : ran && days <= 7 ? 1 : 0;
    r.stockout_today = r.closing_stock <= 0 ? 1 : 0;
  }
}
// Stockout attribution per ingredient per day: lost sales exist on days when any ingredient was out.
for (const r of daily) r.lost_sales_day = lostByDay.get(r.date);

// ---- write ----------------------------------------------------------------------

mkdirSync(OUT, { recursive: true });
const csv = (rows) => {
  const cols = Object.keys(rows[0]);
  const esc = (v) => (typeof v === "string" && /[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v);
  return [cols.join(","), ...rows.map((r) => cols.map((c) => esc(r[c] ?? "")).join(","))].join("\n") + "\n";
};
const trainEnd = businessDate(Math.floor(DAYS * 0.7) - 1), valEnd = businessDate(Math.floor(DAYS * 0.85) - 1);
const splits = {
  by: "business_date",
  train: { from: businessDate(0), to: trainEnd },
  val: { from: businessDate(Math.floor(DAYS * 0.7)), to: valEnd },
  test: { from: businessDate(Math.floor(DAYS * 0.85)), to: businessDate(DAYS - 1) },
};

writeFileSync(join(OUT, "ingredients.json"), JSON.stringify(ingredients, null, 1));
writeFileSync(join(OUT, "menu.json"), JSON.stringify(menu, null, 1));
writeFileSync(join(OUT, "orders.json"), JSON.stringify(orders));
writeFileSync(join(OUT, "movements.csv"), csv(movements));
writeFileSync(join(OUT, "batches.csv"), csv(batches.map((b) => ({
  batch_id: b.batch_id, ingredient_id: b.ingredient_id, quantity_in: r1(b.quantity_in), consumed: r1(b.consumed), wasted: r1(b.wasted),
  remaining: r1(b.quantity), arrived_at: b.arrived_at, expires_at: iso(b.expires_at),
}))));
writeFileSync(join(OUT, "inventory_daily.csv"), csv(daily));
writeFileSync(join(OUT, "kitchen_times.csv"), csv(kitchenRows));
writeFileSync(join(OUT, "daily_sales.csv"), csv(dailyRows));
writeFileSync(join(OUT, "splits.json"), JSON.stringify(splits, null, 2));
writeFileSync(join(OUT, "metadata.json"), JSON.stringify({
  synthetic: true, generator: "datasets/barmade-forecast/generate.mjs", seed: SEED, days: DAYS, timezone: "America/New_York",
  start_date: businessDate(0), end_date: businessDate(DAYS - 1), catalog: CATALOG, stories,
  counts: { ingredients: ingredients.length, menu: menu.length, orders: orders.length, movements: movements.length, batches: batches.length,
    inventory_daily: daily.length, kitchen_times: kitchenRows.length,
    runout_days: daily.filter((r) => r.stockout_today).length, lost_sales_total: round2(dailyRows.reduce((s, r) => s + r.lost_sales, 0)) },
}, null, 2));

console.log(`Wrote ${OUT}`);
console.log(`  ${orders.length} orders, ${movements.length} movements, ${batches.length} batches, ${daily.length} ingredient-days, ${kitchenRows.length} kitchen timings`);
console.log(`  stock-out ingredient-days: ${daily.filter((r) => r.stockout_today).length}, lost sales $${round2(dailyRows.reduce((s, r) => s + r.lost_sales, 0))}`);
console.log(`  splits: train ${splits.train.from}..${splits.train.to} | val ..${splits.val.to} | test ..${splits.test.to}`);
