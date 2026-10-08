// End-to-end check for rehearsal: node scripts/smoke.mjs [baseUrl] [--write]
// Local mode: creates a test customer + order, walks it through the statuses, cancels a second order.
// BarMade mode (orders go to the team backend): read-only unless --write, because a real order
// deducts real inventory and can't be undone. Exits non-zero on the first failure.
const args = process.argv.slice(2);
const write = args.includes("--write");
const base = (args.find((a) => !a.startsWith("--")) || process.env.BASE_URL || "http://localhost:3000").replace(/\/$/, "");
const token = process.env.MERCHANT_API_TOKEN;
const auth = token ? { Authorization: `Bearer ${token}` } : {};
let step = 0;

async function call(method, path, body, headers = {}) {
  const res = await fetch(base + path, {
    method,
    headers: { "Content-Type": "application/json", ...headers },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  return { status: res.status, data };
}
function check(name, ok, detail = "") {
  step++;
  console.log(`${ok ? "✅" : "❌"} ${step}. ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) process.exit(1);
}

const health = await call("GET", "/api/health");
check("health", health.data.ok === true, `db=${health.data.db} orders=${health.data.orders} ai=${health.data.ai}`);
const remote = health.data.orders === "barmade-api";

const menu = await call("GET", "/api/menu");
const available = menu.data.dishes?.filter((d) => d.status !== "sold_out").length ?? 0;
check("menu loads", menu.data.dishes?.length >= 5 && available > 0, `${available} available, special=${menu.data.special?.dishId ?? "none"}`);

const rec0 = await call("POST", "/api/recommend", { likes: ["creamy"], avoid: [], lang: "es" });
check("suggestions", rec0.data.suggestions?.length > 0, `source=${rec0.data.source}`);

if (remote && !write) {
  console.log("\nBarMade mode: skipped writes (customer + order). Re-run with --write to place ONE real test order.");
  process.exit(0);
}

const cust = await call("POST", "/api/customers", { name: "Smoke Test", language: "en" });
check("create customer", cust.status === 201, cust.data.id);

const order = await call("POST", "/api/orders", {
  customerId: cust.data.id,
  customerName: "Smoke Test",
  fulfillment: "to_go",
  items: [{ menuItemId: "MENU-005", quantity: 1, modifiers: [] }],
});
check("place order", order.status === 201 && order.data.channel === "barmade" && order.data.source === "barmade-web",
  `#${order.data.order_number} fee=${order.data.channel_fee_rate}`);

const feed = await call("GET", "/api/orders?limit=5", null, auth);
check("order feed sees it", feed.data.orders?.some((o) => o.id === order.data.id));

const tracked = await call("GET", `/api/orders/${order.data.id}`);
check("tracking reads it back", tracked.status === 200 && tracked.data.customer_name === "Smoke Test", `status=${tracked.data.status}`);

if (remote) {
  console.log(`\nAll good on ${base} (status changes are done by the BarMade backend/merchant).`);
  process.exit(0);
}

for (const s of ["PREPARING", "READY", "COMPLETED"]) {
  const r = await call("PATCH", `/api/orders/${order.data.id}/status`, { status: s }, auth);
  check(`status → ${s}`, r.status === 200 && r.data.status === s);
}

const extra = await call("POST", "/api/orders", {
  customerName: "Smoke Test", fulfillment: "for_here", tableNumber: "1",
  items: [{ menuItemId: "MENU-017", quantity: 1, modifiers: [] }],
});
const cancel = await call("PATCH", `/api/orders/${extra.data.id}/status`, { status: "CANCELLED" }, auth);
check("cancel releases stock", cancel.data.status === "CANCELLED");

console.log(`\nAll good on ${base}`);
