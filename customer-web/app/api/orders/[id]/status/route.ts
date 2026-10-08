import { body, errorResponse, json, merchantAuthorized } from "@/lib/http";
import { setStatus, STATUSES, type OrderStatus } from "@/lib/orders";

/** Merchant moves an order forward: { "status": "PREPARING" | "READY" | "COMPLETED" | "CANCELLED" } */
export async function PATCH(req: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    if (!merchantAuthorized(req)) return json({ error: "unauthorized" }, 401);
    const { status } = await body(req);
    if (!STATUSES.includes(status as OrderStatus)) return json({ error: "invalid", message: `status must be one of ${STATUSES.join(", ")}` }, 400);
    return json(await setStatus((await params).id, status as OrderStatus));
  } catch (err) {
    return errorResponse(err);
  }
}
