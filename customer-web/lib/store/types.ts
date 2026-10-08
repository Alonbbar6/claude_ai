import type { Customer } from "../customers";
import type { Order, OrderStatus } from "../orders";

export interface ListOpts {
  since?: string;
  customerId?: string;
  limit: number;
}

/** Where customers and orders live. Postgres (Neon/Render/Railway/embedded) or Firestore. */
export interface Store {
  kind: "postgres" | "embedded" | "firestore";
  ping(): Promise<void>;
  nextOrderNumber(): Promise<number>;
  insertOrder(order: Order): Promise<Order>;
  getOrder(id: string): Promise<Order | null>;
  listOrders(opts: ListOpts): Promise<Order[]>;
  /** Atomically applies `next(current)`; throws whatever `next` throws. */
  updateOrder(id: string, next: (current: Order) => Partial<Order> | null): Promise<Order | null>;
  /** Ingredient usage of customer-app orders that are not cancelled. */
  consumedByApp(): Promise<Map<string, number>>;
  insertCustomer(c: Customer): Promise<Customer>;
  getCustomer(id: string): Promise<Customer | null>;
  saveCustomer(c: Customer): Promise<Customer>;
}

export type { Order, OrderStatus, Customer };
