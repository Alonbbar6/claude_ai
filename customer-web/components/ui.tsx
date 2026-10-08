"use client";

import { useEffect, useRef, useState } from "react";
import { useApp } from "./AppProvider";

/** Bottom sheet on phones, centered dialog on larger screens. Animates both open and close. */
export function Sheet({
  open,
  onClose,
  label,
  children,
  wide = false,
}: {
  open: boolean;
  onClose: () => void;
  label: string;
  children: React.ReactNode;
  wide?: boolean;
}) {
  const [mounted, setMounted] = useState(open);
  const [visible, setVisible] = useState(false);
  const panel = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (open) {
      setMounted(true);
      const id = requestAnimationFrame(() => requestAnimationFrame(() => setVisible(true)));
      return () => cancelAnimationFrame(id);
    }
    setVisible(false);
    const t = setTimeout(() => setMounted(false), 300);
    return () => clearTimeout(t);
  }, [open]);

  useEffect(() => {
    if (!mounted) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    panel.current?.focus();
    return () => {
      document.body.style.overflow = prev;
      window.removeEventListener("keydown", onKey);
    };
  }, [mounted, onClose]);

  if (!mounted) return null;
  return (
    <div className="sheet fixed inset-0 z-50" data-state={visible ? "open" : "closed"}>
      <div className="sheet-backdrop absolute inset-0 bg-night/55" onClick={onClose} aria-hidden />
      <div className="pointer-events-none absolute inset-0 flex items-end justify-center sm:items-center sm:p-6">
        <div
          ref={panel}
          role="dialog"
          aria-modal="true"
          aria-label={label}
          tabIndex={-1}
          className={`sheet-panel pointer-events-auto relative max-h-[92dvh] w-full overflow-y-auto rounded-t-3xl bg-white shadow-2xl outline-none sm:rounded-3xl ${
            wide ? "sm:max-w-xl" : "sm:max-w-lg"
          }`}
        >
          {children}
        </div>
      </div>
    </div>
  );
}

export function CloseButton({ onClick, className = "" }: { onClick: () => void; className?: string }) {
  const { t } = useApp();
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={t("menu.close")}
      className={`grid h-9 w-9 place-items-center rounded-full bg-white/95 text-lg font-bold text-night shadow-card transition hover:scale-105 ${className}`}
    >
      ✕
    </button>
  );
}

/** Fixed-ratio photo with shimmer while loading and a graceful fallback. */
export function DishImage({
  src,
  alt,
  ratio = "4/3",
  className = "",
  dim = false,
  eager = false,
}: {
  src: string;
  alt: string;
  ratio?: "4/3" | "16/9" | "21/9" | "1/1";
  className?: string;
  dim?: boolean;
  eager?: boolean;
}) {
  const [state, setState] = useState<"loading" | "ok" | "error">("loading");
  const img = useRef<HTMLImageElement>(null);
  useEffect(() => {
    if (img.current?.complete && img.current.naturalWidth > 0) setState("ok");
  }, [src]);
  return (
    <div className={`relative overflow-hidden ${state === "loading" ? "img-wrap" : "bg-gold-tint"} ${className}`} style={{ aspectRatio: ratio }}>
      {state !== "error" ? (
        <img
          ref={img}
          src={src}
          alt={alt}
          loading={eager ? "eager" : "lazy"}
          decoding="async"
          onLoad={() => setState("ok")}
          onError={() => setState("error")}
          className={`absolute inset-0 h-full w-full object-cover object-center transition duration-500 ${
            state === "ok" ? "opacity-100" : "opacity-0"
          } ${dim ? "grayscale-[35%]" : ""}`}
        />
      ) : (
        <div className="absolute inset-0 grid place-items-center text-4xl" aria-hidden>
          🍽️
        </div>
      )}
    </div>
  );
}

export function Stepper({
  value,
  onChange,
  min = 0,
  max = 20,
  label,
}: {
  value: number;
  onChange: (n: number) => void;
  min?: number;
  max?: number;
  label: string;
}) {
  return (
    <div className="inline-flex items-center rounded-full border border-line bg-white" role="group" aria-label={label}>
      <button
        type="button"
        className="grid h-9 w-9 place-items-center rounded-full text-lg font-bold text-ink transition hover:bg-cream disabled:opacity-30"
        onClick={() => onChange(value - 1)}
        disabled={value <= min}
        aria-label="−"
      >
        −
      </button>
      <span className="w-7 text-center font-bold tabular-nums" aria-live="polite">
        {value}
      </span>
      <button
        type="button"
        className="grid h-9 w-9 place-items-center rounded-full text-lg font-bold text-ink transition hover:bg-cream disabled:opacity-30"
        onClick={() => onChange(value + 1)}
        disabled={value >= max}
        aria-label="+"
      >
        +
      </button>
    </div>
  );
}

export function ViaBarmade({ className = "" }: { className?: string }) {
  const { t } = useApp();
  return (
    <span className={`chip bg-night text-white ${className}`}>
      <span className="text-gold">●</span> {t("brand.via")}
    </span>
  );
}
