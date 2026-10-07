# Mini Eats

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

## iOS app

A SwiftUI client lives in [`ios/`](ios/README.md): browse, cart, checkout, live order tracking and push-style notifications against this backend.

## Run it

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

## How it works

```
POST /api/orders
  └─ maps.route(restaurant → customer)      Google Distance Matrix (duration_in_traffic)
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

### Prediction (`app/prediction/`)

| file | role |
|---|---|
| `features.py` | single source of truth for the feature vector (distance, Google travel time, prep time, items, hour, weekend, rain, courier load, restaurant backlog, rush hour) |
| `synthetic.py` | generates training history from a plausible generative process — swap for a real table of delivered orders |
| `eta.py` | `EtaPredictor`: `GradientBoostingRegressor` (minutes) + `GradientBoostingClassifier` (P(late > 10 min)); trains on first start and caches to `models/eta.pkl`; re-scales to "minutes remaining" per lifecycle stage |

`GET /api/predict/model` reports held-out MAE / AUC and feature importances.

### Routing (`app/maps.py`)

`GoogleMapsProvider` calls the Distance Matrix API with `departure_time=now`, caches
results for 60 s, and falls back to `HaversineProvider` on any error so an outage or
bad key never blocks orders. Both return a `RouteEstimate(distance_km, duration_min,
source)`.

### Notifications (`app/notifications/`)

| file | role |
|---|---|
| `events.py` | tiny async event bus (`order.status_changed`, `order.eta_updated`, `order.delayed`) |
| `templates.py` | message per notification kind; `urgent` ones bypass quiet hours |
| `channels.py` | `SimulatedChannel` for push/SMS/email (logs, random failures to exercise retry) and a real `WebSocketChannel` |
| `service.py` | preference-aware dispatch with dedup, quiet-hours deferral + `flush_deferred()`, 3× retry with backoff, delivery log |

## API

| method | path | purpose |
|---|---|---|
| GET | `/api/restaurants`, `/api/users`, `/api/couriers` | seed data |
| PUT | `/api/users/{id}/preferences` | channels & quiet hours |
| POST | `/api/predict/eta` | quote before ordering (includes the Google route) |
| GET | `/api/predict/model` | model metrics & feature importance |
| POST | `/api/orders` | place an order (routes, quotes, notifies, starts simulation) |
| GET | `/api/orders?user_id=` · `/api/orders/{id}` | list / detail |
| GET | `/api/orders/{id}/dispatch` | courier dispatch plan (after confirmation) |
| POST | `/api/orders/{id}/advance` · `/cancel` · `/refresh-eta?demand_shock=` | drive the lifecycle manually |
| GET | `/api/notifications?user_id=` | notifications with per-channel delivery records |
| POST | `/api/notifications/flush-deferred` | send what quiet hours held back |
| WS | `/ws/{user_id}` | live notification stream |

## Next steps

- Replace `synthetic.py` with real delivered-order history (store each order's
  Google quote alongside the actual delivery time) and retrain on a schedule.
- Geocode free-text addresses (Google Geocoding API) instead of fixed lat/lng.
- Real providers for push (FCM/APNs), SMS (Twilio) and email behind the same
  `BaseChannel` interface.
- Persist orders/notifications (Postgres) and move the event bus to a queue.
