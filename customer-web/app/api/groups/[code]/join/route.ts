import { body, errorResponse, json } from "@/lib/http";
import { joinGroup } from "@/lib/groups";

/** POST { customerId, name } */
export async function POST(req: Request, { params }: { params: Promise<{ code: string }> }) {
  try {
    const b = await body(req);
    return json(await joinGroup((await params).code.toUpperCase(), String(b.customerId ?? ""), String(b.name ?? "")));
  } catch (err) {
    return errorResponse(err);
  }
}
