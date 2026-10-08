"use client";

import { useEffect, useState } from "react";
import type { ViewDish } from "@/lib/types";
import { useApp } from "./AppProvider";
import { DishCard } from "./MenuView";

interface Suggestion {
  dishId: string;
  reason: string;
}

/** "Picked for you": taste-based suggestions, plus a free-text craving box. */
export function ForYou({ dishes, onOpen }: { dishes: ViewDish[]; onOpen: (d: ViewDish) => void }) {
  const { t, lang, customer, setTastesOpen } = useApp();
  const [items, setItems] = useState<Suggestion[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [craving, setCraving] = useState("");
  const likes = customer?.taste?.likes ?? [];
  const avoid = customer?.taste?.avoid ?? [];
  const hasTaste = likes.length > 0 || avoid.length > 0;
  const tasteKey = JSON.stringify([likes, avoid, lang]);

  async function load(withCraving?: string) {
    setLoading(true);
    try {
      const res = await fetch("/api/recommend", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ likes, avoid, lang, craving: withCraving }),
      });
      const data = await res.json();
      setItems(res.ok ? data.suggestions : []);
    } catch {
      setItems([]);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    if (hasTaste) load();
    else setItems(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tasteKey]);

  const picks = (items ?? [])
    .map((s) => ({ s, dish: dishes.find((d) => d.id === s.dishId) }))
    .filter((x): x is { s: Suggestion; dish: ViewDish } => !!x.dish);

  return (
    <section className="px-4 pt-6 sm:px-6">
      <div className="rounded-3xl bg-night p-4 text-white sm:p-6">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-xl font-black">
              <span className="text-gold">✨</span> {t("ai.title")}
            </h2>
            <p className="text-sm text-white/70">{t("ai.subtitle")}</p>
          </div>
          <button type="button" onClick={() => setTastesOpen(true)} className="shrink-0 rounded-full border border-white/30 px-3 py-1.5 text-xs font-bold hover:bg-white/10">
            {t("taste.edit")}
          </button>
        </div>

        <form
          className="mt-4 flex gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            if (craving.trim()) load(craving.trim());
          }}
        >
          <label className="sr-only" htmlFor="craving">
            {t("ai.ask")}
          </label>
          <input
            id="craving"
            value={craving}
            onChange={(e) => setCraving(e.target.value)}
            maxLength={200}
            placeholder={`${t("ai.ask")} ${t("ai.askPlaceholder")}`}
            className="min-w-0 flex-1 rounded-full border border-white/20 bg-white/10 px-4 py-2.5 text-sm text-white placeholder:text-white/50 outline-none focus:border-gold"
          />
          <button type="submit" disabled={!craving.trim() || loading} className="btn-gold px-4 py-2.5 text-sm">
            {t("ai.askCta")}
          </button>
        </form>

        {!hasTaste && items === null && !loading ? (
          <button type="button" onClick={() => setTastesOpen(true)} className="mt-4 w-full rounded-2xl border border-dashed border-gold/60 px-4 py-4 text-left font-bold text-gold hover:bg-white/5">
            {t("ai.setTastes")} →
          </button>
        ) : loading ? (
          <div className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-3" aria-live="polite">
            <p className="sr-only">{t("ai.loading")}</p>
            {[0, 1, 2].map((i) => (
              <div key={i} className={`img-wrap h-48 rounded-2xl opacity-20 ${i === 2 ? "hidden sm:block" : ""}`} />
            ))}
          </div>
        ) : items && picks.length === 0 ? (
          <p className="mt-4 rounded-2xl bg-white/10 px-4 py-3 text-sm text-white/85">{t("ai.none")}</p>
        ) : (
          picks.length > 0 && (
            <div className="no-scrollbar -mx-4 mt-4 flex snap-x gap-3 overflow-x-auto px-4 sm:mx-0 sm:grid sm:grid-cols-3 sm:px-0">
              {picks.map(({ s, dish }) => (
                <div key={dish.id} className="w-[70%] shrink-0 snap-start text-ink sm:w-auto">
                  <DishCard dish={dish} onOpen={() => onOpen(dish)} badge={t("menu.forYou")} />
                  <p className="mt-2 px-1 text-sm text-white/85">“{s.reason}”</p>
                </div>
              ))}
            </div>
          )
        )}
      </div>
    </section>
  );
}
