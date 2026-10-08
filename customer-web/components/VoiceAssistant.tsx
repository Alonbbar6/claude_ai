"use client";

import { useState } from "react";
import { useApp } from "./AppProvider";
import { useSpeech } from "./useSpeech";

export const VOICE_ENABLED = process.env.NEXT_PUBLIC_VOICE_ORDERING === "on";

/** Floating mic: speak, see what was heard. (Step 1: transcription only.) */
export function VoiceAssistant() {
  const { t, lang } = useApp();
  const speech = useSpeech(lang);
  const [heard, setHeard] = useState("");
  const [open, setOpen] = useState(false);

  if (!speech.supported) return null;

  function toggle() {
    if (speech.listening) return speech.stop();
    setOpen(true);
    setHeard("");
    speech.start((text) => setHeard(text));
  }

  const errorKey = speech.error ? (`voice.error.${speech.error}` as const) : null;

  return (
    <div className="fixed bottom-24 right-4 z-40 flex flex-col items-end gap-2 sm:bottom-28 sm:right-6">
      {open && (speech.listening || heard || errorKey) && (
        <div className="max-w-[min(20rem,calc(100vw-2rem))] rounded-2xl bg-night px-4 py-3 text-sm text-white shadow-2xl" aria-live="polite">
          {speech.listening ? (
            <p>
              <span className="mr-1 inline-block h-2 w-2 animate-pulse rounded-full bg-gold" /> {speech.interim || t("voice.listening")}
            </p>
          ) : errorKey ? (
            <p className="text-gold">{t(errorKey)}</p>
          ) : (
            <p>
              <span className="text-white/60">{t("voice.youSaid")}</span> “{heard}”
            </p>
          )}
        </div>
      )}
      <button
        type="button"
        onClick={toggle}
        aria-label={speech.listening ? t("voice.stop") : t("voice.start")}
        aria-pressed={speech.listening}
        className={`grid h-14 w-14 place-items-center rounded-full text-2xl shadow-2xl transition hover:scale-105 active:scale-95 ${
          speech.listening ? "animate-pulse bg-warn text-white" : "bg-gold text-night"
        }`}
      >
        {speech.listening ? "■" : "🎤"}
      </button>
    </div>
  );
}
