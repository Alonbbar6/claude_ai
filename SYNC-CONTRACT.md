# Sync Contract — customer frontend ↔ manager backend

The customer-facing ordering app (your teammate's part) talks to **this** backend over HTTP.
This is the whole seam. When her app is ready, point it at the backend base URL and use these
two endpoints. Everything else on the backend is manager-side.

Base URL: `http://localhost:4000` locally, or the Railway backend URL in production.

## 1. Get the menu

```
GET /api/menu
```

Returns menu items with their canonical `key` (the `item_id` used when ordering), name,
category, price, and `modifierIds`. Render the menu from this so item names/prices never drift.

```jsonc
[
  { "id": "MENU-001", "key": "pizza_margherita", "name": "Margherita Pizza",
    "category": "Pizza", "price": 15.99, "modifierIds": ["extra_cheese", "no_cheese"] }
]
```

## 2. Submit an order (the canonical order shape)

```
POST /api/orders
Content-Type: application/json
```

The customer app chooses a **channel** first, then dishes. Send exactly this shape:

```jsonc
{
  "channel": "uber_eats",          // dine_in | takeout | website | uber_eats | doordash | barmade
  "placed_at": "2026-10-07T19:42:00Z", // optional ISO; defaults to now
  "items": [
    { "item_id": "pizza_margherita", "quantity": 2, "modifiers": ["extra_cheese"] }
  ]
}
```

`item_id` **must** be the menu `key` from `GET /api/menu`. The backend:
1. prices the order (channel fee applied automatically per channel),
2. deducts ingredients via each dish's recipe (inventory depletion),
3. raises a low-stock alert if any ingredient crosses its reorder point.

Response (201):

```jsonc
{
  "orderId": "ORD-07320",
  "channel": "uber_eats",
  "businessDate": "2026-10-07",
  "gross": 31.98,
  "channelFee": 9.59,
  "net": 22.39,
  "alertsRaised": ["ALERT-015"]
}
```

Errors return `{ "error": "message" }` with status 400 (bad item key / shape) or 500.

## CORS

The backend allows origins from `CORS_ORIGINS` in `backend/.env`
(default `http://localhost:5173,http://localhost:5174`). Add her dev origin there — e.g. if her
app runs on `http://localhost:5174` it already works; otherwise append her URL.

## That's it

She only needs `GET /api/menu` and `POST /api/orders`. The manager dashboard reads the same
database and reflects her orders live (press refresh / Simulate rush shows the mechanism).
When you're both ready to merge, we just deploy both apps to Railway against the same Postgres.
