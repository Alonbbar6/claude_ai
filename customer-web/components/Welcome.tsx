"use client";

import { useState } from "react";
import { useApp } from "./AppProvider";
import { LangToggle, Logo } from "./Header";

export function Welcome() {
  const { t, lang, setCustomer } = useApp();
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim()) return;
    setBusy(true);
    setError(false);
    try {
      const res = await fetch("/api/customers", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name, language: lang }),
      });
      if (!res.ok) throw new Error();
      const c = await res.json();
      setCustomer({ id: c.id, name: c.display_name });
    } catch {
      setError(true);
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="relative min-h-dvh overflow-hidden bg-night">
      <img
        src="/images/covers/trattoria.jpg"
        alt=""
        className="absolute inset-0 h-full w-full object-cover opacity-55"
      />
      <div className="absolute inset-0 bg-gradient-to-t from-night via-night/70 to-night/20" />
      <div className="relative mx-auto flex min-h-dvh max-w-md flex-col px-5 pb-10 pt-5">
        <div className="flex items-center justify-between">
          <Logo light />
          <LangToggle light />
        </div>
        <div className="mt-auto">
          <h1 className="text-4xl font-black leading-tight text-white">{t("welcome.title")}</h1>
          <p className="mt-3 text-lg text-white/80">{t("welcome.subtitle")}</p>
          <form onSubmit={submit} className="mt-8 rounded-2xl bg-white p-5 shadow-card">
            <label htmlFor="name" className="text-sm font-bold text-ink">
              {t("welcome.nameLabel")}
            </label>
            <input
              id="name"
              autoComplete="given-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              maxLength={40}
              placeholder={t("welcome.namePlaceholder")}
              className="mt-2 w-full rounded-xl border border-line bg-cream px-4 py-3 text-lg outline-none transition focus:border-gold focus:ring-2 focus:ring-gold/30"
            />
            {error && <p className="mt-2 text-sm text-warn">{t("cart.errorGeneric")}</p>}
            <button type="submit" disabled={!name.trim() || busy} className="btn-gold mt-4 w-full text-lg">
              {t("welcome.cta")} →
            </button>
            <p className="mt-3 text-center text-xs text-ink-faint">{t("welcome.privacy")}</p>
          </form>
        </div>
      </div>
    </main>
  );
}
