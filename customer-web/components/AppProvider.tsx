"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import { LANG_COOKIE, translate, formatPrice, type Lang, type MessageKey } from "@/lib/i18n";
import type { Localized } from "@/lib/content";

export interface CustomerLite {
  id: string;
  name: string;
  taste?: { likes: string[]; avoid: string[] };
}

export interface CartLine {
  lineId: string;
  menuItemId: string;
  name: Localized;
  image: string;
  unitPrice: number;
  quantity: number;
  modifiers: string[];
  modifierLabels: Localized[];
}

interface AppState {
  lang: Lang;
  setLang: (l: Lang) => void;
  t: (key: MessageKey, vars?: Record<string, string | number>) => string;
  L: (v: Localized) => string;
  price: (n: number) => string;
  customer: CustomerLite | null;
  setCustomer: (c: CustomerLite | null) => void;
  ready: boolean;
  cart: CartLine[];
  addToCart: (line: Omit<CartLine, "lineId">) => void;
  updateQty: (lineId: string, quantity: number) => void;
  clearCart: () => void;
  activeOrderId: string | null;
  setActiveOrderId: (id: string | null) => void;
  tastesOpen: boolean;
  setTastesOpen: (open: boolean) => void;
}

const Ctx = createContext<AppState | null>(null);

const K = { customer: "bm_customer", cart: "bm_cart", order: "bm_active_order", lang: "bm_lang" };

function load<T>(key: string, fallback: T): T {
  try {
    const v = localStorage.getItem(key);
    return v ? (JSON.parse(v) as T) : fallback;
  } catch {
    return fallback;
  }
}
function save(key: string, value: unknown) {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, JSON.stringify(value));
  } catch {
    /* private mode: state just won't persist */
  }
}

export function AppProvider({ initialLang, children }: { initialLang: Lang; children: React.ReactNode }) {
  const [lang, setLangState] = useState<Lang>(initialLang);
  const [customer, setCustomerState] = useState<CustomerLite | null>(null);
  const [cart, setCart] = useState<CartLine[]>([]);
  const [activeOrderId, setActiveOrderIdState] = useState<string | null>(null);
  const [ready, setReady] = useState(false);
  const [tastesOpen, setTastesOpen] = useState(false);

  useEffect(() => {
    setCustomerState(load<CustomerLite | null>(K.customer, null));
    setCart(load<CartLine[]>(K.cart, []));
    setActiveOrderIdState(load<string | null>(K.order, null));
    setReady(true);
  }, []);

  useEffect(() => {
    if (ready) save(K.cart, cart);
  }, [cart, ready]);

  const setLang = useCallback(
    (l: Lang) => {
      setLangState(l);
      document.cookie = `${LANG_COOKIE}=${l}; path=/; max-age=31536000; samesite=lax`;
      document.documentElement.lang = l;
      if (customer)
        fetch(`/api/customers/${customer.id}`, {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ language: l }),
        }).catch(() => {});
    },
    [customer],
  );

  const setCustomer = useCallback((c: CustomerLite | null) => {
    setCustomerState(c);
    save(K.customer, c);
  }, []);

  const setActiveOrderId = useCallback((id: string | null) => {
    setActiveOrderIdState(id);
    save(K.order, id);
  }, []);

  const value = useMemo<AppState>(
    () => ({
      lang,
      setLang,
      t: (key, vars) => translate(lang, key, vars),
      L: (v) => v[lang] || v.en,
      price: (n) => formatPrice(n, lang),
      customer,
      setCustomer,
      ready,
      cart,
      addToCart: (line) =>
        setCart((c) => {
          const same = c.find(
            (x) => x.menuItemId === line.menuItemId && x.modifiers.join() === line.modifiers.join(),
          );
          if (same) return c.map((x) => (x === same ? { ...x, quantity: Math.min(20, x.quantity + line.quantity) } : x));
          return [...c, { ...line, lineId: `${line.menuItemId}:${line.modifiers.join("+")}:${Date.now()}` }];
        }),
      updateQty: (lineId, quantity) =>
        setCart((c) =>
          quantity <= 0 ? c.filter((x) => x.lineId !== lineId) : c.map((x) => (x.lineId === lineId ? { ...x, quantity: Math.min(20, quantity) } : x)),
        ),
      clearCart: () => setCart([]),
      activeOrderId,
      setActiveOrderId,
      tastesOpen,
      setTastesOpen,
    }),
    [lang, setLang, customer, setCustomer, ready, cart, activeOrderId, setActiveOrderId, tastesOpen],
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useApp() {
  const v = useContext(Ctx);
  if (!v) throw new Error("useApp must be used inside AppProvider");
  return v;
}
