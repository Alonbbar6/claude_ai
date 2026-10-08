import "server-only";
import { aiProvider, structured } from "./ai";
import { z } from "zod";
import { getMenu, type Dish } from "./catalog";
import type { Taste } from "./content";
import type { Allergen } from "./types";
import type { Lang } from "./i18n";
import { avoidConflicts } from "./diet";

/**
 * Taste-based suggestions.
 * 1. Code decides what is allowed: in stock, and nothing the customer wants to avoid.
 * 2. Claude only ranks those candidates and writes a one-line reason.
 * Per the PRD, Claude never gets customer personal info (no name, no id) — just tastes.
 * Without an API key, or if the call fails/times out, a rule-based ranking is returned.
 */

export interface RecommendInput {
  likes: Taste[];
  avoid: Allergen[];
  craving?: string;
  lang: Lang;
}

export interface Suggestion {
  dishId: string;
  reason: string;
}

export interface RecommendResult {
  suggestions: Suggestion[];
  source: "ai" | "rules";
}

const TIMEOUT_MS = 12_000;
const CACHE_TTL_MS = 5 * 60_000;
const cache = new Map<string, { at: number; value: RecommendResult }>();

const Output = z.object({
  suggestions: z
    .array(z.object({ dishId: z.string(), reason: z.string() }))
    .describe("Up to 3 dishes, best first"),
});

export function allowedFor(dish: Dish, avoid: Allergen[]) {
  if (dish.status === "sold_out") return false;
  return avoidConflicts(dish, avoid).length === 0;
}

export async function recommend(input: RecommendInput): Promise<RecommendResult> {
  const menu = await getMenu();
  const candidates = menu.dishes.filter((d) => d.category !== "Beverage" && allowedFor(d, input.avoid));
  if (!candidates.length) return { suggestions: [], source: "rules" };

  const key = JSON.stringify([
    [...input.likes].sort(),
    [...input.avoid].sort(),
    input.craving?.trim().toLowerCase() ?? "",
    input.lang,
    candidates.map((c) => c.id + c.status),
    menu.special?.dishId,
  ]);
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < CACHE_TTL_MS) return hit.value;

  let value: RecommendResult;
  try {
    value = aiProvider()
      ? await withAi(input, candidates, menu.special?.dishId)
      : rules(input, candidates, menu.special?.dishId);
  } catch (err) {
    console.error("recommend: falling back to rules", err instanceof Error ? err.message : err);
    value = rules(input, candidates, menu.special?.dishId);
  }
  cache.set(key, { at: Date.now(), value });
  return value;
}

async function withAi(input: RecommendInput, candidates: Dish[], specialId?: string): Promise<RecommendResult> {
  const language = input.lang === "es" ? "Spanish (Latin American, friendly)" : "English";
  const menu = candidates.map((d) => ({
    id: d.id,
    name: d.name.en,
    description: d.description.en,
    tastes: d.tastes,
    price: d.price,
    vegetarian: d.vegetarian,
    ...(d.id === specialId ? { chefsSpecial: true } : {}),
    ...(d.status === "low" ? { fewLeft: true } : {}),
  }));

  const output = await structured({
    schema: Output,
    maxTokens: 2000,
    timeoutMs: TIMEOUT_MS,
    system:
      "You recommend dishes at a casual Italian restaurant for a customer ordering ahead on their lunch break. " +
      "Choose only from the provided menu by id; every dish listed is in stock and safe for the customer's restrictions. " +
      "Pick up to 3 that best match their tastes (and craving, if given). Prefer variety across categories. " +
      "If a chef's special fits, include it. Each reason is one warm sentence of at most 14 words that ties the dish to " +
      `what they like. Never invent ingredients or prices. Write reasons in ${language}.`,
    user:
          `<menu>${JSON.stringify(menu)}</menu>\n` +
          `<likes>${input.likes.join(", ") || "no preference given"}</likes>\n` +
          (input.craving ? `<craving>${input.craving.slice(0, 200)}</craving>\n` : "") +
          "Return your picks.",
  });

  if (!output) throw new Error("model declined");
  const ids = new Set(candidates.map((c) => c.id));
  const suggestions = (output.suggestions ?? [])
    .filter((s, i, all) => ids.has(s.dishId) && all.findIndex((x) => x.dishId === s.dishId) === i)
    .slice(0, 3)
    .map((s) => ({ dishId: s.dishId, reason: s.reason.trim().slice(0, 160) }));
  if (!suggestions.length) throw new Error("no valid suggestions");
  return { suggestions, source: "ai" };
}

const REASON: Record<Lang, (tastes: string[]) => string> = {
  en: (t) => (t.length ? `Matches what you like: ${t.join(", ")}.` : "A customer favorite today."),
  es: (t) => (t.length ? `Va con lo que te gusta: ${t.join(", ")}.` : "Uno de los favoritos de hoy."),
};

const TASTE_WORDS: Record<Lang, Partial<Record<Taste, string>>> = {
  en: { cheesy: "cheesy", creamy: "creamy", tomato: "tomato", meaty: "meaty", light: "light", fresh: "fresh", comfort: "comfort food", savory: "savory", spicy: "spicy", sweet: "sweet" },
  es: { cheesy: "con queso", creamy: "cremoso", tomato: "tomate", meaty: "con carne", light: "ligero", fresh: "fresco", comfort: "comfort food", savory: "salado", spicy: "picante", sweet: "dulce" },
};

/** Deterministic fallback: taste overlap, small boost for the chef's special, cheaper wins ties. */
export function rules(input: RecommendInput, candidates: Dish[], specialId?: string): RecommendResult {
  const scored = candidates
    .map((d) => {
      const overlap = d.tastes.filter((t) => input.likes.includes(t));
      return { d, overlap, score: overlap.length * 2 + (d.id === specialId ? 1 : 0) };
    })
    .sort((a, b) => b.score - a.score || a.d.price - b.d.price);
  const picks: typeof scored = [];
  for (const s of scored) {
    // variety: at most 2 from the same category
    if (picks.filter((p) => p.d.category === s.d.category).length < 2) picks.push(s);
    if (picks.length === 3) break;
  }
  return {
    source: "rules",
    suggestions: picks.map(({ d, overlap }) => ({
      dishId: d.id,
      reason: REASON[input.lang](overlap.map((t) => TASTE_WORDS[input.lang][t] ?? t)),
    })),
  };
}

