import "server-only";
import { db, dbBackend } from "../db";
import { cleanTaste, type Customer } from "../customers";
import { isLang } from "../i18n";
import type { Order, OrderStatus, Fulfillment } from "../orders";
import type { ListOpts, Store } from "./types";

const ORDER_COLS = [
  "id", "order_number", "restaurant_id", "status", "channel", "source", "fulfillment", "table_number",
  "customer_id", "customer_name", "placed_at", "business_date", "items", "total", "gross_total",
  "channel_fee_rate", "channel_fee", "net_total", "consumed", "status_history", "updated_at",
] as const;
const JSON_COLS = new Set(["items", "consumed", "status_history"]);

function orderParams(o: Order) {
  return ORDER_COLS.map((c) => (JSON_COLS.has(c) ? JSON.stringify(o[c]) : o[c]));
}
const placeholders = ORDER_COLS.map((c, i) => (JSON_COLS.has(c) ? `$${i + 1}::jsonb` : `$${i + 1}`)).join(", ");

export const postgresStore: Store = {
  kind: dbBackend() === "postgres" ? "postgres" : "embedded",

  async ping() {
    await (await db())("SELECT 1");
  },

  async nextOrderNumber() {
    const [{ n }] = await (await db())<{ n: number }>(`SELECT nextval('barmade_order_number')::int AS n`);
    return n;
  },

  async insertOrder(o) {
    const rows = await (await db())(
      `INSERT INTO orders (${ORDER_COLS.join(", ")}) VALUES (${placeholders}) RETURNING *`,
      orderParams(o),
    );
    return toOrder(rows[0]);
  },

  async getOrder(id) {
    const rows = await (await db())(`SELECT * FROM orders WHERE id = $1`, [id]);
    return rows[0] ? toOrder(rows[0]) : null;
  },

  async listOrders({ since, customerId, limit }: ListOpts) {
    const where = [`source = 'barmade-web'`];
    const params: unknown[] = [];
    if (since) {
      params.push(since);
      where.push(`updated_at > $${params.length}`);
    }
    if (customerId) {
      params.push(customerId);
      where.push(`customer_id = $${params.length}`);
    }
    params.push(limit);
    const rows = await (await db())(
      `SELECT * FROM orders WHERE ${where.join(" AND ")} ORDER BY placed_at DESC LIMIT $${params.length}`,
      params,
    );
    return rows.map(toOrder);
  },

  async updateOrder(id, next) {
    const q = await db();
    // Single-writer demo: read-modify-write guarded by the status we read.
    const current = await this.getOrder(id);
    if (!current) return null;
    const patch = next(current);
    if (!patch) return current;
    const merged = { ...current, ...patch };
    const rows = await q(
      `UPDATE orders SET status = $2, updated_at = $3, status_history = $4::jsonb
        WHERE id = $1 AND status = $5 RETURNING *`,
      [id, merged.status, merged.updated_at, JSON.stringify(merged.status_history), current.status],
    );
    // Someone else changed it in between: re-run against the fresh row.
    return rows[0] ? toOrder(rows[0]) : this.updateOrder(id, next);
  },

  async consumedByApp() {
    const rows = await (await db())<{ ingredient_id: string; used: string }>(
      `SELECT c->>'ingredientId' AS ingredient_id, SUM((c->>'quantity')::numeric) AS used
         FROM orders, jsonb_array_elements(consumed) AS c
        WHERE source = 'barmade-web' AND status <> 'CANCELLED'
        GROUP BY 1`,
    );
    return new Map(rows.map((r) => [r.ingredient_id, Number(r.used)]));
  },

  async insertCustomer(c) {
    const rows = await (await db())(
      `INSERT INTO customers (id, display_name, language, taste, created_at) VALUES ($1, $2, $3, $4::jsonb, $5) RETURNING *`,
      [c.id, c.display_name, c.language, JSON.stringify(c.taste), c.created_at],
    );
    return toCustomer(rows[0]);
  },

  async getCustomer(id) {
    const rows = await (await db())(`SELECT * FROM customers WHERE id = $1`, [id]);
    return rows[0] ? toCustomer(rows[0]) : null;
  },

  async saveCustomer(c) {
    const rows = await (await db())(
      `UPDATE customers SET display_name = $2, language = $3, taste = $4::jsonb WHERE id = $1 RETURNING *`,
      [c.id, c.display_name, c.language, JSON.stringify(c.taste)],
    );
    return toCustomer(rows[0]);
  },
};

function iso(v: unknown) {
  return v instanceof Date ? v.toISOString() : String(v);
}
function json<T>(v: unknown): T {
  return (typeof v === "string" ? JSON.parse(v) : v) as T;
}

function toOrder(r: Record<string, unknown>): Order {
  return {
    id: String(r.id),
    order_number: Number(r.order_number),
    restaurant_id: String(r.restaurant_id),
    status: r.status as OrderStatus,
    channel: "barmade",
    source: "barmade-web",
    fulfillment: r.fulfillment as Fulfillment,
    table_number: (r.table_number as string) ?? null,
    customer_id: (r.customer_id as string) ?? null,
    customer_name: String(r.customer_name ?? ""),
    placed_at: iso(r.placed_at),
    business_date: r.business_date instanceof Date ? r.business_date.toISOString().slice(0, 10) : String(r.business_date),
    items: json(r.items),
    total: Number(r.total),
    gross_total: Number(r.gross_total),
    channel_fee_rate: Number(r.channel_fee_rate),
    channel_fee: Number(r.channel_fee),
    net_total: Number(r.net_total),
    consumed: json(r.consumed),
    status_history: json(r.status_history),
    updated_at: iso(r.updated_at),
  };
}

function toCustomer(r: Record<string, unknown>): Customer {
  return {
    id: String(r.id),
    display_name: String(r.display_name),
    language: isLang(r.language) ? r.language : "en",
    taste: cleanTaste(json(r.taste)),
    created_at: iso(r.created_at),
  };
}
