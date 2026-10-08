"use client";

import { useApp } from "./AppProvider";
import { Logo } from "./Header";
import { TasteSheet } from "./TasteSheet";
import { Welcome } from "./Welcome";

/** Requires a (name-only) account before showing the app. */
export function Gate({ children }: { children: React.ReactNode }) {
  const { ready, customer } = useApp();
  if (!ready)
    return (
      <div className="grid min-h-dvh place-items-center">
        <Logo />
      </div>
    );
  if (!customer) return <Welcome />;
  return (
    <>
      {children}
      <TasteSheet />
    </>
  );
}
