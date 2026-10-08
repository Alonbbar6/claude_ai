import "server-only";
import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { z } from "zod";
import { getMenu } from "./catalog";
import { RESTAURANTS, TRATTORIA_ID } from "./content";
import type { Lang } from "./i18n";
import type { Localized } from "./content";
import type { Allergen } from "./types";
import { avoidConflicts } from "./diet";

/**
 * Voice/text intent → cart actions. Claude only proposes; code validates every dish id,
 * quantity and stock. Nothing is ordered here: the customer confirms in the cart.
 * Claude receives the spoken sentence and the menu, never the customer's name or id.
 */

// Voice needs a fast answer; VOICE_MODEL lets you pick a quicker model for this route only.
const MODEL = process.env.VOICE_MODEL?.trim() || process.env.ANTHROPIC_MODEL?.trim() || "claude-opus-5-5";
const MAX_QTY = 20;
// The mic bubble is small; replies must fit this many characters as complete sentences.
const REPLY_MAX = 200;
const AVOIDABLE: Allergen[] = ["dairy", "gluten", "egg", "fish", "pork", "meat"];

const Output = z.object({
  intent: z.enum(["add_to_order", "build_meal", "find_dish", "unknown"]),
  items: z.array(z.object({ dishId: z.string(), quantity: z.number() })).describe("for build_meal: most important first"),
  budget: z.number().describe("build_meal: total budget they said, in dollars; 0 if none"),
  avoid: z.array(z.enum(["dairy", "gluten", "egg", "fish", "pork", "meat"])).describe("what they said to avoid"),
  fulfillment: z.enum(["to_go", "for_here", "unspecified"]),
  tableNumber: z.string(),
  matches: z.array(z.string()).describe("dish ids that answer a find_dish question, best first"),
  reply: z.string().describe("one or two short friendly sentences to show the customer"),
});

export interface VoiceResult {
  intent: "add_to_order" | "build_meal" | "find_dish" | "unknown";
  items: { dishId: string; quantity: number }[];
  /** build_meal only, computed here (never by the model): what the meal costs and the budget it had to fit. */
  total: number | null;
  budget: number | null;
  fulfillment: "to_go" | "for_here" | null;
  tableNumber: string | null;
  matches: { dishId: string; restaurantId: string; name: Localized; image: string; open: boolean }[];
  reply: string;
}

// Used when code had to drop dishes the model picked, so the reply can't describe a meal that isn't in the cart.
const MEAL_TRIMMED: Record<Lang, { fits: string; none: string }> = {
  en: { fits: "Here's what fits your budget and what you avoid. Review it before you confirm.", none: "Nothing on the menu fits that budget and what you avoid right now." },
  es: { fits: "Esto es lo que cabe en tu presupuesto y respeta lo que evitas. Revísalo antes de confirmar.", none: "Ahora mismo nada del menú cabe en ese presupuesto y respeta lo que evitas." },
};

const UNAVAILABLE: Record<Lang, string> = {
  en: "The voice assistant isn't available right now. You can still browse the menu and order from it.",
  es: "El asistente de voz no está disponible en este momento. Puedes ver el menú y pedir desde ahí.",
};

const FALLBACK: Record<Lang, string> = {
  en: "Sorry, I couldn't understand that. Try “two Margheritas and a Coke, to go”.",
  es: "Perdón, no te entendí. Prueba “dos Margheritas y una Coca-Cola, para llevar”.",
};

/** One earlier exchange in the same mic session, so follow-ups like "yes, add it" have context. */
export interface VoiceTurn {
  said: string;
  reply: string;
  /** dishes proposed (shown as a meal or as choices) but not in the cart */
  proposed: string[];
  /** what that turn actually put in the cart */
  added: { dishId: string; quantity: number }[];
}

export function cleanHistory(v: unknown): VoiceTurn[] {
  const ids = (x: unknown) => (Array.isArray(x) ? x : []).filter((i): i is string => typeof i === "string").slice(0, 8).map((i) => i.slice(0, 60));
  return (Array.isArray(v) ? v : []).slice(-2).flatMap((t) => {
    if (!t || typeof t.said !== "string") return [];
    const added = (Array.isArray(t.added) ? t.added : [])
      .filter((a: { dishId?: unknown; quantity?: unknown }) => typeof a?.dishId === "string" && Number(a.quantity) > 0)
      .slice(0, 8)
      .map((a: { dishId: string; quantity: unknown }) => ({ dishId: a.dishId.slice(0, 60), quantity: Math.min(MAX_QTY, Math.round(Number(a.quantity))) }));
    return [{ said: t.said.slice(0, 300), reply: String(t.reply ?? "").slice(0, 600), proposed: ids(t.proposed), added }];
  });
}

export async function interpret(text: string, lang: Lang, profileAvoid: Allergen[] = [], history: VoiceTurn[] = []): Promise<VoiceResult> {
  const empty: VoiceResult = { intent: "unknown", items: [], total: null, budget: null, fulfillment: null, tableNumber: null, matches: [], reply: FALLBACK[lang] };
  if (!process.env.ANTHROPIC_API_KEY) return empty;

  const menu = await getMenu();
  const open = RESTAURANTS.find((r) => r.id === TRATTORIA_ID)!;
  const orderable = menu.dishes.filter((d) => d.status !== "sold_out");
  const catalog = [
    {
      restaurant: open.name,
      open: true,
      dishes: menu.dishes.map((d) => ({
        id: d.id,
        name: d.name.en,
        name_es: d.name.es,
        price: d.price,
        category: d.category,
        allergens: avoidConflicts(d, AVOIDABLE),
        ...(d.status === "sold_out" ? { soldOut: true } : { left: d.servingsLeft }),
      })),
    },
    ...RESTAURANTS.filter((r) => !r.acceptsOrders).map((r) => ({
      restaurant: r.name,
      open: false,
      opensAt: "5:00 PM",
      dishes: (r.dishes ?? []).map((d) => ({ id: `${r.id}:${d.id}`, name: d.name.en, name_es: d.name.es, price: d.price })),
    })),
  ];

  const client = new Anthropic({ timeout: 15_000, maxRetries: 1 });
  const res = await client.beta.messages.parse({
    model: MODEL,
    max_tokens: 2000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: { effort: "low", format: betaZodOutputFormat(Output) },
    system:
      "You are the voice ordering helper of BarMade, a restaurant ordering web app. The customer spoke a sentence " +
      "(speech-to-text, so expect small transcription errors and number words like 'two'/'dos'). Map it to an intent:\n" +
      "- add_to_order: they want dishes. Put only dishes from the OPEN restaurant that are not soldOut in items, " +
      "with quantities (default 1). Only add a dish when what they said clearly names it (allowing for small " +
      "transcription errors). If a word could be more than one dish, or names nothing on the menu, do NOT add a " +
      "guess: put the likely dish ids in matches and ask in the reply which one they meant. Set fulfillment if they say to go / take away / para llevar (to_go) or " +
      "for here / eat here / para comer aquí (for_here), else unspecified. tableNumber only if they say one, else empty.\n" +
      "- build_meal: they want you to put a meal together (e.g. 'dinner for two under $40, no pork', 'something " +
      "light for one'). Pick dishes from the OPEN restaurant that are not soldOut: a sensible meal per person (a main, " +
      "and a drink or starter or dessert when the budget allows), most important first. Respect what they avoid and the " +
      `customer's saved avoid list ${JSON.stringify(profileAvoid)}, using each dish's allergens. Set budget if they gave ` +
      "one (else 0) and fill avoid with what they said to avoid. Code checks the budget and the allergens and computes " +
      "the total, so never state prices or totals in the reply. The dishes go straight into the cart, so say you " +
      "added them (not 'how about…') and describe the meal in a few words. If nothing fits, " +
      "return no items and say so.\n" +
      "- find_dish: they ask where/what to eat or for restaurants with some dish. Put matching dish ids from any " +
      "restaurant in matches (closed ones too). If the best match is closed, say it opens at 5 PM and suggest a similar " +
      "orderable dish at the open restaurant, including its id in matches.\n" +
      "- unknown: anything else.\n" +
      "If they ask for something sold out or not on the menu, say so briefly and suggest an alternative. Never invent " +
      "dishes, prices or ids. The reply is shown on screen: one or two short, warm sentences, and for add_to_order " +
      "remind them to review and confirm their order.\n" +
      "previous_turns (if any) are earlier sentences in this same conversation, oldest first. Use them to resolve " +
      "follow-ups like 'yes', 'add it', 'add that meal', 'make it three': for those, return add_to_order with the dishes " +
      "they refer to (from proposed, or from the dishes named in that reply). Dishes in added are ALREADY in the cart: " +
      "never add them again unless they clearly ask for more; if they only confirm, return unknown and say it's already " +
      "in their cart and they can tap Review order.\n" +
      `The reply is at most ${REPLY_MAX} characters including spaces, plain text, one or two sentences. Plan it to ` +
      "fit: as you get close to the limit, wrap up with a complete closing sentence. Never leave a sentence unfinished. " +
      `Reply in ${lang === "es" ? "Spanish" : "English"}.`,
    messages: [
      {
        role: "user",
        content:
          `<menu>${JSON.stringify(catalog)}</menu>\n` +
          (history.length ? `<previous_turns>${JSON.stringify(history)}</previous_turns>\n` : "") +
          `<customer_said>${text.slice(0, 300)}</customer_said>`,
      },
    ],
  }).catch((err: unknown) => {
    // e.g. out of API credit, rate limit, network: answer politely instead of failing the request
    console.error("voice: Claude unavailable", err instanceof Error ? err.message : err);
    return null;
  });
  if (!res) return { ...empty, reply: UNAVAILABLE[lang] };
  if (res.stop_reason === "refusal" || !res.parsed_output) return empty;
  const out = res.parsed_output;

  // ---- validate everything Claude proposed against the live menu
  const byId = new Map(orderable.map((d) => [d.id, d]));
  const building = out.intent === "build_meal";
  let trimmed = false;
  const avoid = [...new Set([...profileAvoid, ...out.avoid])];
  const merged = new Map<string, number>();
  for (const it of out.intent === "add_to_order" || building ? out.items : []) {
    const d = byId.get(it.dishId);
    if (!d) continue;
    // A meal we build must respect what they avoid; a dish they named themselves is their call (the UI warns).
    if (building && avoidConflicts(d, avoid).length) {
      trimmed = true;
      continue;
    }
    const q = Math.max(1, Math.min(MAX_QTY, Math.round(Number(it.quantity) || 1)));
    merged.set(d.id, Math.min((merged.get(d.id) ?? 0) + q, d.servingsLeft));
  }
  // Fit the budget by trimming from the least important end, one serving at a time.
  const budget = building && out.budget > 0 ? Math.round(out.budget * 100) / 100 : null;
  const totalOf = () => [...merged].reduce((s, [id, q]) => s + byId.get(id)!.price * q, 0);
  while (budget !== null && merged.size && totalOf() > budget) {
    trimmed = true;
    const last = [...merged.keys()].pop()!;
    const q = merged.get(last)! - 1;
    if (q > 0) merged.set(last, q);
    else merged.delete(last);
  }
  const lookup = new Map<string, VoiceResult["matches"][number]>();
  for (const d of menu.dishes) lookup.set(d.id, { dishId: d.id, restaurantId: TRATTORIA_ID, name: d.name, image: d.image, open: true });
  for (const r of RESTAURANTS)
    for (const d of r.dishes ?? [])
      lookup.set(`${r.id}:${d.id}`, { dishId: d.id, restaurantId: r.id, name: d.name, image: d.image, open: false });
  const matches = [...new Set(out.matches)].flatMap((id) => lookup.get(id) ?? []).slice(0, 4);

  const reply = trimmed ? MEAL_TRIMMED[lang][merged.size ? "fits" : "none"] : (await fitReply(client, out.reply, lang)) || FALLBACK[lang];
  return {
    // Nothing clear to add but likely dishes to pick from → show them as choices.
    intent: (out.intent === "add_to_order" || building) && merged.size === 0 ? (matches.length ? "find_dish" : "unknown") : out.intent,
    items: [...merged].filter(([, q]) => q > 0).map(([dishId, quantity]) => ({ dishId, quantity })),
    total: building && merged.size ? Math.round(totalOf() * 100) / 100 : null,
    budget: building && merged.size ? budget : null,
    fulfillment: out.fulfillment === "unspecified" ? null : out.fulfillment,
    tableNumber: out.tableNumber.trim().replace(/[^\w-]/g, "").slice(0, 8) || null,
    matches,
    reply,
  };
}

/**
 * A reply over REPLY_MAX is rewritten shorter by the model (same meaning, complete sentences) instead of being cut.
 * Only if the rewrite still doesn't fit are whole trailing sentences dropped; a sentence is never cut in half.
 */
async function fitReply(client: Anthropic, reply: string, lang: Lang): Promise<string> {
  let s = reply.trim().replace(/\s+/g, " ");
  if (s.length <= REPLY_MAX) return s;
  try {
    const res = await client.beta.messages.parse({
      model: MODEL,
      max_tokens: 400,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      output_config: { effort: "low", format: betaZodOutputFormat(z.object({ reply: z.string() })) },
      system:
        `Rewrite the restaurant assistant's message in at most ${REPLY_MAX} characters including spaces. Keep its ` +
        "meaning, the dish names and any question it asks; drop filler. Use complete sentences, plain text, " +
        `${lang === "es" ? "Spanish" : "English"}. Do not add facts.`,
      messages: [{ role: "user", content: s }],
    });
    const short = res.parsed_output?.reply.trim().replace(/\s+/g, " ");
    if (short && short.length < s.length) s = short;
  } catch {
    // keep the original; the sentence fallback below still applies
  }
  if (s.length <= REPLY_MAX) return s;
  const sentences = s.match(/[^.!?]+[.!?]+["”»)]*\s*/g) ?? [s];
  let kept = "";
  for (const x of sentences) {
    if ((kept + x).trim().length > REPLY_MAX) break;
    kept += x;
  }
  return kept.trim() || s; // one long sentence is shown whole rather than cut
}
