# Customer app ↔ BarMade backend contract

For the backend / merchant team. **The backend owns orders.** The customer web app (`customer-web/`)
creates every order through the backend's `POST /api/orders`. The backend computes consumption from
the recipe, deducts inventory, records the movement, and manages the order status.

```
Customer phone ─► customer-web server ─POST /api/orders─► BarMade API (Render) ─► Firestore barmade/state/*
                         │                                                    ▲
                         └──── reads menu + inventory + order status (read-only) ┘
```

## 1. What the customer app sends: `POST {BARMADE_API_URL}/api/orders`

```json
{
  "items": [
    { "menuItemId": "MENU-001", "quantity": 2 },
    { "menuItemId": "MENU-005", "quantity": 1 }
  ],
  "channel": "barmade",
  "source": "barmade-web",
  "fulfillment": "to_go",
  "tableNumber": null,
  "customerName": "María",
  "customerId": "671a1afb-87f2-4b9f-a1bf-c11b0e806b7b"
}
```

- `items` is what the backend already accepts.
- **The other fields are new.** Please **store them on the order doc**, so the merchant ticket can show:
  - 🏷️ **"Ordered via BarMade"** when `source === "barmade-web"` (or `channel === "barmade"`)
  - 🥡 **To go** (packed) / 🍽️ **For here** (on a plate) from `fulfillment`, plus `tableNumber` if given
  - the customer's name, to call the order
- Before sending, the app checks every dish against the **live menu + inventory** (it hides dishes that
  are not in `barmade/state/menu` and blocks quantities the stock can't cover). The backend still has
  the final say.

## 2. What the customer app expects back

`201` with `{ "data": <order> }`, the same order doc that is stored in `barmade/state/orders/{id}`:

```json
{ "data": { "id": "ORD-003", "status": "RECEIVED", "createdAt": "2026-10-08T19:05:00",
            "items": [...], "total": 34.97, "consumed": [...] } }
```

Errors: `{ "error": { "code", "message", "details" } }`.
- `409 INSUFFICIENT_INVENTORY`: the customer sees "Sorry, some items just sold out". If `details`
  mentions the `menuItemId`s, we name the exact dishes.
- Any other 4xx: shown as "We couldn't place your order".
- Timeout or 5xx: "The restaurant system didn't answer". The app waits up to 60 s, because Render free tier can sleep.

## 3. Order status: please implement in the backend

**New orders must start as `RECEIVED`** (not `COMPLETED`), or the customer will see "Picked up" right away.

```
RECEIVED ──► PREPARING ──► READY ──► COMPLETED
    │             │
    └─────────────┴──► CANCELLED
```

- Merchant buttons call something like `PATCH /api/orders/:id/status { "status": "PREPARING" }`.
  The backend validates the move (409 on an invalid one).
- On each change, please also set `updatedAt` (ISO) and append `{ status, at }` to `statusHistory`.
  The customer's timeline shows those times. Without them it still works, but with fewer timestamps.
- The customer app reads `barmade/state/orders/{id}` every 3 s, so it picks up the change on its own.
  The customer app **never changes status** itself.
- Accepted spellings: `RECEIVED|PENDING|NEW`, `PREPARING|IN_PROGRESS`, `READY`, `COMPLETED|PICKED_UP|SERVED`, `CANCELLED|CANCELED`.

## 4. What the customer app reads (read-only)

| Path | Used for |
|---|---|
| `barmade/state/menu` | Which dishes can be ordered, price, recipe. Dataset dishes not in this collection show as **"Sold out"**, so adding a dish here makes it orderable right away. |
| `barmade/state/inventory` | Live stock: sum of non-expired `batches`. Shows "Only N left" / "Sold out" and picks the chef's special (most stock vs. `reorderPoint`). |
| `barmade/state/orders/{id}` | Order status for the customer's tracking screen |

## 5. What the customer app writes to Firestore (its own collections only)

| Collection | Why |
|---|---|
| `customers/{uuid}` | Name-only profiles: `{ display_name, language, taste: { likes, avoid } }` |
| `customer_app_orders/{orderId}` | Copy of the customer-facing details (name, fulfillment, table), in case the backend doesn't store them yet |

It **never writes** to `barmade/state/*`. Everything there goes through the API.

## 6. Demo-day checklist

- [ ] Final `BARMADE_API_URL` shared (the `onrender.com` URL of the Express API)
- [ ] `POST /api/orders` stores `channel`, `source`, `fulfillment`, `tableNumber`, `customerName`
- [ ] New orders start as `RECEIVED`; merchant can move them through the statuses
- [ ] **Wake Render up ~2 minutes before presenting** (open `/api/menu` in a browser). The customer app
      also pings it every few minutes while someone is browsing.
- [ ] One real test order end to end (it deducts real inventory, so do it on purpose)
