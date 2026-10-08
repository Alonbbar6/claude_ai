import { body, errorResponse, json } from "@/lib/http";
import { getCustomer, updateCustomer } from "@/lib/customers";

type Ctx = { params: Promise<{ id: string }> };

export async function GET(_req: Request, { params }: Ctx) {
  try {
    const c = await getCustomer((await params).id);
    return c ? json(c) : json({ error: "not_found" }, 404);
  } catch (err) {
    return errorResponse(err);
  }
}

export async function PATCH(req: Request, { params }: Ctx) {
  try {
    const c = await updateCustomer((await params).id, await body(req));
    return c ? json(c) : json({ error: "not_found" }, 404);
  } catch (err) {
    return errorResponse(err);
  }
}
