import { errorResponse, json } from "@/lib/http";
import { getOrder } from "@/lib/orders";

export const dynamic = "force-dynamic";

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const order = await getOrder((await params).id);
    return order ? json(order) : json({ error: "not_found" }, 404);
  } catch (err) {
    return errorResponse(err);
  }
}
