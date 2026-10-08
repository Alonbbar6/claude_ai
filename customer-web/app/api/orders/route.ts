import { body, errorResponse, json, merchantAuthorized } from "@/lib/http";
import { createOrder, listOrders, type Fulfillment } from "@/lib/orders";
import type { LineInput } from "@/lib/catalog";

export const dynamic = "force-dynamic";

/** Customer places an order. Always channel "barmade". */
export async function POST(req: Request) {
  try {
    const b = await body(req);
    const order = await createOrder({
      customerId: typeof b.customerId === "string" && /^[0-9a-f-]{36}$/i.test(b.customerId) ? b.customerId : null,
      customerName: String(b.customerName ?? ""),
      fulfillment: b.fulfillment as Fulfillment,
      tableNumber: typeof b.tableNumber === "string" ? b.tableNumber : null,
      items: (Array.isArray(b.items) ? b.items : []) as LineInput[],
    });
    return json(order, 201);
  } catch (err) {
    return errorResponse(err);
  }
}

/**
 * GET /api/orders?since=<ISO>&limit=50        → merchant feed (poll with the last updated_at)
 * GET /api/orders?customerId=<uuid>           → a customer's own orders
 */
export async function GET(req: Request) {
  try {
    const url = new URL(req.url);
    const customerId = url.searchParams.get("customerId") ?? undefined;
    if (!customerId && !merchantAuthorized(req)) return json({ error: "unauthorized" }, 401);
    const orders = await listOrders({
      customerId,
      since: url.searchParams.get("since") ?? undefined,
      limit: Number(url.searchParams.get("limit")) || undefined,
    });
    return json({ orders, now: new Date().toISOString() });
  } catch (err) {
    return errorResponse(err);
  }
}
