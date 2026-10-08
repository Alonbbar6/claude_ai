# BarMade — iOS apps

Two SwiftUI apps (iOS 17+) that are native clients of the **BarMade API** — the team's
Express + Firestore backend on Render (`https://barmade-riw5.onrender.com`). The customer web
app (`../customer-web/`, Next.js) talks to the same backend, so a phone order and a web order
are the same ticket in the kitchen.

```
iPhone  BarMade app ───┐                                    ┌─── BarMade Merchant (iPhone/iPad)
                       ├──► BarMade API (Render) ◄──────────┤      inventory · menu · tickets ·
Web     customer-web ──┘    menu · stock · orders · status  └───   status buttons · alerts
                 └──── photos & descriptions (optional, /api/menu) ────► BarMade app
```

| App | Target | Bundle id | What it does |
|---|---|---|---|
| **BarMade** (customer) | `MiniEats` | `com.minieats.app` | Name-only sign in → menu with live "Sold out" / "Only n left" from batch stock → cart with **To go / For here + table** → order sent to the kitchen → live tracker (Received → Preparing → Ready → Picked up, polled every 3 s) → order history |
| **BarMade Merchant** (kitchen) | `MiniEatsMerchant` | `com.minieats.merchant` | Tickets from the web and the iPhone app (name, to go / for here, table, "via Web / iPhone app"), one-tap status moves, batch inventory with expiry, menu with portions left, alerts |

Backend calls (both apps, `Shared/BarMade.swift`): `GET /api/menu`, `GET /api/inventory`,
`GET /api/orders`, `GET /api/orders/:id`, `POST /api/orders`, `PATCH /api/orders/:id/status`,
`GET /api/alerts`. Orders are posted with the same fields as the web app
(`items`, `channel: "barmade"`, `source: "barmade-ios"`, `fulfillment`, `tableNumber`, `customerName`).

### Tracking and predictive timing (on the phone, no server)

The old Mini Eats server did ETA prediction and pickup planning in Python; the BarMade app does
the same on the phone, from the kitchen's own data:

- **Ready-time model** (`MiniEats/Prediction/ReadyTimeModel.swift`): the old quantile model's
  structure (prep time from the recipe, item count, how many tickets the kitchen has open,
  rush hour, weekend; a right-skewed p50/p75/p90 band) is the prior. It is tuned to this kitchen
  from BarMade's order `statusHistory` (RECEIVED → READY): a pace factor and spread, shrunk toward
  the prior while there are few samples; tickets that sat > 90 min (nobody tapped) are ignored.
  Account → "Ready-time model" shows what it learned.
- **Pickup planner** (`Prediction/PickupPlanner.swift`): the server's `plan_pickup` 1:1 — arrive at
  the p75 ready time, `leave_at = target − (travel + parking/walk-in)`; wait / leave now / ready /
  too far, with the same messages.
- **Routing** (`Routing.swift`): Apple Maps directions (traffic-aware driving, walking), falling
  back to a straight-line estimate (×1.3 road factor at 19 km/h; ×1.2 at 4.8 km/h walking).
- **Tracker**: map with your position, the restaurant and the routed path; **"Leave in m:ss"**
  countdown re-planned as you move (50 m) and every 3 s poll; Drive/Walk switch; Get directions;
  a local **"Time to head out"** notification at leave time; status changes also notify.
- **Cart and menu**: "Food ready ~N (by M)" and "Leave at" before you order; the restaurant card's
  "Ready in" comes from the model given the kitchen's live load.
- **Ready when you arrive** (menu, above the categories): up to three dishes whose kitchen time best
  fits your trip from where you are now (`CustomerStore.rankForArrival`): 44 min of cooking and a
  20 min drive means you leave in ~24 min; a dish that's ready the moment you reach the counter
  ranks first, waiting a little ranks above food sitting. Needs a location fix.
- **Leave timer everywhere**: the same live "Leave in m:ss" countdown (`LeaveCountdown`, compact form)
  runs in the cart before you order, on the home banner for the active order, and on each row of the
  orders list, not only on the tracker; "Leave now" once the time comes.
- **Pickup timing** (Account): the parking / walk-in buffer per travel mode (default 2 min driving,
  ½ min walking) is a stepper; 0 makes leave time exactly ready time − travel time.
- **Map tab** (`Views/NearbyMapView.swift`): you (live blue dot), the restaurant, the routed path,
  "ready ~N · trip" on the pin, Drive/Walk, Directions, Order now.
- **Time adjustment**: the quote given at checkout is remembered; every re-plan compares the
  kitchen's current estimate to it. A 5+ min slip posts a **"Running late"** notification and moves
  the leave time; the tracker shows "Quoted ~12:40 at checkout", "Running ~7 min late" and a
  **delay-risk** badge (chance of being >10 min later than quoted, read off the p50/p75/p90 band).
- **Restaurants**: BarMade has no profile, so the app carries presets under Account → Restaurant:
  *Trattoria Little Italy* (120 E Flagler St) and a **QA Test Kitchen at MDC Wolfson Campus**
  (300 NE 2nd Ave, Miami, FL 33132) for demo-day testing. Both order from the same kitchen API;
  only the place trips are planned to changes.

BarMade publishes no restaurant location: the address under Account → Restaurant is geocoded
(default 120 E Flagler St, Miami). Delivery/courier tracking is not here because BarMade has no
delivery; everything is pickup / for-here.

Optional: under **Account → Web app** enter the customer web app's URL. The iPhone menu then
shows the same photos, descriptions and categories as the web menu (`GET {web}/api/menu`).
Without it, dishes show their ingredients.

## Run

```bash
cd ios
brew install xcodegen      # once
xcodegen generate          # creates MiniEats.xcodeproj from project.yml
open MiniEats.xcodeproj    # scheme MiniEats (customer) or MiniEatsMerchant, ⌘R
```

Both apps point at the team's backend by default (`BARMADE_API_URL` in `project.yml`). To
build against a different one: `BARMADE_API_URL=https://… xcodegen generate`, or change it in
the app under Account / Settings.

### Try it without touching the real kitchen

Every order placed on the team's backend deducts real stock. For local testing there is a
stand-in with the same routes and shapes:

```bash
node scripts/barmade-stub.mjs                 # http://127.0.0.1:8787, in-memory, resets on restart
```

Then set the server to `http://127.0.0.1:8787` in **Account** (customer) / **Settings**
(merchant) in the Simulator, or launch with `-barMadeServerURL http://127.0.0.1:8787`.
Place an order in the customer app, move it in the merchant app, watch the tracker follow.

## Tests

```bash
xcodebuild -project MiniEats.xcodeproj -scheme MiniEats \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

- `MiniEatsTests/BarMadeDecodingTests.swift`: the JSON contract with the BarMade API
  (camelCase fields, zone-less timestamps, the order body the web app sends).
- `MiniEatsUITests/OrderFlowUITests.swift`: end to end against the stub (start it first):
  name → menu → dish → cart (for here, table 7) → order → the test moves it through
  PREPARING / READY / COMPLETED over the API and the tracker follows.
- `MiniEatsMerchantUITests/MerchantUITests.swift` (scheme `MiniEatsMerchant`): a ticket placed
  over the API shows up with the customer's name and is moved Received → Preparing → Ready by tapping.

`TEST_RUNNER_SERVER_URL=http://host:port` points the UI tests at another server;
`TEST_RUNNER_SHOT_DIR=/path` saves a screenshot of each step.

## Layout

```
Shared/                  compiled into both apps
  BarMade.swift          models + async client for the BarMade API
  APIClient.swift        APIError, ISO date parsing, Info.plist lookup
  Components.swift       BarMade palette (gold/night/cream), chips, badges, buttons, status vocabulary
MiniEats/                customer app
  CustomerStore.swift    @Observable: name, menu + stock, servings math, cart, my orders
  Views/                 Welcome, Menu (home + dishes), DishSheet, Cart, Orders, OrderTracker, Account
MiniEatsMerchant/        kitchen app
  MerchantStore.swift    @Observable: BarMade snapshot, status moves
  Views/BarMadeViews.swift   Inventory, Menu, Orders (+ status buttons), Alerts, Settings
scripts/barmade-stub.mjs local stand-in for the API
```

## Not in the iPhone app (yet)

- Spanish copy and the "Picked for you" Claude suggestions (web only; the suggestions route
  `POST {web}/api/recommend` is there to call).
- Modifiers (extra cheese, …): the BarMade backend has none, so neither app offers them.
- Push notifications: the tracker polls while open.
