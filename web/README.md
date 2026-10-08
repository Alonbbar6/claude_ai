# Barmade restaurant inventory demo (web MVP)

Classroom prototype from `barmade_restaurant_inventory_prd.pdf`: a fictional Italian
restaurant where orders from simulated channels deplete recipe-based **estimated**
stock, raise low-stock alerts, and roll up into an AI-phrased end-of-day summary.

Not production software. Every channel is simulated, every number is synthetic.

## Run

```bash
cd claude_ai
.venv/bin/python -m pip install -r requirements.txt     # once
.venv/bin/uvicorn web.app:app --reload --port 8010
```

- Manager dashboard: http://127.0.0.1:8010/
- Customer menu (the QR target): http://127.0.0.1:8010/order

For phones in the room, run it behind a tunnel (ngrok / cloudflared) and the
dashboard's QR code will point at that public URL automatically.

Tests: `.venv/bin/pytest web/tests`

### AI summary

"Close day" sends the computed facts to Claude (`claude-opus-5-5`) to phrase a
four-section summary. Set `ANTHROPIC_API_KEY` (or `ant auth login`) to enable it.
Without credentials, or if the model's text mentions a number that is not in the
facts, a fixed template is used instead — the demo never depends on the model.
`BARMADE_SUMMARY_AI=off` forces the template.

## Demo script (matches PRD §2.3)

1. Open the dashboard: 60 days of seeded history, today's morning sales, no alerts.
   Mozzarella sits three pizzas above its alert line (a fridge incident this
   morning — see its movement history); Chicken is overstocked (double delivery).
2. Show the QR code. Participants pick a simulated channel, dishes, and submit.
3. Click an order in **Live orders**: channel payload → canonical order → recipe →
   ingredient movements → resulting estimate.
4. After the third pizza a **low-stock alert** appears with servings left and the
   order that triggered it. Pause the dish from the menu table (simulated).
5. **Inventory count**: prefilled with estimates, enter a real count, **Review**,
   then **Confirm** — nothing is saved before confirm.
6. **Overstock special**: Chicken Alfredo at 15% off, with the computed reason.
7. **Close day**: facts are computed in code; the model only writes the prose.
8. Thin participation? **Simulate rush** places 12 orders across channels.
   **Reset demo** reseeds everything for rehearsal.

## Layout

| File | Purpose |
|---|---|
| `web/data.py` | Restaurant, ingredients, recipes, channel adapters, 60-day seed |
| `web/engine.py` | Depletion, alerts, servings, counts, overstock, day facts (all deterministic) |
| `web/summary.py` | Claude phrasing + grounding check + template fallback |
| `web/app.py` | FastAPI routes and pages |
| `web/static/` | `dashboard.html` (manager), `order.html` (customer) |
| `web/tests/` | FR-1 … FR-10 acceptance tests |

Ingredient and menu IDs match the live BarMade API (`barmade-api.onrender.com`)
so this can later read from it instead of the in-memory store.

## Demo conventions (PRD open questions)

- Channels: dine-in, takeout, Barmade, Uber Eats, DoorDash, and website/direct
  (flagged in the UI as pending team confirmation).
- Low ingredient: alert + servings remaining, plus a manual, simulated **pause**.
- Regular count day: Sunday; the sheet prefills with today's estimate.
- Day cutoff: Close Day button; timezone America/New_York.
- Overstock: ≥ 1.5× par → special on the dish that uses the most of it, 15% off.
