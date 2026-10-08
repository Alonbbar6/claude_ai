import "server-only";
import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { GoogleGenAI } from "@google/genai";
import { z } from "zod";

/**
 * One structured-output call, two providers:
 *  - Claude (default): ANTHROPIC_API_KEY
 *  - Gemini: AI_PROVIDER=gemini + GEMINI_API_KEY (also used automatically when only GEMINI_API_KEY is set)
 * Callers pass a zod schema and get back validated data, or null when the model declines.
 * Errors (no credit, rate limit, network, timeout) are thrown so callers can fall back.
 */

export type AiProvider = "claude" | "gemini";

export function aiProvider(): AiProvider | null {
  const want = process.env.AI_PROVIDER?.trim().toLowerCase();
  const hasClaude = !!process.env.ANTHROPIC_API_KEY?.trim();
  const hasGemini = !!process.env.GEMINI_API_KEY?.trim();
  if (want === "gemini" && hasGemini) return "gemini";
  if (want === "claude" && hasClaude) return "claude";
  if (hasClaude) return "claude";
  if (hasGemini) return "gemini";
  return null;
}

const CLAUDE_MODEL = process.env.ANTHROPIC_MODEL?.trim() || "claude-opus-5-5";
// Measured Oct 2026: 3.5 Flash ~2.4 s; the "latest" alias and 3.6 Flash were overloaded (503 / >40 s).
const GEMINI_MODEL = process.env.GEMINI_MODEL?.trim() || "gemini-3.5-flash";
// Tried once if the main model is overloaded or too slow.
const GEMINI_FALLBACK_MODEL = process.env.GEMINI_FALLBACK_MODEL?.trim() || "gemini-3.5-flash-lite";

export async function structured<S extends z.ZodType>(opts: {
  system: string;
  user: string;
  schema: S;
  maxTokens: number;
  timeoutMs: number;
  /** Claude only: lets voice use a faster model (VOICE_MODEL) */
  claudeModel?: string;
}): Promise<z.infer<S> | null> {
  const provider = aiProvider();
  if (!provider) throw new Error("No AI provider configured");
  return provider === "gemini" ? withGemini(opts) : withClaude(opts);
}

async function withClaude<S extends z.ZodType>(opts: Parameters<typeof structured<S>>[0]): Promise<z.infer<S> | null> {
  const client = new Anthropic({ timeout: opts.timeoutMs, maxRetries: 1 });
  const res = await client.beta.messages.parse({
    model: opts.claudeModel || CLAUDE_MODEL,
    max_tokens: opts.maxTokens,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: { effort: "low", format: betaZodOutputFormat(opts.schema) },
    system: opts.system,
    messages: [{ role: "user", content: opts.user }],
  });
  if (res.stop_reason === "refusal") return null;
  return (res.parsed_output as z.infer<S> | null) ?? null;
}

let gemini: GoogleGenAI | null = null;

async function withGemini<S extends z.ZodType>(opts: Parameters<typeof structured<S>>[0]): Promise<z.infer<S> | null> {
  try {
    return await geminiCall(GEMINI_MODEL, opts, opts.timeoutMs);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const busy = /\b(503|429|UNAVAILABLE|RESOURCE_EXHAUSTED|high demand|aborted|timed? ?out)\b/i.test(msg);
    if (!busy || GEMINI_FALLBACK_MODEL === GEMINI_MODEL) throw err;
    console.error(`gemini: ${GEMINI_MODEL} busy, retrying with ${GEMINI_FALLBACK_MODEL}`);
    return geminiCall(GEMINI_FALLBACK_MODEL, opts, Math.min(opts.timeoutMs, 10_000));
  }
}

async function geminiCall<S extends z.ZodType>(model: string, opts: Parameters<typeof structured<S>>[0], timeoutMs: number): Promise<z.infer<S> | null> {
  gemini ??= new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY!.trim() });
  const res = await gemini.models.generateContent({
    model,
    contents: opts.user,
    config: {
      systemInstruction: opts.system,
      responseMimeType: "application/json",
      responseJsonSchema: z.toJSONSchema(opts.schema),
      maxOutputTokens: Math.max(opts.maxTokens, 4096), // thinking tokens count toward this limit
      abortSignal: AbortSignal.timeout(timeoutMs),
    },
  });
  const text = res.text;
  if (!text) return null; // blocked or empty
  const parsed = opts.schema.safeParse(JSON.parse(text));
  if (!parsed.success) throw new Error(`Gemini returned an unexpected shape: ${parsed.error.message.slice(0, 200)}`);
  return parsed.data;
}
