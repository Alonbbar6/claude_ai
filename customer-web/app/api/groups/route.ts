import { body, errorResponse, json } from "@/lib/http";
import { createGroup } from "@/lib/groups";

/** POST { customerId, name } → new group with the caller as host. */
export async function POST(req: Request) {
  try {
    const b = await body(req);
    return json(await createGroup(String(b.customerId ?? ""), String(b.name ?? "")), 201);
  } catch (err) {
    return errorResponse(err);
  }
}
