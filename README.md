# BarMade: restaurant ordering & inventory demo

Classroom prototype for **BarMade**: small restaurants get live, recipe-based inventory, and their customers
skip the lunch line by ordering ahead from their phone. All restaurant data is **synthetic**.

| Part | Where | What it is |
|---|---|---|
| **Customer web app** | [`customer-web/`](customer-web/HANDOFF.md) | The page customers open from a QR code: name-only account, EN/ES, live menu, to go / for here, live order tracking, Claude suggestions. Next.js, deployed on Railway. |
| **BarMade backend** | `https://barmade-riw5.onrender.com` (separate service) | Express + Firestore. Owns the menu, recipes, batch inventory, orders, movements and order status. |
| Mini Eats prototype | [`app/`](#mini-eats-prototype-python-backend), `static/`, `tests/` | Python/FastAPI backend: predictive ETA, pickup "when to leave", courier dispatch, notifications, merchant menu + inventory. |
| iOS apps | [`ios/`](ios/README.md) | SwiftUI customer app (MiniEats) and merchant app (MiniEatsMerchant). |
| Hand-off docs | [`docs/handoff/`](docs/handoff/orders-contract.md) | Contract between the customer app and the BarMade backend. |

---

## Customer web app (`customer-web/`)

```
Phone (QR) ─► customer-web (Railway) ──POST /api/orders──► BarMade API (Render) ─► Firestore barmade/state/*
                      │                                                                  ▲
                      └──────────── reads menu, stock, order status (read-only) ──────────┘
```

**What a customer can do**

- **Create an account with just a name.** It's stored in Firestore `customers/{id}` and remembered on the device.
- **Use the app in English (default) or Spanish**, with a toggle that also translates dish names and descriptions.
- **Browse Trattoria Little Italy.** Price, recipe and stock are read live from the backend. Each dish shows
  "Only N left" or "Sold out". Dataset dishes the restaurant isn't serving appear as sold out.
- **See allergen badges** (dairy, gluten, egg, fish, pork) derived from the recipe ingredients, with an "ask staff" note.
- **See a chef's special** picked from what the kitchen has the most of compared with its reorder point (PRD FR-8).
- **Get "Picked for you" suggestions** from taste chips or a free-text craving ("something light under $15").
  **Claude** ranks the in-stock, allergy-safe dishes and writes a one-line reason. It never receives the customer's
  name or id. Without an API key, a rule-based fallback is used.
- **Choose 🥡 To go (packed) or 🍽️ For here (on a plate)**, with an optional table number. No payments:
  "Pay at pickup / at your table".
- **Track the order live** with an "Ordered via BarMade" badge. The order page reads the backend status every 3 s:
  `RECEIVED → PREPARING → READY → COMPLETED`.
- **Browse three closed restaurants** (La Ventanita de Calle 8, Brickell Sushi Co., Wynwood Greens). They show a
  browse-only menu with original illustrations, are always closed in the demo, and suggest similar dishes at the open Trattoria.

**How an order flows**

1. The customer app validates the basket against the live menu and stock.
2. `POST /api/orders` on the BarMade backend sends `items` plus `channel: "barmade"`, `source: "barmade-web"`,
   `fulfillment`, `tableNumber`, `customerName` and `customerId`.
3. The backend computes consumption from the recipe, deducts inventory (oldest batch first), records the movement, and
   creates the order as `RECEIVED` (5% BarMade channel fee).
4. The merchant moves the order with `PATCH /api/orders/:id/status`. The customer's screen follows within ~3 s.

Tested end to end against the real backend. For example, ORD-004 (a Coca-Cola, for here at table 4): inventory 119 → 118,
movement `MOV-000002 sale`, status `RECEIVED`.

**Run it locally**

```bash
cd customer-web
nvm use              # Node 20+
npm install
cp .env.example .env # BARMADE_API_URL, FIREBASE_SERVICE_ACCOUNT, FIREBASE_PROJECT_ID, ANTHROPIC_API_KEY
npm run dev          # http://localhost:3000
```

With no backend or Firebase variables, it runs fully offline on the synthetic dataset and an embedded
database, without touching the team's data. `GET /api/health` shows what's active, and `npm run smoke -- <url>` checks a
deployment (read-only unless `--write`).

**Deploy:** see [`customer-web/HANDOFF.md`](customer-web/HANDOFF.md) (Railway, root directory `customer-web`).
**Contract with the backend:** [`docs/handoff/orders-contract.md`](docs/handoff/orders-contract.md).

**Next up:** voice ordering. Speech builds the cart ("two Margheritas and a Coke, to go") and the customer
confirms with one tap. The merchant dashboard also needs buttons for the status changes.

---

## Mini Eats prototype (Python backend)

A small Uber Eats-style food delivery app built to exercise two things:

1. **Predictive ETA model** – gradient-boosted models that quote delivery time and a
   "delay risk" probability, using **Google Maps distance and traffic-aware travel
   time** as features.
2. **Notification system** – an event-driven pipeline (status changes, ETA slips,
   courier dispatch) with per-user channels, quiet hours, dedup, retry and a
   delivery log, streamed live to the browser over WebSocket.

On top of those, orders are **dispatched by distance**: when the kitchen confirms,
the app routes every free courier to the restaurant and times their departure so
they arrive as the food comes out.

### iOS app

A SwiftUI client lives in [`ios/`](ios/README.md): browse, cart, checkout, live order tracking and push-style notifications against this backend.

### Run it

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt pytest-asyncio
cp .env.example .env            # optional: add your Google Maps key
export $(grep -v '^#' .env | xargs)
.venv/bin/uvicorn app.main:app --reload
```

Open http://127.0.0.1:8000. Pick a user and a restaurant, add items, and watch the
order move through the lifecycle (one stage every 4 s) with notifications arriving in
real time. "Simulate demand spike" re-runs the model and fires a *Running late* alert
when the ETA slips 5+ minutes.

Without `GOOGLE_MAPS_API_KEY` the app uses a straight-line fallback (haversine × 1.3
road factor at 19 km/h) and labels it as such in the UI.

Tests: `.venv/bin/pytest`

### How it works

```
POST /api/orders
  └─ maps.route(restaurant → customer)      Google Routes API (TRAFFIC_AWARE)
  └─ predictor.predict(...)                 ETA + delay risk, quoted to the customer
  └─ bus.publish(order.status_changed)      → NotificationService → push/sms/email/ws

advance → confirmed
  └─ plan_dispatch()
       ready_at   = now + kitchen time (prep + items + backlog)
       for each free courier: maps.route(courier → restaurant)
       choose courier that lands closest to ready_at (never late if avoidable)
       dispatch_at = ready_at − courier travel time
       delivery_at = pickup + customer-leg travel time

advance → preparing / courier_dispatched / picked_up / delivered
  └─ refresh_eta()  re-predict with live courier load & backlog
       slip ≥ 5 min → bus.publish(order.delayed) → "Running late" notification
```

#### Prediction (`app/prediction/`)

| file | role |
|---|---|
| `features.py` | single source of truth for the feature vector (distance, Google travel time, prep time, items, hour, weekend, rain, courier load, restaurant backlog, rush hour) |
| `synthetic.py` | generates training history from a plausible generative process — swap for a real table of delivered orders |
| `eta.py` | `EtaPredictor`: `GradientBoostingRegressor` (minutes) + `GradientBoostingClassifier` (P(late > 10 min)); trains on first start and caches to `models/eta.pkl`; re-scales to "minutes remaining" per lifecycle stage |

`GET /api/predict/model` reports held-out MAE / AUC and feature importances.

#### Pickup timing (`app/prediction/ready.py`, `app/pickup.py`)

For pickup orders the app tells you **when to leave** so you get there as the food
comes out: no waiting at the counter, no cold food.

- **Kitchen ready-time model**: three quantile gradient-boosting models give a range
  for when the food is ready: p50 (most likely), p75 (planned against), p90 (almost
  surely ready). Inputs: restaurant prep time, items, kitchen backlog, hour/rush/weekend.
  Calibrated on held-out data (p75 covers ~74% of orders, p90 ~90%). Delivery dispatch
  uses the same model's p50 to time couriers.
- **Planner** (pure function): `leave_at = p75 ready time − (travel time + parking/walk-in)`,
  with travel from the customer's live GPS location by car or on foot (Google Routes API
  `mode=driving|walking`). It returns `wait` (leave in N min), `leave_now`, `ready`, or
  `too_far`, plus how long the food would sit (`food_wait_min`) or you would wait.
- **Live re-planning**: the app sends location as you move (`POST /api/orders/{id}/pickup-plan`),
  and the server re-plans every 30 s while the kitchen cooks. When it's time, it sends a
  **"Time to head out"** notification once (deduplicated), even if the app is closed.

#### Routing (`app/maps.py`)

`GoogleMapsProvider` calls the Routes API `computeRouteMatrix` (traffic-aware for driving), caches
results for 60 s, and falls back to `HaversineProvider` on any error so an outage or
bad key never blocks orders. Both return a `RouteEstimate(distance_km, duration_min,
source)`.

#### Notifications (`app/notifications/`)

| file | role |
|---|---|
| `events.py` | tiny async event bus (`order.status_changed`, `order.eta_updated`, `order.delayed`) |
| `templates.py` | message per notification kind; `urgent` ones bypass quiet hours |
| `channels.py` | `SimulatedChannel` for push/SMS/email (logs, random failures to exercise retry) and a real `WebSocketChannel` |
| `service.py` | preference-aware dispatch with dedup, quiet-hours deferral + `flush_deferred()`, 3× retry with backoff, delivery log |

### API

| method | path | purpose |
|---|---|---|
| GET | `/api/restaurants`, `/api/users`, `/api/couriers` | seed data |
| PUT | `/api/users/{id}/preferences` | channels & quiet hours |
| POST | `/api/predict/eta` | quote before ordering (includes the Google route) |
| POST | `/api/predict/pickup` | pickup quote: ready time range, trip, when to leave |
| GET | `/api/predict/model` | model metrics & feature importance |
| POST | `/api/orders` | place an order (routes, quotes, notifies, starts simulation) |
| GET | `/api/orders?user_id=` · `/api/orders/{id}` | list / detail |
| GET | `/api/orders/{id}/dispatch` | courier dispatch plan (after confirmation) |
| POST | `/api/orders/{id}/advance` · `/cancel` · `/refresh-eta?demand_shock=` | drive the lifecycle manually |
| POST | `/api/orders/{id}/pickup-plan` | re-plan pickup from `{lat, lng, mode}` |
| POST | `/api/orders/{id}/collect` | pickup: customer has the food |
| GET | `/api/notifications?user_id=` | notifications with per-channel delivery records |
| POST | `/api/notifications/flush-deferred` | send what quiet hours held back |
| WS | `/ws/{user_id}` | live notification stream |

### Next steps

- Replace `synthetic.py` with real delivered-order history (store each order's
  Google quote alongside the actual delivery time) and retrain on a schedule.
- Geocode free-text addresses (Google Geocoding API) instead of fixed lat/lng.
- Real providers for push (FCM/APNs), SMS (Twilio) and email behind the same
  `BaseChannel` interface.
- Persist orders/notifications (Postgres) and move the event bus to a queue.
