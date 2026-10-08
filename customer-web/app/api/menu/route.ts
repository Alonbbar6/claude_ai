import { errorResponse, json } from "@/lib/http";
import { getMenu } from "@/lib/catalog";

export const dynamic = "force-dynamic";

export async function GET() {
  try {
    return json(await getMenu());
  } catch (err) {
    return errorResponse(err);
  }
}
