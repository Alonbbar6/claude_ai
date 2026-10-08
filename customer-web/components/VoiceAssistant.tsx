"use client";

import Link from "next/link";
import { useState } from "react";
import type { Localized } from "@/lib/content";
import type { ViewDish } from "@/lib/types";
import { useApp } from "./AppProvider";
import type { CartPreset } from "./Cart";
import { useSpeech } from "./useSpeech";
import { avoidConflicts } from "@/lib/diet";

export const VOICE_ENABLED = process.env.NEXT_PUBLIC_VOICE_ORDERING === "on";

interface VoiceResult {
  intent: "add_to_order" | "build_meal" | "find_dish" | "unknown";
  items: { dishId: string; quantity: number }[];
  total: number | null;
  budget: number | null;
  fulfillment: "to_go" | "for_here" | null;
  tableNumber: string | null;
  matches: { dishId: string; restaurantId: string; name: Localized; image: string; open: boolean }[];
  reply: string;
}

/**
 * Floating mic. Speech → /api/voice → either fills the cart and lists what it added (with undo
 * and a button to review the order), or shows matching dishes. It never places an order by itself.
 */
export function VoiceAssistant({
  dishes,
  onOpenDish,
  onReviewCart,
}: {
  dishes: ViewDish[];
  onOpenDish: (d: ViewDish) => void;
  onReviewCart: (preset: CartPreset) => void;
}) {
  const { t, L, lang, price, cart, customer, addToCart, updateQty } = useApp();
  const avoid = customer?.taste?.avoid ?? [];
  const speech = useSpeech(lang);
  const [heard, setHeard] = useState("");
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<VoiceResult | null>(null);
  const [open, setOpen] = useState(false);
  // What the last voice request put in the cart, so the customer can see it and undo it.
  const [added, setAdded] = useState<{ dish: ViewDish; quantity: number }[]>([]);

  if (!speech.supported) return null;

  async function handle(text: string) {
    setHeard(text);
    setBusy(true);
    setResult(null);
    setAdded([]);
    try {
      const res = await fetch("/api/voice", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text, lang, avoid }),
      });
      if (!res.ok) throw new Error();
      const r: VoiceResult = await res.json();
      setResult(r);
      if ((r.intent === "add_to_order" || r.intent === "build_meal") && r.items.length) {
        const done: typeof added = [];
        for (const it of r.items) {
          const d = dishes.find((x) => x.id === it.dishId);
          if (!d) continue;
          // The cart caps a line at 20, so only count what actually fits.
          const have = cart.find((l) => l.menuItemId === d.id && l.modifiers.length === 0)?.quantity ?? 0;
          const quantity = Math.min(it.quantity, 20 - have);
          if (quantity <= 0) continue;
          addToCart({ menuItemId: d.id, name: d.name, image: d.image, unitPrice: d.price, quantity, modifiers: [], modifierLabels: [] });
          done.push({ dish: d, quantity });
        }
        setAdded(done);
      }
    } catch {
      setResult({ intent: "unknown", items: [], total: null, budget: null, fulfillment: null, tableNumber: null, matches: [], reply: t("voice.error.other") });
    } finally {
      setBusy(false);
    }
  }

  function undo() {
    for (const a of added) {
      const line = cart.find((l) => l.menuItemId === a.dish.id && l.modifiers.length === 0);
      if (line) updateQty(line.lineId, line.quantity - a.quantity);
    }
    setAdded([]);
    setResult(null);
    setHeard("");
  }

  function toggle() {
    if (speech.listening) return speech.stop();
    setOpen(true);
    setHeard("");
    setResult(null);
    setAdded([]);
    speech.start(handle);
  }

  const errorKey = speech.error ? (`voice.error.${speech.error}` as const) : null;
  const showBubble = open && (speech.listening || busy || heard || result || errorKey);

  return (
    <div className="fixed bottom-24 right-4 z-40 flex flex-col items-end gap-2 sm:bottom-28 sm:right-6">
      {showBubble && (
        <div className="relative w-[min(22rem,calc(100vw-2rem))] rounded-2xl bg-night p-4 text-sm text-white shadow-2xl" aria-live="polite">
          <button type="button" onClick={() => setOpen(false)} aria-label={t("menu.close")} className="absolute right-2 top-2 h-7 w-7 rounded-full text-white/60 hover:bg-white/10">
            ✕
          </button>
          {speech.listening ? (
            <p className="pr-6">
              <span className="mr-1 inline-block h-2 w-2 animate-pulse rounded-full bg-gold" /> {speech.interim || t("voice.listening")}
            </p>
          ) : errorKey && !heard ? (
            <p className="pr-6 text-gold">{t(errorKey)}</p>
          ) : (
            <div className="space-y-2 pr-4">
              {heard && (
                <p className="text-white/60">
                  {t("voice.youSaid")} “{heard}”
                </p>
              )}
              {busy && <p>{t("voice.thinking")}</p>}
              {result && <p className="font-semibold">{result.reply}</p>}
              {result && added.length > 0 && (
                <>
                  <ul className="rounded-xl bg-white/10 px-3 py-2">
                    <li className="text-xs font-bold uppercase tracking-wide text-white/60">{t("voice.added")}</li>
                    {added.map((a) => {
                      const clash = avoidConflicts(a.dish, avoid);
                      return (
                        <li key={a.dish.id} className="font-semibold">
                          {a.quantity}× {L(a.dish.name)}
                          {clash.length > 0 && (
                            <span className="ml-1 text-xs text-gold">⚠ {clash.map((x) => t(`allergen.${x}` as never)).join(" · ")}</span>
                          )}
                        </li>
                      );
                    })}
                    {result.total !== null && (
                      <li className="mt-1 border-t border-white/15 pt-1 text-xs text-white/70">
                        {result.budget !== null
                          ? t("voice.totalBudget", { total: price(result.total), budget: price(result.budget) })
                          : t("voice.total", { total: price(result.total) })}
                      </li>
                    )}
                  </ul>
                  <div className="flex gap-2">
                    <button type="button" onClick={undo} className="flex-1 rounded-full border border-white/30 py-2 text-sm font-bold hover:bg-white/10">
                      {t("voice.undo")}
                    </button>
                    <button type="button" onClick={() => onReviewCart({ fulfillment: result.fulfillment, table: result.tableNumber })} className="btn-gold flex-[2] py-2 text-sm">
                      {t("voice.review")} →
                    </button>
                  </div>
                </>
              )}
              {result && result.matches.length > 0 && (
                <div className="flex flex-wrap gap-2 pt-1">
                  {result.matches.map((m) => {
                    const local = m.open ? dishes.find((d) => d.id === m.dishId) : undefined;
                    const chip = (
                      <>
                        <img src={m.image} alt="" className="h-6 w-6 rounded-full object-cover" />
                        {L(m.name)}
                        {!m.open && <span className="text-white/50">🌙</span>}
                      </>
                    );
                    const cls = "inline-flex items-center gap-1.5 rounded-full bg-white/10 py-1 pl-1 pr-3 text-xs font-bold hover:bg-white/20";
                    return local ? (
                      <button key={m.restaurantId + m.dishId} type="button" className={cls} onClick={() => onOpenDish(local)}>
                        {chip}
                      </button>
                    ) : (
                      <Link key={m.restaurantId + m.dishId} href={`/r/${m.restaurantId}`} className={cls}>
                        {chip}
                      </Link>
                    );
                  })}
                </div>
              )}
            </div>
          )}
        </div>
      )}
      <button
        type="button"
        onClick={toggle}
        disabled={busy}
        aria-label={speech.listening ? t("voice.stop") : t("voice.start")}
        aria-pressed={speech.listening}
        className={`grid h-14 w-14 place-items-center rounded-full text-2xl shadow-2xl transition hover:scale-105 active:scale-95 disabled:opacity-60 ${
          speech.listening ? "animate-pulse bg-warn text-white" : "bg-gold text-night"
        }`}
      >
        {busy ? "…" : speech.listening ? "■" : "🎤"}
      </button>
    </div>
  );
}
