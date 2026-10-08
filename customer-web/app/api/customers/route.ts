import { body, errorResponse, json } from "@/lib/http";
import { cleanName, createCustomer } from "@/lib/customers";
import { isLang } from "@/lib/i18n";

export async function POST(req: Request) {
  try {
    const b = await body(req);
    const name = cleanName(b.name);
    if (!name) return json({ error: "invalid", message: "name is required" }, 400);
    return json(await createCustomer(name, isLang(b.language) ? b.language : "en"), 201);
  } catch (err) {
    return errorResponse(err);
  }
}
