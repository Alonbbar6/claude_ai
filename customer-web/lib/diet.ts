// Client-safe: which of the customer's "avoid" choices a dish conflicts with (from recipe ingredients).
import type { Allergen } from "./types";

export function avoidConflicts(dish: { allergens: Allergen[]; vegetarian: boolean | null }, avoid: readonly string[]): Allergen[] {
  const hits = dish.allergens.filter((a) => avoid.includes(a));
  // "meat" isn't listed as an allergen on the dish; avoiding it means vegetarian dishes only.
  if (avoid.includes("meat") && dish.vegetarian === false) hits.push("meat");
  return hits;
}
