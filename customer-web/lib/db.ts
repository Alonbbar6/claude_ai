import "server-only";
import path from "node:path";

/**
 * One tiny Postgres interface for two backends:
 *  - DATABASE_URL set  → real Postgres (Neon / Railway) via `postgres`
 *  - DATABASE_URL empty → embedded Postgres (PGlite) persisted in ./.pglite
 * Same SQL runs on both, so switching to Neon is just setting the env var.
 */
type Row = Record<string, unknown>;
export type Query = <T extends Row = Row>(text: string, params?: unknown[]) => Promise<T[]>;

const SCHEMA = /* sql */ `
CREATE TABLE IF NOT EXISTS customers (
  id            uuid PRIMARY KEY,
  display_name  text NOT NULL,
  language      text NOT NULL DEFAULT 'en',
  taste         jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE SEQUENCE IF NOT EXISTS barmade_order_number START 1001;

CREATE TABLE IF NOT EXISTS orders (
  id                text PRIMARY KEY,
  order_number      integer,
  restaurant_id     text NOT NULL DEFAULT 'trattoria-little-italy',
  status            text NOT NULL,
  channel           text NOT NULL,
  source            text,
  fulfillment       text,
  table_number      text,
  customer_id       uuid,
  customer_name     text,
  placed_at         timestamptz NOT NULL DEFAULT now(),
  business_date     date NOT NULL,
  items             jsonb NOT NULL,
  total             numeric(10,2) NOT NULL,
  gross_total       numeric(10,2) NOT NULL,
  channel_fee_rate  numeric(6,4) NOT NULL,
  channel_fee       numeric(10,2) NOT NULL,
  net_total         numeric(10,2) NOT NULL,
  consumed          jsonb NOT NULL DEFAULT '[]'::jsonb,
  status_history    jsonb NOT NULL DEFAULT '[]'::jsonb,
  updated_at        timestamptz NOT NULL DEFAULT now()
);

`;

/**
 * Additive changes to a pre-existing `orders` table owned by the team.
 * Only run when DB_ALLOW_ALTER=true (always on for the local embedded DB),
 * so pointing at the team's database never changes their schema by surprise.
 */
const EXTEND = /* sql */ `
ALTER TABLE orders ADD COLUMN IF NOT EXISTS order_number   integer;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS source         text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS fulfillment    text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS table_number   text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS customer_id    uuid;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS customer_name  text;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS status_history jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS updated_at     timestamptz NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS orders_placed_at_idx ON orders (placed_at DESC);
CREATE INDEX IF NOT EXISTS orders_customer_idx  ON orders (customer_id);
`;

async function connect(): Promise<Query> {
  const url = process.env.DATABASE_URL?.trim();
  if (url) {
    const { default: postgres } = await import("postgres");
    const sql = postgres(url, {
      max: 5,
      // An explicit ?sslmode= in the URL wins; otherwise TLS for anything that isn't local/private.
      ...(/[?&]sslmode=/.test(url)
        ? {}
        : { ssl: /localhost|127\.0\.0\.1|\.railway\.internal/.test(url) ? false : ("require" as const) }),
      onnotice: () => {},
    });
    return async (text, params = []) =>
      (await sql.unsafe(text, params as never[])) as unknown as never[];
  }
  const { PGlite } = await import("@electric-sql/pglite");
  const db = new PGlite(path.join(process.cwd(), ".pglite"));
  return async (text, params = []) => (await db.query(text, params)).rows as never[];
}

async function init(): Promise<Query> {
  const q = await connect();
  // Run statements one at a time: postgres.js `unsafe` with params can't take multi-statement text.
  const allowAlter = dbBackend() === "embedded" || process.env.DB_ALLOW_ALTER === "true";
  for (const stmt of statements(SCHEMA)) await q(stmt);
  if (allowAlter) for (const stmt of statements(EXTEND)) await q(stmt);
  return q;
}

function statements(sql: string) {
  return sql.split(";").map((s) => s.trim()).filter(Boolean);
}

const g = globalThis as unknown as { __barmadeDb?: Promise<Query> };

export function db(): Promise<Query> {
  g.__barmadeDb ??= init().catch((err) => {
    g.__barmadeDb = undefined; // retry on next request instead of caching the failure
    throw err;
  });
  return g.__barmadeDb;
}

export function dbBackend(): "postgres" | "embedded" {
  return process.env.DATABASE_URL?.trim() ? "postgres" : "embedded";
}
