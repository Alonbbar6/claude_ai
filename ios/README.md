# Mini Eats — iOS app

SwiftUI client (iOS 17+) for the Python/FastAPI backend in the repo root. Uber Eats / DoorDash-style flow:

| Tab | What it does | Backend |
|---|---|---|
| **Home** | Restaurants with a live ML-predicted ETA and distance → menu → cart | `GET /api/restaurants`, `POST /api/predict/eta` |
| **Cart** (sheet) | Line items, total, **Delivery / Pickup**. Delivery: ETA quote that re-predicts as the cart or weather changes. Pickup: food-ready time, your trip (drive/walk from your GPS location), **when to leave** | `POST /api/predict/eta`, `POST /api/predict/pickup`, `POST /api/orders` |
| **Orders** | Delivery: ETA, delay risk, timeline, route, courier dispatch plan. Pickup: live **"Leave in m:ss"** countdown, re-planned as you move, Drive/Walk switch, **Get directions** (Apple Maps), **I've picked it up** | `GET /api/orders/{id}`, `/pickup-plan`, `/collect`, `/advance`, `/refresh-eta`, `/cancel` |
| **Alerts** | Every notification with per-channel delivery status (push/SMS/email/in-app, retries) | `GET /api/notifications`, `WS /ws/{user_id}` |
| **Account** | Switch user, notification channels, quiet hours (saved to backend), server URL | `PUT /api/users/{id}/preferences` |

For pickup, the app also schedules a local **"Time to head out"** reminder at the planned
leave time. It fires even if the app is suspended and is replaced if the server sends its own.
Location is "While Using" only and runs only while a pickup is quoted or tracked.

Live updates arrive over the WebSocket. Each one shows an in-app banner, files an iOS
local notification, and refreshes the order. Tracking also polls every 3 s as a fallback.

## Run

```bash
# 1. Backend (from the repo root)
.venv/bin/uvicorn app.main:app --reload            # simulator
.venv/bin/uvicorn app.main:app --host 0.0.0.0      # physical iPhone

# 2. App
cd ios
brew install xcodegen      # once
xcodegen generate          # creates MiniEats.xcodeproj from project.yml
open MiniEats.xcodeproj    # pick an iPhone simulator, ⌘R
```

On a physical iPhone, set your signing team in Xcode and enter `http://<your-mac-LAN-IP>:8000`
under **Account → Server**.

## Tests

```bash
xcodebuild -project MiniEats.xcodeproj -scheme MiniEats \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

- `MiniEatsTests`: JSON contract with the Python models (snake_case, microsecond ISO dates, nulls).
- `MiniEatsUITests`: end-to-end with the backend running. Delivery: browse, add to cart, check out,
  track until delivered, check notifications. Pickup: choose Pickup, check the leave
  countdown, switch to Walk (it re-plans), advance until ready, mark it picked up. Place the
  simulator near Grill House first: `xcrun simctl location booted set 25.7930,-80.1330`. Set
  `TEST_RUNNER_SHOT_DIR=/path` to save a screenshot of each step.

## Layout

```
MiniEats/
  MiniEatsApp.swift        app entry, notification delegate
  AppStore.swift           @Observable state: catalogue, cart, orders, notifications, WebSocket
  APIClient.swift          async/await REST client, snake_case + date coding
  Models.swift             Codable mirrors of app/models.py
  Views/                   Root, RestaurantList, Menu, Cart, Orders, OrderDetail, Notifications, Account
```

## Toward production

- Real push: register for APNs, send the device token to the backend, and add an APNs channel
  behind `BaseChannel` (replaces the local-notification mirror).
- Auth (Sign in with Apple), saved addresses + Google Places autocomplete, Apple Pay / Stripe.
- MapKit live courier map once the backend streams courier locations.
