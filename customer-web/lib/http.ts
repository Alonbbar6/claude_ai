import "server-only";
import { NextResponse } from "next/server";
import { OrderError } from "./orders";

export function json(data: unknown, status = 200) {
  return NextResponse.json(data, { status, headers: { "Cache-Control": "no-store" } });
}

export function errorResponse(err: unknown) {
  if (err instanceof OrderError) {
    const status = { invalid: 400, sold_out: 409, not_found: 404, bad_transition: 409, upstream: 502 }[err.code];
    return json({ error: err.code, message: err.message, detail: err.detail ?? null }, status);
  }
  console.error(err);
  return json({ error: "server_error", message: "Something went wrong" }, 500);
}

export async function body(req: Request): Promise<Record<string, unknown>> {
  try {
    const b = await req.json();
    return b && typeof b === "object" ? b : {};
  } catch {
    return {};
  }
}

/** Merchant-only endpoints: required only when MERCHANT_API_TOKEN is set. */
export function merchantAuthorized(req: Request) {
  const token = process.env.MERCHANT_API_TOKEN?.trim();
  if (!token) return true;
  return req.headers.get("authorization") === `Bearer ${token}`;
}
