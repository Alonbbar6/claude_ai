import "server-only";
import { randomUUID } from "node:crypto";
import { store } from "./store";
import { TASTES, type Taste } from "./content";
import { isLang, type Lang } from "./i18n";
import type { Allergen } from "./catalog";

export interface TasteProfile {
  likes: Taste[];
  avoid: Allergen[];
  vegetarian?: boolean;
}

export interface Customer {
  id: string;
  display_name: string;
  language: Lang;
  taste: TasteProfile;
  created_at: string;
}

const AVOIDABLE: Allergen[] = ["dairy", "gluten", "egg", "fish", "pork", "meat"];

export function cleanName(v: unknown) {
  return typeof v === "string" ? v.replace(/\s+/g, " ").trim().slice(0, 40) : "";
}

export function cleanTaste(v: unknown): TasteProfile {
  const t = (v ?? {}) as Partial<TasteProfile>;
  return {
    likes: (Array.isArray(t.likes) ? t.likes : []).filter((x): x is Taste => TASTES.includes(x as Taste)),
    avoid: (Array.isArray(t.avoid) ? t.avoid : []).filter((x): x is Allergen => AVOIDABLE.includes(x as Allergen)),
    vegetarian: t.vegetarian === true,
  };
}

export async function createCustomer(name: string, language: Lang): Promise<Customer> {
  return store().insertCustomer({
    id: randomUUID(),
    display_name: name,
    language,
    taste: { likes: [], avoid: [], vegetarian: false },
    created_at: new Date().toISOString(),
  });
}

export async function getCustomer(id: string): Promise<Customer | null> {
  if (!/^[0-9a-f-]{36}$/i.test(id)) return null;
  const c = await store().getCustomer(id);
  return c && { ...c, language: isLang(c.language) ? c.language : "en", taste: cleanTaste(c.taste) };
}

export async function updateCustomer(id: string, patch: { language?: unknown; taste?: unknown; name?: unknown }) {
  const current = await getCustomer(id);
  if (!current) return null;
  return store().saveCustomer({
    ...current,
    display_name: cleanName(patch.name) || current.display_name,
    language: isLang(patch.language) ? patch.language : current.language,
    taste: patch.taste === undefined ? current.taste : cleanTaste(patch.taste),
  });
}
