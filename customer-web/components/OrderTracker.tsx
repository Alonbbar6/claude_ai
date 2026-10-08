"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useApp } from "./AppProvider";
import { Header } from "./Header";
import { Gate } from "./Gate";
import { ViaBarmade } from "./ui";
import { MODIFIERS } from "@/lib/content";

interface Order {
  id: string;
  order_number: number;
  status: "RECEIVED" | "PREPARING" | "READY" | "COMPLETED" | "CANCELLED";
  fulfillment: "to_go" | "for_here";
  table_number: string | null;
  customer_name: string;
  placed_at: string;
  items: { menuItemId: string; name: string; quantity: number; modifiers: string[]; lineTotal: number }[];
  total: number;
  status_history: { status: string; at: string }[];
}

const STEPS = ["RECEIVED", "PREPARING", "READY", "COMPLETED"] as const;

export function OrderTracker({ id }: { id: string }) {
  const { t, price, lang } = useApp();
  const [order, setOrder] = useState<Order | null>(null);
  const [missing, setMissing] = useState(false);
  const [names, setNames] = useState<Record<string, { en: string; es: string }>>({});

  useEffect(() => {
    fetch("/api/menu")
      .then((r) => r.json())
      .then((m: { dishes: { id: string; name: { en: string; es: string } }[] }) =>
        setNames(Object.fromEntries(m.dishes.map((d) => [d.id, d.name]))),
      )
      .catch(() => {});
  }, []);

  useEffect(() => {
    let stop = false;
    let timer: ReturnType<typeof setTimeout>;
    async function poll() {
      try {
        const res = await fetch(`/api/orders/${id}`, { cache: "no-store" });
        if (res.status === 404) return setMissing(true);
        if (res.ok) {
          const o: Order = await res.json();
          if (!stop) setOrder(o);
          if (o.status === "COMPLETED" || o.status === "CANCELLED") return;
        }
      } catch {
        /* keep polling through network blips */
      }
      // Every 4 s while visible; slower in a background tab (shared Firestore read quota).
      if (!stop) timer = setTimeout(poll, document.hidden ? 20_000 : 4000);
    }
    poll();
    return () => {
      stop = true;
      clearTimeout(timer);
    };
  }, [id]);

  const at = (s: string) => order?.status_history.find((h) => h.status === s)?.at;
  const time = (iso?: string) =>
    iso ? new Date(iso).toLocaleTimeString(lang === "es" ? "es-US" : "en-US", { hour: "numeric", minute: "2-digit" }) : "";
  const current = order ? STEPS.indexOf(order.status as (typeof STEPS)[number]) : -1;

  return (
    <Gate>
      <Header />
      <main className="mx-auto max-w-xl px-4 pb-16 pt-6">
        {missing ? (
          <p className="py-20 text-center text-ink-soft">{t("order.notFound")}</p>
        ) : !order ? (
          <div className="img-wrap mt-10 h-64 rounded-3xl" />
        ) : (
          <>
            <div className="card p-6 text-center">
              <ViaBarmade />
              <p className="mt-4 text-sm font-bold uppercase tracking-widest text-ink-faint">{t("order.thanks", { name: order.customer_name })}</p>
              <h1 className="mt-1 text-5xl font-black text-night">#{order.order_number}</h1>
              <p className="mt-1 text-ink-soft">{t("order.sentTo", { restaurant: "Trattoria Little Italy" })}</p>
              <div className="mt-4 flex flex-wrap justify-center gap-2">
                <span className="chip bg-gold-tint text-gold-text">
                  {order.fulfillment === "to_go" ? "🥡" : "🍽️"} {t(`order.fulfillment.${order.fulfillment}` as never)}
                </span>
                {order.table_number && <span className="chip bg-cream text-ink">{t("order.table", { n: order.table_number })}</span>}
              </div>
            </div>

            {order.status === "CANCELLED" ? (
              <p className="mt-6 rounded-2xl bg-warn-tint p-4 text-center font-bold text-warn">{t("order.status.CANCELLED")}</p>
            ) : (
              <ol className="card mt-6 p-6" aria-label="Order status">
                {STEPS.map((s, i) => {
                  const done = i <= current;
                  const now = i === current;
                  const label =
                    s === "READY" ? t(`order.step.READY.${order.fulfillment}` as never) : t(`order.step.${s}` as never);
                  return (
                    <li key={s} className="relative flex gap-4 pb-6 last:pb-0">
                      {i < STEPS.length - 1 && (
                        <span className={`absolute left-[15px] top-8 h-[calc(100%-2rem)] w-0.5 ${i < current ? "bg-gold" : "bg-line"}`} aria-hidden />
                      )}
                      <span
                        className={`relative grid h-8 w-8 shrink-0 place-items-center rounded-full text-sm font-black transition ${
                          done ? "bg-gold text-night" : "bg-cream text-ink-faint"
                        } ${now && s !== "COMPLETED" ? "ring-4 ring-gold/30" : ""}`}
                      >
                        {done && !now ? "✓" : i + 1}
                      </span>
                      <div className="pt-1">
                        <p className={`font-bold ${done ? "text-night" : "text-ink-faint"}`}>{t(`order.status.${s}` as never)}</p>
                        {now && <p className="text-sm text-ink-soft">{label}</p>}
                        {at(s) && <p className="text-xs text-ink-faint">{time(at(s))}</p>}
                      </div>
                    </li>
                  );
                })}
                {order.status !== "COMPLETED" && (
                  <p className="mt-2 flex items-center gap-2 text-xs text-ink-faint">
                    <span className="h-2 w-2 animate-pulse rounded-full bg-fresh" /> {t("order.live")}
                  </p>
                )}
              </ol>
            )}

            <section className="card mt-6 p-6">
              <h2 className="mb-3 font-black text-night">{t("order.items")}</h2>
              <ul className="space-y-2">
                {order.items.map((it, i) => (
                  <li key={i} className="flex justify-between gap-3">
                    <span>
                      <b>{it.quantity}×</b> {names[it.menuItemId]?.[lang] ?? it.name}
                      {it.modifiers.length > 0 && <span className="text-sm text-ink-soft"> · {it.modifiers.map((m) => (MODIFIERS[m] ? MODIFIERS[m].label[lang] : m)).join(", ")}</span>}
                    </span>
                    <span className="font-semibold">{price(it.lineTotal)}</span>
                  </li>
                ))}
              </ul>
              <div className="mt-3 flex justify-between border-t border-line pt-3 text-lg font-black">
                <span>{t("cart.total")}</span>
                <span>{price(order.total)}</span>
              </div>
              <p className="mt-1 text-sm text-ink-soft">{t(order.fulfillment === "to_go" ? "cart.payNote.to_go" : "cart.payNote.for_here")}</p>
            </section>

            <Link href="/r/trattoria-little-italy" className="btn-ghost mt-6 w-full">
              ← {t("order.back")}
            </Link>
          </>
        )}
      </main>
    </Gate>
  );
}
