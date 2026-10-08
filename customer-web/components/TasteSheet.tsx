"use client";

import { useEffect, useState } from "react";
import { TASTES } from "@/lib/content";
import type { Allergen } from "@/lib/types";
import { useApp } from "./AppProvider";
import { CloseButton, Sheet } from "./ui";

const AVOID: Allergen[] = ["dairy", "gluten", "egg", "fish", "pork", "meat"];

export function TasteSheet() {
  const { t, customer, setCustomer, tastesOpen, setTastesOpen } = useApp();
  const [likes, setLikes] = useState<string[]>([]);
  const [avoid, setAvoid] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (tastesOpen) {
      setLikes(customer?.taste?.likes ?? []);
      setAvoid(customer?.taste?.avoid ?? []);
    }
  }, [tastesOpen, customer]);

  const toggle = (list: string[], set: (v: string[]) => void, v: string) =>
    set(list.includes(v) ? list.filter((x) => x !== v) : [...list, v]);

  async function save() {
    if (!customer) return;
    setBusy(true);
    const taste = { likes, avoid };
    // Optimistic: suggestions update right away even if the network is slow.
    setCustomer({ ...customer, taste });
    setTastesOpen(false);
    await fetch(`/api/customers/${customer.id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ taste }),
    }).catch(() => {});
    setBusy(false);
  }

  return (
    <Sheet open={tastesOpen} onClose={() => setTastesOpen(false)} label={t("taste.title")}>
      <div className="space-y-5 p-5">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-2xl font-black text-night">{t("taste.title")}</h2>
            <p className="text-ink-soft">{t("taste.subtitle")}</p>
          </div>
          <CloseButton onClick={() => setTastesOpen(false)} />
        </div>
        <div className="flex flex-wrap gap-2">
          {TASTES.map((x) => (
            <button
              key={x}
              type="button"
              aria-pressed={likes.includes(x)}
              onClick={() => toggle(likes, setLikes, x)}
              className={`rounded-full border-2 px-4 py-2 font-bold transition ${
                likes.includes(x) ? "border-gold bg-gold text-night" : "border-line bg-white text-ink hover:border-gold/60"
              }`}
            >
              {t(`taste.${x}` as never)}
            </button>
          ))}
        </div>
        <div>
          <h3 className="mb-2 font-bold text-night">{t("taste.avoid")}</h3>
          <div className="flex flex-wrap gap-2">
            {AVOID.map((x) => (
              <button
                key={x}
                type="button"
                aria-pressed={avoid.includes(x)}
                onClick={() => toggle(avoid, setAvoid, x)}
                className={`rounded-full border-2 px-4 py-2 text-sm font-bold transition ${
                  avoid.includes(x) ? "border-warn bg-warn-tint text-warn" : "border-line bg-white text-ink-soft hover:border-warn/50"
                }`}
              >
                {avoid.includes(x) ? "🚫 " : ""}
                {t(`allergen.${x}` as never)}
              </button>
            ))}
          </div>
        </div>
        <div className="flex gap-3 pt-2">
          <button type="button" className="btn-ghost flex-1" onClick={() => setTastesOpen(false)}>
            {t("taste.skip")}
          </button>
          <button type="button" className="btn-gold flex-1" disabled={busy} onClick={save}>
            {t("taste.save")}
          </button>
        </div>
      </div>
    </Sheet>
  );
}
