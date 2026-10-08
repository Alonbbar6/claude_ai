import "server-only";
import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { z } from "zod";
import { getMenu } from "./catalog";
import { RESTAURANTS, TRATTORIA_ID } from "./content";
import type { Lang } from "./i18n";
import type { Localized } from "./content";

/**
 * Voice/text intent → cart actions. Claude only proposes; code validates every dish id,
 * quantity and stock. Nothing is ordered here: the customer confirms in the cart.
 * Claude receives the spoken sentence and the menu, never the customer's name or id.
 */

// Voice needs a fast answer; VOICE_MODEL lets you pick a quicker model for this route only.
const MODEL = process.env.VOICE_MODEL?.trim() || process.env.ANTHROPIC_MODEL?.trim() || "claude-opus-5-5";
const MAX_QTY = 20;

const Output = z.object({
  intent: z.enum(["add_to_order", "find_dish", "unknown"]),
  items: z.array(z.object({ dishId: z.string(), quantity: z.number() })),
  fulfillment: z.enum(["to_go", "for_here", "unspecified"]),
  tableNumber: z.string(),
  matches: z.array(z.string()).describe("dish ids that answer a find_dish question, best first"),
  reply: z.string().describe("one or two short friendly sentences to show the customer"),
});

export interface VoiceResult {
  intent: "add_to_order" | "find_dish" | "unknown";
  items: { dishId: string; quantity: number }[];
  fulfillment: "to_go" | "for_here" | null;
  tableNumber: string | null;
  matches: { dishId: string; restaurantId: string; name: Localized; image: string; open: boolean }[];
  reply: string;
}

const FALLBACK: Record<Lang, string> = {
  en: "Sorry, I couldn't understand that. Try “two Margheritas and a Coke, to go”.",
  es: "Perdón, no te entendí. Prueba “dos Margheritas y una Coca-Cola, para llevar”.",
};

export async function interpret(text: string, lang: Lang): Promise<VoiceResult> {
  const empty: VoiceResult = { intent: "unknown", items: [], fulfillment: null, tableNumber: null, matches: [], reply: FALLBACK[lang] };
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
      "- find_dish: they ask where/what to eat or for restaurants with some dish. Put matching dish ids from any " +
      "restaurant in matches (closed ones too). If the best match is closed, say it opens at 5 PM and suggest a similar " +
      "orderable dish at the open restaurant, including its id in matches.\n" +
      "- unknown: anything else.\n" +
      "If they ask for something sold out or not on the menu, say so briefly and suggest an alternative. Never invent " +
      "dishes, prices or ids. The reply is shown on screen: one or two short, warm sentences, and for add_to_order " +
      `remind them to review and confirm their order. Reply in ${lang === "es" ? "Spanish" : "English"}.`,
    messages: [
      {
        role: "user",
        content: `<menu>${JSON.stringify(catalog)}</menu>\n<customer_said>${text.slice(0, 300)}</customer_said>`,
      },
    ],
  });
  if (res.stop_reason === "refusal" || !res.parsed_output) return empty;
  const out = res.parsed_output;

  // ---- validate everything Claude proposed against the live menu
  const byId = new Map(orderable.map((d) => [d.id, d]));
  const merged = new Map<string, number>();
  for (const it of out.intent === "add_to_order" ? out.items : []) {
    const d = byId.get(it.dishId);
    if (!d) continue;
    const q = Math.max(1, Math.min(MAX_QTY, Math.round(Number(it.quantity) || 1)));
    merged.set(d.id, Math.min((merged.get(d.id) ?? 0) + q, d.servingsLeft));
  }
  const lookup = new Map<string, VoiceResult["matches"][number]>();
  for (const d of menu.dishes) lookup.set(d.id, { dishId: d.id, restaurantId: TRATTORIA_ID, name: d.name, image: d.image, open: true });
  for (const r of RESTAURANTS)
    for (const d of r.dishes ?? [])
      lookup.set(`${r.id}:${d.id}`, { dishId: d.id, restaurantId: r.id, name: d.name, image: d.image, open: false });
  const matches = [...new Set(out.matches)].flatMap((id) => lookup.get(id) ?? []).slice(0, 4);

  return {
    // Nothing clear to add but likely dishes to pick from → show them as choices.
    intent: out.intent === "add_to_order" && merged.size === 0 ? (matches.length ? "find_dish" : "unknown") : out.intent,
    items: [...merged].filter(([, q]) => q > 0).map(([dishId, quantity]) => ({ dishId, quantity })),
    fulfillment: out.fulfillment === "unspecified" ? null : out.fulfillment,
    tableNumber: out.tableNumber.trim().replace(/[^\w-]/g, "").slice(0, 8) || null,
    matches,
    reply: out.reply.trim().slice(0, 300) || FALLBACK[lang],
  };
}
