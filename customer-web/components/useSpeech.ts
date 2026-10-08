"use client";

import { useCallback, useEffect, useRef, useState } from "react";

// Minimal typing for the Web Speech API (Chrome, Edge, Safari 14.5+; not Firefox).
interface SpeechRecognitionLike {
  lang: string;
  interimResults: boolean;
  continuous: boolean;
  maxAlternatives: number;
  start(): void;
  stop(): void;
  abort(): void;
  onresult: ((e: { results: ArrayLike<ArrayLike<{ transcript: string }> & { isFinal: boolean }> }) => void) | null;
  onerror: ((e: { error: string }) => void) | null;
  onend: (() => void) | null;
}

function recognitionCtor(): (new () => SpeechRecognitionLike) | null {
  if (typeof window === "undefined") return null;
  const w = window as unknown as Record<string, unknown>;
  return (w.SpeechRecognition ?? w.webkitSpeechRecognition ?? null) as (new () => SpeechRecognitionLike) | null;
}

export type SpeechError = "not-allowed" | "no-speech" | "network" | "unsupported" | "other";

/** Browser speech-to-text. Free, no keys; audio is handled by the browser vendor's service. */
export function useSpeech(lang: "en" | "es") {
  const [supported, setSupported] = useState(false);
  const [listening, setListening] = useState(false);
  const [interim, setInterim] = useState("");
  const [error, setError] = useState<SpeechError | null>(null);
  const rec = useRef<SpeechRecognitionLike | null>(null);
  const finalText = useRef("");
  const onFinal = useRef<((text: string) => void) | null>(null);

  useEffect(() => setSupported(recognitionCtor() !== null), []);
  useEffect(() => () => rec.current?.abort(), []);

  const start = useCallback(
    (cb: (text: string) => void) => {
      const Ctor = recognitionCtor();
      if (!Ctor) return setError("unsupported");
      rec.current?.abort();
      const r = new Ctor();
      r.lang = lang === "es" ? "es-US" : "en-US";
      r.interimResults = true;
      r.continuous = false;
      r.maxAlternatives = 1;
      finalText.current = "";
      onFinal.current = cb;
      setInterim("");
      setError(null);
      r.onresult = (e) => {
        let text = "";
        for (let i = 0; i < e.results.length; i++) text += e.results[i][0].transcript;
        setInterim(text);
        if (e.results[e.results.length - 1].isFinal) finalText.current = text;
      };
      r.onerror = (e) => {
        const map: Record<string, SpeechError> = { "not-allowed": "not-allowed", "service-not-allowed": "not-allowed", "no-speech": "no-speech", network: "network" };
        setError(map[e.error] ?? (e.error === "aborted" ? null : "other"));
      };
      r.onend = () => {
        setListening(false);
        const text = finalText.current.trim();
        if (text) onFinal.current?.(text);
      };
      rec.current = r;
      r.start();
      setListening(true);
    },
    [lang],
  );

  const stop = useCallback(() => rec.current?.stop(), []);

  return { supported, listening, interim, error, start, stop };
}
