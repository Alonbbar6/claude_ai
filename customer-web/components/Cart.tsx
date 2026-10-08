"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { useApp } from "./AppProvider";
import { CloseButton, DishImage, Sheet, Stepper } from "./ui";

export function CartBar({ onOpen }: { onOpen: () => void }) {
  const { cart, t, price } = useApp();
  const count = cart.reduce((s, l) => s + l.quantity, 0);
  const total = cart.reduce((s, l) => s + l.unitPrice * l.quantity, 0);
  if (!count) return null;
  return (
    <div className="fixed inset-x-0 bottom-0 z-40 p-3 sm:p-4">
      <button
        type="button"
        onClick={onOpen}
        className="mx-auto flex w-full max-w-xl items-center justify-between rounded-full bg-night px-5 py-4 text-white shadow-2xl transition hover:scale-[1.01] active:scale-[.99]"
      >
        <span className="flex items-center gap-2 font-bold">
          <span className="grid h-7 min-w-7 place-items-center rounded-full bg-gold px-2 text-sm font-black text-night">{count}</span>
          {t("cart.view")}
        </span>
        <span className="font-black">{price(total)}</span>
      </button>
    </div>
  );
}

type Fulfillment = "to_go" | "for_here";

export interface CartPreset {
  fulfillment?: Fulfillment | null;
  table?: string | null;
}

export function CartSheet({
  open,
  onClose,
  restaurantName,
  preset,
}: {
  open: boolean;
  onClose: () => void;
  restaurantName: string;
  preset?: CartPreset | null;
}) {
  const { cart, t, L, price, updateQty, clearCart, customer, setActiveOrderId } = useApp();
  const router = useRouter();
  const [fulfillment, setFulfillment] = useState<Fulfillment>("to_go");
  const [table, setTable] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Set once the order is placed, so the emptied cart doesn't flash "Your order is empty" while we navigate.
  const [placed, setPlaced] = useState(false);
  useEffect(() => {
    if (open) setPlaced(false);
  }, [open]);
  const total = cart.reduce((s, l) => s + l.unitPrice * l.quantity, 0);

  // Voice can pre-select "to go / for here" and the table; the customer still confirms.
  useEffect(() => {
    if (!open || !preset) return;
    if (preset.fulfillment) setFulfillment(preset.fulfillment);
    if (preset.table) setTable(preset.table);
  }, [open, preset]);

  async function place() {
    if (!customer) return;
    setBusy(true);
    setError(null);
    try {
      const res = await fetch("/api/orders", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          customerId: customer.id,
          customerName: customer.name,
          fulfillment,
          tableNumber: fulfillment === "for_here" ? table : null,
          items: cart.map((l) => ({ menuItemId: l.menuItemId, quantity: l.quantity, modifiers: l.modifiers })),
        }),
      });
      const data = await res.json();
      if (res.status === 409 && data.error === "sold_out") {
        setError(t("cart.errorSoldOut", { items: (data.detail as string[]).join(", ") }));
        router.refresh();
        return;
      }
      if (!res.ok) throw new Error(data.message);
      setPlaced(true);
      setActiveOrderId(data.id);
      router.push(`/order/${data.id}`);
      clearCart();
    } catch {
      setError(t("cart.errorGeneric"));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Sheet open={open} onClose={onClose} label={t("cart.title")} wide>
      <div className="flex items-center justify-between border-b border-line p-5">
        <div>
          <h2 className="text-2xl font-black text-night">{t("cart.title")}</h2>
          <p className="text-sm text-ink-soft">{restaurantName}</p>
        </div>
        <CloseButton onClick={onClose} />
      </div>

      {cart.length === 0 ? (
        <p className="p-8 text-center text-ink-soft">{placed ? t("cart.placing") : t("cart.empty")}</p>
      ) : (
        <div className="space-y-6 p-5">
          <ul className="space-y-3">
            {cart.map((l) => (
              <li key={l.lineId} className="flex items-center gap-3">
                <DishImage src={l.image} alt="" ratio="1/1" className="w-16 shrink-0 rounded-xl" />
                <div className="min-w-0 flex-1">
                  <p className="truncate font-bold text-night">{L(l.name)}</p>
                  {l.modifierLabels.length > 0 && <p className="truncate text-xs text-ink-soft">{l.modifierLabels.map(L).join(", ")}</p>}
                  <p className="text-sm font-bold text-gold-text">{price(l.unitPrice * l.quantity)}</p>
                </div>
                <Stepper value={l.quantity} onChange={(n) => updateQty(l.lineId, n)} label={L(l.name)} />
              </li>
            ))}
          </ul>

          <fieldset>
            <legend className="mb-2 font-bold text-night">{t("cart.howTitle")}</legend>
            <div className="grid grid-cols-2 gap-3">
              {(
                [
                  ["to_go", "🥡", t("cart.toGo"), t("cart.toGoHint")],
                  ["for_here", "🍽️", t("cart.forHere"), t("cart.forHereHint")],
                ] as const
              ).map(([value, icon, label, hint]) => (
                <label
                  key={value}
                  className={`flex cursor-pointer flex-col items-center gap-1 rounded-2xl border-2 p-4 text-center transition ${
                    fulfillment === value ? "border-gold bg-gold-tint" : "border-line hover:border-gold/50"
                  }`}
                >
                  <input type="radio" name="fulfillment" value={value} checked={fulfillment === value} onChange={() => setFulfillment(value)} className="sr-only" />
                  <span className="text-3xl" aria-hidden>
                    {icon}
                  </span>
                  <span className="font-black text-night">{label}</span>
                  <span className="text-xs text-ink-soft">{hint}</span>
                </label>
              ))}
            </div>
            {fulfillment === "for_here" && (
              <label className="mt-3 block">
                <span className="text-sm font-semibold text-ink-soft">{t("cart.table")}</span>
                <input
                  value={table}
                  onChange={(e) => setTable(e.target.value.replace(/[^\w-]/g, "").slice(0, 8))}
                  inputMode="numeric"
                  className="mt-1 w-full rounded-xl border border-line bg-cream px-4 py-2.5 outline-none focus:border-gold focus:ring-2 focus:ring-gold/30"
                />
              </label>
            )}
          </fieldset>

          <div className="space-y-1 border-t border-line pt-4">
            <div className="flex justify-between text-lg font-black text-night">
              <span>{t("cart.total")}</span>
              <span>{price(total)}</span>
            </div>
            <p className="text-sm text-ink-soft">{t(fulfillment === "to_go" ? "cart.payNote.to_go" : "cart.payNote.for_here")}</p>
          </div>

          {error && <p className="rounded-xl bg-warn-tint px-4 py-3 text-sm font-semibold text-warn" role="alert">{error}</p>}

          <button type="button" className="btn-gold w-full py-4 text-lg" disabled={busy || !customer} onClick={place}>
            {busy ? t("cart.placing") : t("cart.place", { price: price(total) })}
          </button>
        </div>
      )}
    </Sheet>
  );
}
