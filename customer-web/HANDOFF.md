# BarMade customer web: deployment hand-off (Railway)

The customer-facing ordering app (the page people open from the QR code). It is a Next.js 16 app in
`customer-web/` and runs as **one Railway service** that serves the pages and a small server API (`/api/*`).

```
Phone ─► customer-web (Railway) ──POST /api/orders──► BarMade API (Render) ─► Firestore barmade/state/*
                 │                                                               ▲
                 └────────── reads menu, stock, order status (read-only) ─────────┘
```

Orders, inventory, movements and order status belong to the **BarMade backend** (`https://barmade-riw5.onrender.com`).
The customer app never writes to `barmade/state/*`.

## Deploy on Railway

1. **New Project → Deploy from GitHub repo**, then pick this repo and the branch.
2. Service **Settings → Root Directory: `customer-web`**. Railway then reads `customer-web/railway.json`:
   - build: `npm run build`
   - start: `npm start` (listens on Railway's `$PORT`)
   - health check: `/api/health`
3. **Node 20+** (taken from `engines` in `package.json` and from `.nvmrc`). Next 16 does not build on Node 18;
   locally, run `nvm use` in `customer-web/` in every new terminal (or `nvm alias default 20` once).
4. **Variables** (Service → Variables). Ask Aleska for the values, and **never commit them or paste them in chat**:

| Variable | Required | Value |
|---|---|---|
| `BARMADE_API_URL` | **Yes** | `https://barmade-riw5.onrender.com` |
| `FIREBASE_SERVICE_ACCOUNT` | **Yes** | The Firebase service-account JSON **in base64, on one line** (the same value as in Aleska's `customer-web/.env`). Used to read the menu, stock and order status live, and to store customer profiles. |
| `FIREBASE_PROJECT_ID` | Yes | `barmade1-7be2b` |
| `ANTHROPIC_API_KEY` | Recommended | Claude key for the "Picked for you" suggestions (without it, rule-based suggestions are used). **Required for voice ordering**: without it the mic only answers "Sorry, I couldn't understand that". |
| `ANTHROPIC_MODEL` | No | Defaults to `claude-opus-5-5`. |
| `NEXT_PUBLIC_VOICE_ORDERING` | No | `on` shows the 🎤 voice-ordering button on the menu (Chrome / Safari). Read at **build** time, so redeploy after changing it. Off by default. |
| `VOICE_MODEL` | No | Model for voice only (defaults to `ANTHROPIC_MODEL`). |

5. **Settings → Networking → Generate Domain**. That URL is the one for the QR code.
6. **Check it:** open `https://<domain>/api/health`. It should return:
   ```json
   {"ok":true,"db":"firestore","orders":"barmade-api","ai":true}
   ```
   If it says `"db":"embedded"` or `"orders":"local"`, a variable is missing: the app would then keep data
   on Railway's disk, which is wiped on every deploy.
7. Optional end-to-end check from your machine: `cd customer-web && npm install && npm run smoke -- https://<domain>`.
   It is **read-only** against the real backend (health, menu, suggestions). Add `--write` to place ONE real
   test order (a Coca-Cola). That deducts real inventory, so only do it on purpose.

## Voice ordering (optional)

To turn it on: set `NEXT_PUBLIC_VOICE_ORDERING=on` and `ANTHROPIC_API_KEY` in Railway, then **redeploy** (the flag is
baked in at build time). Check it on a phone over the Railway HTTPS URL.


With `NEXT_PUBLIC_VOICE_ORDERING=on`, a 🎤 button appears on the Trattoria menu. The customer says
"two Margheritas and a Coke, to go" (English or Spanish). Claude turns it into cart items, the server checks them
against the live menu and stock, and the mic bubble lists **exactly what was added**, with **Undo** and **Review order**
(which opens the cart with to go / for here and the table pre-set). If a word is unclear or not on the menu, nothing is
added: the likely dishes appear as choices to tap. Voice never places an order by itself.

It can also **build a meal**: "dinner for two under $40, no pork". Claude picks the dishes; code removes anything sold
out or containing what the customer avoids (their saved list plus what they said), trims to the budget and computes the
total (PRD: the AI never calculates). The saved avoid list (Tastes → "Anything to avoid?") also reshapes the menu:
clashing dishes get a ⚠ chip, sort last and can be hidden. Questions like "where can I get sushi?" show matching dishes, including closed restaurants. The mic
needs HTTPS (Railway provides it) and the browser's microphone permission.

## Group orders

On the Trattoria menu, **"Order as a group"** creates a 4-letter code / link (`/g/CODE`). Friends open it,
enter their name and add their own dishes; everyone sees each other's dishes live. The host picks
**"each pays their own"** or **"split equally"** (exact cents), to go / for here and table, then sends **one**
order to the kitchen through the normal path (stock check, BarMade API). Each person sees what they pay
(at the counter / table, no online payment) and the host can mark people as paid. Groups live in Firestore
`group_orders/{code}` and expire after 6 hours.

## Before the demo

- **Firestore free tier: ~50k reads/day for the whole team.** It ran out once during testing (every backend call
  failed until the daily reset, midnight Pacific). The customer app caches reads, but keep dashboards that poll
  Firestore to a minimum on demo day, or switch the Firebase project to the pay-as-you-go plan.
  While the quota is out, the menu falls back to the synthetic dataset (browsing and the cart, voice included, still
  work) but **placing an order fails** with a generic error, because the BarMade backend can't write. It recovers by
  itself after the reset; no redeploy needed.
- **Wake Render up ~2 minutes before presenting**: open `https://barmade-riw5.onrender.com/api/menu`. On the
  free tier the first request after a nap takes ~50 s. The customer app also pings it every few minutes while
  someone is browsing.
- Open the Railway URL on a real phone: enter a name, add a dish, then check that the order shows up on the merchant side.
- The merchant moves orders with `PATCH /api/orders/:id/status` (`RECEIVED → PREPARING → READY → COMPLETED`).
  The customer's order page updates by itself within ~3 s.

## Run locally

```bash
cd customer-web
nvm use               # Node 20
npm install
cp .env.example .env  # then fill in the variables above
npm run dev           # http://localhost:3000
```

With no `BARMADE_API_URL` and no Firebase variables, the app runs fully offline on the synthetic dataset and an
embedded database in `customer-web/.pglite/` (delete that folder to reset). That's handy for UI work, and it
never touches the team's data.

## Folder map

```
customer-web/
├── app/                    pages + API routes
│   ├── page.tsx            home: open restaurant, chef's special, closed "More on BarMade"
│   ├── r/[id]/page.tsx     restaurant menu (Trattoria orders; the others are browse-only)
│   ├── order/[id]/page.tsx live order tracking
│   ├── credits/            photo/illustration credits
│   └── api/
│       ├── customers/      POST create (name only) · GET/PATCH /:id (language, tastes)
│       ├── menu/           GET live menu with stock-based availability + chef's special
│       ├── orders/         POST place order (→ BarMade API) · GET /:id (status)
│       ├── recommend/      POST taste-based suggestions (Claude, falls back to rules)
│       └── health/         GET which storage / backend / AI is active
├── components/             UI (React, Tailwind)
├── lib/
│   ├── barmade.ts          BarMade API client + live menu/inventory (Firestore read-only)
│   ├── barmade-orders.ts   orders through the BarMade API, status mapping
│   ├── catalog.ts          menu, recipes, allergens, stock, chef's special
│   ├── orders.ts           validation, then BarMade API (or local store when offline)
│   ├── customers.ts        name-only accounts + taste profile
│   ├── recommend.ts        Claude suggestions (no customer personal data sent)
│   ├── store/              where customers live: firestore.ts · postgres.ts (offline)
│   ├── content.ts          EN/ES copy, images, browse-only restaurants
│   └── i18n.ts             English (default) / Spanish
├── data/barmade/           synthetic dataset (used offline, and for the 12 dishes shown as sold out)
├── public/images/          Trattoria photos (Wikimedia, see credits.json) + original SVG illustrations
├── scripts/smoke.mjs       end-to-end check
└── railway.json            Railway build/start/health-check
```

## Demo guardrails (from the PRD)

- Stock shown to customers is an **estimate** from recipes and live batches. Sold-out dishes can't be ordered.
- Claude only gets the menu and anonymous tastes, never the customer's name or id. Code decides what is safe
  and in stock; Claude only ranks and phrases.
- Allergen badges are derived from recipe ingredients and come with an "ask staff" note.
- The footer says "Classroom demo · synthetic data". There are no payments: "Pay at pickup / at your table".

See also `docs/handoff/orders-contract.md` for the contract with the backend.
