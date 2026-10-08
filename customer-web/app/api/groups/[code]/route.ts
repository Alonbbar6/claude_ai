import { body, errorResponse, json } from "@/lib/http";
import { getGroup, setOptions, setPaid } from "@/lib/groups";

export const dynamic = "force-dynamic";
type Ctx = { params: Promise<{ code: string }> };

/** GET → group, everyone's dishes, the bill per person and the order status once sent. */
export async function GET(_req: Request, { params }: Ctx) {
  try {
    const g = await getGroup((await params).code.toUpperCase());
    return g ? json(g) : json({ error: "not_found" }, 404);
  } catch (err) {
    return errorResponse(err);
  }
}

/**
 * Host only. PATCH { customerId, split?, fulfillment?, tableNumber? }
 *         or PATCH { customerId, memberId, paid }
 */
export async function PATCH(req: Request, { params }: Ctx) {
  try {
    const code = (await params).code.toUpperCase();
    const b = await body(req);
    const host = String(b.customerId ?? "");
    if (typeof b.memberId === "string") return json(await setPaid(code, host, b.memberId, b.paid === true));
    return json(await setOptions(code, host, b));
  } catch (err) {
    return errorResponse(err);
  }
}
