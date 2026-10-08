import "server-only";
import { firestoreConfigured, firestoreStore } from "./firestore";
import { postgresStore } from "./postgres";
import type { Store } from "./types";

/**
 * DATA_STORE=firestore | postgres picks explicitly. Otherwise: Firestore when Firebase
 * credentials are present, else Postgres (DATABASE_URL), else the local embedded Postgres.
 */
export function store(): Store {
  const choice = process.env.DATA_STORE?.trim().toLowerCase();
  if (choice === "firestore") return firestoreStore;
  if (choice === "postgres") return postgresStore;
  return firestoreConfigured() ? firestoreStore : postgresStore;
}

export type { Store } from "./types";
