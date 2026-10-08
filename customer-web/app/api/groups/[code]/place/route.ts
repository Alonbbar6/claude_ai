import { body, errorResponse, json } from "@/lib/http";
import { placeGroup } from "@/lib/groups";

/** POST { customerId } → host sends everyone's dishes to the kitchen as one order. */
export async function POST(req: Request, { params }: { params: Promise<{ code: string }> }) {
  try {
    const b = await body(req);
    return json(await placeGroup((await params).code.toUpperCase(), String(b.customerId ?? "")));
  } catch (err) {
    return errorResponse(err);
  }
}
