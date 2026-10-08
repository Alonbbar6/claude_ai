"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import type { ViewDish } from "@/lib/types";
import { useApp } from "./AppProvider";
import { DemoFooter, Header } from "./Header";
import { Gate } from "./Gate";
import { DishImage, Stepper } from "./ui";

interface Line {
  menuItemId: string;
  quantity: number;
  modifiers: string[];
}
interface Group {
  code: string;
  hostId: string;
  status: "open" | "placed";
  split: "by_item" | "equal";
  fulfillment: "to_go" | "for_here";
  tableNumber: string | null;
  members: { id: string; name: string; items: Line[]; paid: boolean }[];
  orderId: string | null;
  bill: { total: number; perMember: { id: string; name: string; subtotal: number; owes: number; paid: boolean }[] };
  order: { id: string; order_number: number; status: string } | null;
}

const GROUPS_KEY = "bm_groups";

/** Remember groups this device is in, so the orders bar can show a group order to every member. */
export function rememberGroup(code: string) {
  try {
    const list: string[] = JSON.parse(localStorage.getItem(GROUPS_KEY) ?? "[]");
    localStorage.setItem(GROUPS_KEY, JSON.stringify([code, ...list.filter((c) => c !== code)].slice(0, 5)));
  } catch {
    /* private mode */
  }
}

async function call(path: string, method: string, body?: unknown) {
  const res = await fetch(`/api/groups${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw Object.assign(new Error(data.message ?? "error"), { data, status: res.status });
  return data;
}

/** Start a group, or join one with a code. Shown on the restaurant menu. */
export function GroupEntry() {
  const { t, customer } = useApp();
  const router = useRouter();
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);

  async function start() {
    if (!customer) return;
    setBusy(true);
    try {
      const g: Group = await call("", "POST", { customerId: customer.id, name: customer.name });
      rememberGroup(g.code);
      router.push(`/g/${g.code}`);
    } catch {
      setBusy(false);
    }
  }

  return (
    <div className="mx-4 mt-4 flex flex-col gap-3 rounded-2xl border border-line bg-white p-4 sm:mx-6 sm:flex-row sm:items-center">
      <div className="flex-1">
        <p className="font-black text-night">👥 {t("group.start")}</p>
        <p className="text-sm text-ink-soft">{t("group.startHint")}</p>
      </div>
      <div className="flex gap-2">
        <button type="button" className="btn-gold px-4 py-2 text-sm" disabled={busy} onClick={start}>
          {t("group.start")}
        </button>
        <form
          className="flex gap-1"
          onSubmit={(e) => {
            e.preventDefault();
            if (code.trim().length === 4) router.push(`/g/${code.trim().toUpperCase()}`);
          }}
        >
          <input
            value={code}
            onChange={(e) => setCode(e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 4))}
            placeholder={t("group.codePlaceholder")}
            aria-label={t("group.codePlaceholder")}
            className="w-20 rounded-full border border-line bg-cream px-3 py-2 text-center text-sm font-bold uppercase tracking-widest outline-none focus:border-gold"
          />
          <button type="submit" className="btn-ghost px-3 py-2 text-sm" disabled={code.length !== 4}>
            {t("group.join")}
          </button>
        </form>
      </div>
    </div>
  );
}

export function GroupOrder({ code, dishes }: { code: string; dishes: ViewDish[] }) {
  const { t, L, price, customer, setActiveOrderId } = useApp();
  const [group, setGroup] = useState<Group | null>(null);
  const [missing, setMissing] = useState(false);
  const [mine, setMine] = useState<Line[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const saveTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const editing = useRef(false);

  const me = group?.members.find((m) => m.id === customer?.id);
  const isHost = !!customer && group?.hostId === customer.id;
  const host = group?.members.find((m) => m.id === group.hostId);
  const open = group?.status === "open";
  const dishById = new Map(dishes.map((d) => [d.id, d]));

  // Live updates: everyone sees each other's dishes and the order status.
  useEffect(() => {
    let stop = false;
    let timer: ReturnType<typeof setTimeout>;
    async function poll() {
      try {
        const g: Group = await call(`/${code}`, "GET");
        if (!stop) setGroup(g);
      } catch (e) {
        if ((e as { status?: number }).status === 404 && !stop) setMissing(true);
      }
      if (!stop) timer = setTimeout(poll, document.hidden ? 15_000 : 3000);
    }
    poll();
    return () => {
      stop = true;
      clearTimeout(timer);
    };
  }, [code]);

  // My dishes start from the server copy; while I'm editing, my local copy wins.
  useEffect(() => {
    if (me && !editing.current) setMine(me.items);
  }, [me]);

  useEffect(() => {
    if (me) rememberGroup(code);
  }, [me, code]);

  async function join() {
    if (!customer) return;
    setBusy(true);
    setError(null);
    try {
      setGroup(await call(`/${code}/join`, "POST", { customerId: customer.id, name: customer.name }));
      rememberGroup(code);
    } catch {
      setError(t("group.errorJoin"));
    } finally {
      setBusy(false);
    }
  }

  function setQty(menuItemId: string, quantity: number) {
    if (!customer || !open) return;
    const next = [...(mine ?? []).filter((l) => l.menuItemId !== menuItemId)];
    if (quantity > 0) next.push({ menuItemId, quantity, modifiers: [] });
    next.sort((a, b) => a.menuItemId.localeCompare(b.menuItemId));
    setMine(next);
    editing.current = true;
    clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(async () => {
      try {
        setGroup(await call(`/${code}/items`, "PUT", { customerId: customer.id, items: next }));
      } catch (e) {
        setError((e as Error).message);
      } finally {
        editing.current = false;
      }
    }, 500);
  }

  async function hostUpdate(body: Record<string, unknown>) {
    if (!customer) return;
    try {
      setGroup(await call(`/${code}`, "PATCH", { customerId: customer.id, ...body }));
    } catch (e) {
      setError((e as Error).message);
    }
  }

  async function send() {
    if (!customer) return;
    setBusy(true);
    setError(null);
    try {
      const g: Group = await call(`/${code}/place`, "POST", { customerId: customer.id });
      setGroup(g);
      if (g.orderId) setActiveOrderId(g.orderId);
    } catch (e) {
      const d = (e as { data?: { error?: string; detail?: string[] } }).data;
      setError(d?.error === "sold_out" ? t("cart.errorSoldOut", { items: (d.detail ?? []).join(", ") }) : (e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function share() {
    const url = `${window.location.origin}/g/${code}`;
    try {
      if (navigator.share) await navigator.share({ title: "BarMade", text: t("group.shareText", { url }), url });
      else {
        await navigator.clipboard.writeText(url);
        setCopied(true);
        setTimeout(() => setCopied(false), 2000);
      }
    } catch {
      /* share sheet dismissed */
    }
  }

  const orderable = dishes.filter((d) => d.status !== "sold_out");
  const myBill = group?.bill.perMember.find((p) => p.id === customer?.id);

  return (
    <Gate>
      <Header />
      <main className="mx-auto max-w-3xl px-4 pb-16 pt-6">
        {missing ? (
          <p className="py-20 text-center text-ink-soft">{t("group.notFound")}</p>
        ) : !group ? (
          <div className="img-wrap h-48 rounded-3xl" />
        ) : (
          <div className="space-y-6">
            {/* Code + share */}
            <section className="card p-5 text-center">
              <p className="text-sm font-bold uppercase tracking-widest text-ink-faint">👥 {t("group.title")} · Trattoria Little Italy</p>
              <p className="mt-1 text-5xl font-black tracking-[0.3em] text-night">{group.code}</p>
              <div className="mt-3 flex flex-wrap justify-center gap-2">
                {group.members.map((m) => (
                  <span key={m.id} className={`chip ${m.id === customer?.id ? "bg-gold text-night" : "bg-cream text-ink"}`}>
                    {m.name}
                    {m.id === group.hostId && ` · ${t("group.host")}`}
                  </span>
                ))}
              </div>
              {open && (
                <button type="button" onClick={share} className="btn-ghost mt-4 text-sm">
                  🔗 {copied ? t("group.copied") : t("group.share")}
                </button>
              )}
            </section>

            {/* Sent: order status + what I pay */}
            {group.status === "placed" && group.order && (
              <section className="card space-y-2 p-5 text-center">
                <p className="text-lg font-black text-night">✅ {t("group.sent", { n: group.order.order_number || "…" })}</p>
                <span className="chip bg-gold-tint text-gold-text">{t(`order.status.${group.order.status}` as never)}</span>
                {myBill && <p className="text-2xl font-black text-night">{t("group.youPay", { price: price(myBill.owes) })}</p>}
                <p className="text-sm text-ink-soft">{t(`group.payWhere.${group.fulfillment}` as never)}</p>
                <Link href={`/order/${group.order.id}`} className="btn-gold mt-2">
                  {t("group.track")} →
                </Link>
              </section>
            )}

            {!me && open && (
              <section className="card p-5 text-center">
                <button type="button" className="btn-gold w-full py-4 text-lg" disabled={busy} onClick={join}>
                  {t("group.joinCta", { name: host?.name ?? "" })}
                </button>
              </section>
            )}

            {/* My dishes */}
            {me && open && (
              <section className="card p-5">
                <h2 className="mb-3 text-lg font-black text-night">{t("group.myDishes")}</h2>
                <ul className="divide-y divide-line">
                  {orderable.map((d) => {
                    const q = mine?.find((l) => l.menuItemId === d.id)?.quantity ?? 0;
                    return (
                      <li key={d.id} className="flex items-center gap-3 py-2">
                        <DishImage src={d.image} alt="" ratio="1/1" className="w-12 shrink-0 rounded-lg" />
                        <div className="min-w-0 flex-1">
                          <p className="truncate font-bold text-night">{L(d.name)}</p>
                          <p className="text-sm font-bold text-gold-text">{price(d.price)}</p>
                        </div>
                        <Stepper value={q} onChange={(n) => setQty(d.id, n)} max={Math.min(20, d.servingsLeft ?? 20)} label={L(d.name)} />
                      </li>
                    );
                  })}
                </ul>
              </section>
            )}

            {/* Everyone's dishes + bill */}
            <section className="card p-5">
              <h2 className="mb-3 text-lg font-black text-night">{t("group.everyone")}</h2>
              <ul className="space-y-3">
                {group.members.map((m) => {
                  const bill = group.bill.perMember.find((p) => p.id === m.id)!;
                  return (
                    <li key={m.id} className="rounded-xl bg-cream p-3">
                      <div className="flex items-center justify-between gap-2">
                        <p className="font-black text-night">
                          {m.id === customer?.id ? `${m.name} (${t("group.you")})` : m.name}
                        </p>
                        <div className="flex items-center gap-2">
                          <span className="text-sm text-ink-soft">
                            {t("group.owes")} <b className="text-night">{price(bill.owes)}</b>
                          </span>
                          {group.status === "placed" &&
                            (isHost ? (
                              <button
                                type="button"
                                onClick={() => hostUpdate({ memberId: m.id, paid: !bill.paid })}
                                className={`chip ${bill.paid ? "bg-fresh text-white" : "border border-line bg-white text-ink"}`}
                              >
                                {bill.paid ? `✓ ${t("group.paid")}` : t("group.markPaid")}
                              </button>
                            ) : (
                              bill.paid && <span className="chip bg-fresh text-white">✓ {t("group.paid")}</span>
                            ))}
                        </div>
                      </div>
                      {m.items.length ? (
                        <p className="mt-1 text-sm text-ink-soft">
                          {m.items.map((it) => `${it.quantity}× ${dishById.get(it.menuItemId) ? L(dishById.get(it.menuItemId)!.name) : it.menuItemId}`).join(" · ")}
                        </p>
                      ) : (
                        <p className="mt-1 text-sm italic text-ink-faint">{t("group.nothingYet")}</p>
                      )}
                    </li>
                  );
                })}
              </ul>

              {/* Split mode */}
              <fieldset className="mt-5">
                <legend className="mb-2 font-bold text-night">{t("group.split")}</legend>
                <div className="grid grid-cols-2 gap-2">
                  {(["by_item", "equal"] as const).map((mode) => (
                    <label
                      key={mode}
                      className={`rounded-xl border-2 px-3 py-2 text-center text-sm font-bold transition ${
                        group.split === mode ? "border-gold bg-gold-tint text-night" : "border-line text-ink-soft"
                      } ${isHost ? "cursor-pointer" : "cursor-default opacity-80"}`}
                    >
                      <input type="radio" name="split" className="sr-only" disabled={!isHost} checked={group.split === mode} onChange={() => hostUpdate({ split: mode })} />
                      {mode === "by_item" ? `🧾 ${t("group.byItem")}` : `➗ ${t("group.equal")}`}
                    </label>
                  ))}
                </div>
              </fieldset>
              <div className="mt-4 flex justify-between border-t border-line pt-3 text-lg font-black text-night">
                <span>{t("group.total")}</span>
                <span>{price(group.bill.total)}</span>
              </div>
            </section>

            {/* Host: how + send */}
            {open && isHost && (
              <section className="card space-y-4 p-5">
                <div className="grid grid-cols-2 gap-2">
                  {(["to_go", "for_here"] as const).map((f) => (
                    <button
                      key={f}
                      type="button"
                      onClick={() => hostUpdate({ fulfillment: f })}
                      className={`rounded-2xl border-2 p-3 font-black ${group.fulfillment === f ? "border-gold bg-gold-tint" : "border-line"}`}
                    >
                      {f === "to_go" ? `🥡 ${t("cart.toGo")}` : `🍽️ ${t("cart.forHere")}`}
                    </button>
                  ))}
                </div>
                {group.fulfillment === "for_here" && (
                  <input
                    defaultValue={group.tableNumber ?? ""}
                    onBlur={(e) => hostUpdate({ tableNumber: e.target.value })}
                    placeholder={t("cart.table")}
                    inputMode="numeric"
                    className="w-full rounded-xl border border-line bg-cream px-4 py-2.5 outline-none focus:border-gold"
                  />
                )}
                <button type="button" className="btn-gold w-full py-4 text-lg" disabled={busy || group.bill.total === 0} onClick={send}>
                  {busy ? t("group.sending") : t("group.send", { price: price(group.bill.total) })}
                </button>
              </section>
            )}
            {open && me && !isHost && <p className="text-center text-sm text-ink-soft">{t("group.waitHost", { name: host?.name ?? "" })}</p>}

            {error && (
              <p className="rounded-xl bg-warn-tint px-4 py-3 text-sm font-semibold text-warn" role="alert">
                {error}
              </p>
            )}
          </div>
        )}
        <DemoFooter />
      </main>
    </Gate>
  );
}
