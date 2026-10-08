"""HTTP API and pages for the Barmade restaurant inventory demo.

Run:  .venv/bin/uvicorn web.app:app --reload --port 8010
  /        manager dashboard        /order   customer menu (QR target)
"""

from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from web.data import CHANNELS
from web.engine import OrderError, Store
from web.summary import write_summary

STATIC = Path(__file__).resolve().parent / "static"

app = FastAPI(title="Barmade Restaurant Inventory Demo", version="0.1.0")
app.state.store = Store()

_STATUS = {"UNKNOWN_CHANNEL": 404, "UNKNOWN_ITEM": 404, "UNKNOWN_INGREDIENT": 404,
           "INSUFFICIENT_ESTIMATED_STOCK": 409, "ITEM_PAUSED": 409}


@app.exception_handler(OrderError)
async def order_error(_: Request, e: OrderError):
    return JSONResponse({"error": {"code": e.code, "message": e.message, "details": e.details}},
                        status_code=_STATUS.get(e.code, 400))


def store() -> Store:
    return app.state.store


def _ingredient(ing_id: str):
    s = store()
    if ing_id not in s.ingredients:
        raise OrderError("UNKNOWN_INGREDIENT", f"Ingredient {ing_id} was not found.")
    return s.ingredients[ing_id]


# ---- pages -------------------------------------------------------------------

@app.get("/", include_in_schema=False)
async def dashboard():
    return FileResponse(STATIC / "dashboard.html")


@app.get("/order", include_in_schema=False)
async def order_page():
    return FileResponse(STATIC / "order.html")


# ---- read --------------------------------------------------------------------

@app.get("/api/state")
async def state():
    return store().state()


@app.get("/api/channels")
async def channels():
    return CHANNELS


@app.get("/api/menu")
async def menu():
    s = store()
    return [s.menu_view(m) for m in s.menu.values()]


@app.get("/api/inventory")
async def inventory():
    s = store()
    return [s.ingredient_view(i) for i in s.ingredients.values()]


@app.get("/api/inventory/count-sheet")
async def count_sheet():
    return store().count_sheet()


@app.get("/api/inventory/{ing_id}")
async def ingredient(ing_id: str, limit: int = 40):
    s = store()
    ing = _ingredient(ing_id)
    events = [s.event_view(e) for e in reversed(s.events) if e.ingredient_id == ing_id][:limit]
    dishes = [{"dish": m.name, **s.servings(m)} for m in s.menu.values()
              if any(l.ingredient_id == ing_id for l in m.recipe)]
    return {**s.ingredient_view(ing), "events": events, "dishes": dishes}


@app.get("/api/orders")
async def orders(limit: int = 50):
    s = store()
    return [s.order_view(o) for o in reversed(s.orders[-limit:])]


@app.get("/api/orders/{order_id}")
async def order_detail(order_id: str):
    s = store()
    o = next((o for o in s.orders if o.id == order_id), None)
    if not o:
        raise OrderError("UNKNOWN_ORDER", f"Order {order_id} was not found.")
    return s.order_view(o, trace=True)


@app.get("/api/alerts")
async def alerts(all: bool = False):
    s = store()
    return [s.alert_view(a) for a in reversed(s.alerts) if all or a.status == "active"]


@app.get("/api/specials")
async def specials():
    return store().overstock_specials()


@app.get("/api/history")
async def history(days: int = 60):
    return store().history(days)


@app.get("/api/day-facts")
async def day_facts():
    return store().day_facts()


# ---- write -------------------------------------------------------------------

class LineIn(BaseModel):
    menu_item_id: str
    quantity: int = Field(ge=0)


class OrderIn(BaseModel):
    channel: str
    lines: list[LineIn]
    customer: str | None = None


@app.post("/api/orders", status_code=201)
async def place_order(body: OrderIn):
    s = store()
    before = {a.id for a in s.alerts}
    o = s.place_order(body.channel, [(l.menu_item_id, l.quantity) for l in body.lines], body.customer)
    raised = [s.alert_view(a) for a in s.alerts if a.id not in before]
    return {"order": s.order_view(o, trace=True), "alerts_raised": raised,
            "servings_now": {l.menu_item_id: s.servings(s.menu[l.menu_item_id])["servings"] for l in o.lines}}


class PauseIn(BaseModel):
    paused: bool


@app.post("/api/menu/{item_id}/pause")
async def pause(item_id: str, body: PauseIn):
    s = store()
    if item_id not in s.menu:
        raise OrderError("UNKNOWN_ITEM", f"Menu item {item_id} was not found.")
    s.menu[item_id].paused = body.paused
    return s.menu_view(s.menu[item_id])


class CountIn(BaseModel):
    counts: dict[str, float]
    note: str = ""
    confirmed: bool = False


@app.post("/api/inventory/count/review")
async def review_count(body: CountIn):
    return store().review_count(body.counts)


@app.post("/api/inventory/count/confirm")
async def confirm_count(body: CountIn):
    if not body.confirmed:
        raise OrderError("CONFIRMATION_REQUIRED", "Review the differences and set confirmed=true to save.")
    s = store()
    events = s.confirm_count(body.counts, body.note)
    return {"saved": [s.event_view(e) for e in events],
            "inventory": [s.ingredient_view(s.ingredients[i]) for i in body.counts]}


class MoveIn(BaseModel):
    quantity: float = Field(gt=0)
    note: str = ""


@app.post("/api/inventory/{ing_id}/delivery", status_code=201)
async def delivery(ing_id: str, body: MoveIn):
    s = store()
    _ingredient(ing_id)
    e = s.receive(ing_id, body.quantity, body.note or "Delivery")
    return {"event": s.event_view(e), "ingredient": s.ingredient_view(s.ingredients[ing_id])}


@app.post("/api/inventory/{ing_id}/waste", status_code=201)
async def waste(ing_id: str, body: MoveIn):
    s = store()
    _ingredient(ing_id)
    e = s.waste(ing_id, body.quantity, body.note or "Waste")
    return {"event": s.event_view(e), "ingredient": s.ingredient_view(s.ingredients[ing_id])}


class RushIn(BaseModel):
    orders: int = Field(default=12, ge=1, le=50)
    seed: int | None = None


@app.post("/api/simulate-rush")
async def simulate_rush(body: RushIn):
    return store().simulate_rush(body.orders, body.seed)


@app.post("/api/close-day")
async def close_day():
    facts = store().close_day()
    return {"facts": facts, "summary": write_summary(facts)}


@app.post("/api/reset")
async def reset():
    app.state.store = Store()
    return {"ok": True, "orders": len(app.state.store.orders)}


app.mount("/assets", StaticFiles(directory=STATIC), name="assets")
