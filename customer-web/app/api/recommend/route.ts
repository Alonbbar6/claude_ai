import { body, errorResponse, json } from "@/lib/http";
import { recommend } from "@/lib/recommend";
import { cleanTaste } from "@/lib/customers";
import { isLang } from "@/lib/i18n";

export const dynamic = "force-dynamic";

/** POST { likes: Taste[], avoid: Allergen[], craving?: string, lang: "en"|"es" } */
export async function POST(req: Request) {
  try {
    const b = await body(req);
    const taste = cleanTaste({ likes: b.likes, avoid: b.avoid });
    const craving = typeof b.craving === "string" ? b.craving.trim().slice(0, 200) : undefined;
    return json(await recommend({ ...taste, craving: craving || undefined, lang: isLang(b.lang) ? b.lang : "en" }));
  } catch (err) {
    return errorResponse(err);
  }
}
