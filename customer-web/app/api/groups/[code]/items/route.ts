import { body, errorResponse, json } from "@/lib/http";
import { setMyItems } from "@/lib/groups";

/** PUT { customerId, items: [{ menuItemId, quantity, modifiers }] } → replaces the caller's own dishes. */
export async function PUT(req: Request, { params }: { params: Promise<{ code: string }> }) {
  try {
    const b = await body(req);
    return json(await setMyItems((await params).code.toUpperCase(), String(b.customerId ?? ""), b.items));
  } catch (err) {
    return errorResponse(err);
  }
}
