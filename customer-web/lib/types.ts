// Client-safe shapes shared between server pages and client components.
import type { Localized, Taste } from "./content";

export type Allergen = "dairy" | "gluten" | "egg" | "fish" | "pork" | "meat";

export interface ViewDish {
  id: string;
  name: Localized;
  description: Localized;
  category: string;
  price: number;
  image: string;
  tastes: Taste[];
  allergens: Allergen[];
  vegetarian: boolean | null; // null = unknown (showcase restaurants)
  modifiers: { id: string; label: Localized; price: number }[];
  servingsLeft: number | null;
  status: "available" | "low" | "sold_out";
}

export interface ViewSpecial {
  dishId: string;
  reason: Localized;
}

export interface ViewRestaurant {
  id: string;
  name: string;
  cuisine: Localized;
  neighborhood: string;
  cover: string;
  tagline: Localized;
  acceptsOrders: boolean;
  prepMinutes?: number;
}
