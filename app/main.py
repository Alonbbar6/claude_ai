"""FastAPI entry point. Run with: uvicorn app.main:app --reload"""

from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from typing import Literal

from pydantic import BaseModel, Field

from app import data, qa
from app.catalog import CatalogService, CategoryIn, CategoryUpdate, MenuItemIn, MenuItemUpdate
from app.data import COURIERS, RESTAURANTS, USERS
from app.demand import DemandService
from app.inventory import InventoryService, OutOfStock
from app.maps import LatLng, RouteProvider, get_provider
from app.models import CLOSED, Channel, CreateOrderRequest, Fulfillment, Ingredient, NotificationPreferences, OrderLine, TravelMode
from app.notifications.channels import SimulatedChannel, WebSocketChannel
from app.notifications.events import EventBus
from app.notifications.service import NotificationService
from app.orders import OrderService
from app.prediction.eta import EtaPredictor
from app.prediction.ready import ReadyTimePredictor

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

STATIC_DIR = Path(__file__).resolve().parent.parent / "static"


def build_services(
    *,
    stage_seconds: float = 4.0,
    failure_rate: float = 0.15,
    seed=None,
    routes: RouteProvider | None = None,
):
    """Wire everything together. Factored out so tests can build a fresh set."""
    data.reset()
    inventory = InventoryService(RESTAURANTS, data.seed_ingredients())
    predictor = EtaPredictor()
    predictor.load_or_train()
    ready = ReadyTimePredictor()
    ready.load_or_train()

    bus = EventBus()
    ws_channel = WebSocketChannel()
    channels = {
        Channel.PUSH: SimulatedChannel(Channel.PUSH, failure_rate, seed),
        Channel.SMS: SimulatedChannel(Channel.SMS, failure_rate, seed),
        Channel.EMAIL: SimulatedChannel(Channel.EMAIL, failure_rate, seed),
        Channel.WEBSOCKET: ws_channel,
    }
    notifications = NotificationService(bus, channels, USERS, RESTAURANTS)
    orders = OrderService(
        bus, predictor, routes or get_provider(), USERS, RESTAURANTS, COURIERS,
        ready_predictor=ready, inventory=inventory, stage_seconds=stage_seconds, seed=seed,
    )
    return predictor, bus, ws_channel, notifications, orders


@asynccontextmanager
async def lifespan(app: FastAPI):
    (
        app.state.predictor,
        app.state.bus,
        app.state.ws_channel,
        app.state.notifications,
        app.state.orders,
    ) = build_services()
    if os.environ.get("QA_SEED"):
        n = qa.seed(app.state.orders)
        logging.getLogger(__name__).info("QA_SEED: added %s and %d QA orders", qa.QA_RESTAURANT_ID, n)
    yield
    await app.state.orders.shutdown()


app = FastAPI(title="Mini Eats", lifespan=lifespan)


# ---- UI ----------------------------------------------------------------

@app.get("/", include_in_schema=False)
async def index():
    return FileResponse(STATIC_DIR / "index.html")


# ---- catalogue -----------------------------------------------------------

@app.get("/api/restaurants")
async def list_restaurants():
    # Recipes are internal to the kitchen; customers don't need them.
    return [r.model_dump(mode="json", exclude={"menu": {"__all__": {"recipe"}}}) for r in RESTAURANTS.values()]


@app.get("/api/users")
async def list_users():
    return list(USERS.values())


@app.get("/api/couriers")
async def list_couriers():
    return list(COURIERS.values())


@app.put("/api/users/{user_id}/preferences")
async def update_preferences(user_id: str, prefs: NotificationPreferences):
    user = USERS.get(user_id)
    if not user:
        raise HTTPException(404, "user not found")
    user.prefs = prefs
    return user


# ---- orders --------------------------------------------------------------

@app.post("/api/orders", status_code=201)
async def create_order(req: CreateOrderRequest):
    if req.user_id not in USERS:
        raise HTTPException(404, "user not found")
    if req.restaurant_id not in RESTAURANTS:
        raise HTTPException(404, "restaurant not found")
    if not req.lines:
        raise HTTPException(422, "order has no items")
    if (req.pickup_lat is None) != (req.pickup_lng is None):
        raise HTTPException(422, "send both pickup_lat and pickup_lng, or neither")
    if (req.delivery_lat is None) != (req.delivery_lng is None):
        raise HTTPException(422, "send both delivery_lat and delivery_lng, or neither")
    try:
        return await app.state.orders.create(req)
    except OutOfStock as exc:
        raise HTTPException(409, str(exc))
    except ValueError as exc:
        raise HTTPException(422, str(exc))


@app.get("/api/orders")
async def list_orders(user_id: str | None = None):
    svc: OrderService = app.state.orders
    orders = svc.orders.values()
    if user_id:
        orders = [o for o in orders if o.user_id == user_id]
    return [svc.with_live(o) for o in sorted(orders, key=lambda o: o.created_at, reverse=True)]


def _order_or_404(order_id: str):
    order = app.state.orders.orders.get(order_id)
    if not order:
        raise HTTPException(404, "order not found")
    return order


@app.get("/api/orders/{order_id}")
async def get_order(order_id: str):
    return app.state.orders.with_live(_order_or_404(order_id))


@app.get("/api/orders/{order_id}/dispatch")
async def get_dispatch_plan(order_id: str):
    order = _order_or_404(order_id)
    if not order.dispatch:
        raise HTTPException(404, "no dispatch plan yet (order not confirmed)")
    return order.dispatch


@app.post("/api/orders/{order_id}/advance")
async def advance_order(order_id: str):
    """Manually step the order forward (useful for demos and tests)."""
    _order_or_404(order_id)
    return await app.state.orders.advance(order_id)


@app.post("/api/orders/{order_id}/collect")
async def collect_order(order_id: str):
    """Pickup: the customer has the food."""
    _order_or_404(order_id)
    try:
        return await app.state.orders.collect(order_id)
    except ValueError as exc:
        raise HTTPException(409, str(exc))


class PickupPlanRequest(BaseModel):
    lat: float | None = None
    lng: float | None = None
    mode: TravelMode | None = None


@app.post("/api/orders/{order_id}/pickup-plan")
async def refresh_pickup_plan(order_id: str, req: PickupPlanRequest):
    """Re-plan when to leave from the customer's current location. The app
    calls this as the phone moves; it fires "time to head out" when due."""
    order = _order_or_404(order_id)
    if not order.is_pickup:
        raise HTTPException(409, "not a pickup order")
    return await app.state.orders.refresh_pickup_plan(order, lat=req.lat, lng=req.lng, mode=req.mode)


@app.post("/api/orders/{order_id}/cancel")
async def cancel_order(order_id: str):
    _order_or_404(order_id)
    return await app.state.orders.cancel(order_id)


@app.post("/api/orders/{order_id}/refresh-eta")
async def refresh_eta(order_id: str, demand_shock: float = 1.5):
    """Re-run the model with a simulated demand spike; triggers a delay alert
    if the ETA slips by 5+ minutes."""
    order = _order_or_404(order_id)
    if order.status in CLOSED:
        raise HTTPException(409, "order is closed")
    if order.is_pickup:
        raise HTTPException(409, "pickup orders have no delivery ETA")
    return await app.state.orders.refresh_eta(order, jitter=demand_shock)


# ---- prediction ----------------------------------------------------------

class PredictRequest(BaseModel):
    user_id: str
    restaurant_id: str
    item_count: int = 2
    raining: bool = False
    # Current location: when sent, the delivery quote is to here instead of
    # the saved address.
    lat: float | None = None
    lng: float | None = None
    # Cart lines: item-specific kitchen time (grab-and-go vs cooked).
    lines: list[OrderLine] | None = None


@app.post("/api/predict/eta")
async def predict_eta(req: PredictRequest):
    """Quote an ETA before ordering (what a customer sees on the menu page).
    Routes the restaurant -> customer leg first so the quote reflects
    real distance and current traffic."""
    user, rest = USERS.get(req.user_id), RESTAURANTS.get(req.restaurant_id)
    if not user or not rest:
        raise HTTPException(404, "user or restaurant not found")
    svc: OrderService = app.state.orders
    dest = svc.delivery_destination(user, req.lat, req.lng)
    route = await svc.routes.route(LatLng(rest.lat, rest.lng), dest)
    pred = app.state.predictor.predict(
        distance_km=route.distance_km,
        travel_time_min=route.duration_min,
        prep_time_min=svc.prep_minutes(rest, req.lines),
        item_count=(pred_count := max(1, sum(l.quantity for l in req.lines)) if req.lines else req.item_count),
        when=datetime.now(timezone.utc),
        raining=req.raining,
        courier_load=svc.courier_load(),
        restaurant_busy=svc.restaurant_busy(rest.id),
    )
    breakdown = await svc.delivery_breakdown(rest, dest, req.lines, pred_count)
    out = pred.model_dump(mode="json")
    if breakdown["grab_and_go"]:
        # No cooking: the courier chain is the whole story, not the kitchen model.
        from datetime import timedelta
        out["eta_minutes"] = breakdown["total_min"]
        out["eta_at"] = (datetime.now(timezone.utc) + timedelta(minutes=breakdown["total_min"])).isoformat()
    return {
        **out,
        "breakdown": breakdown,
        "route": route.__dict__,
        "destination": {
            "lat": dest.lat, "lng": dest.lng,
            "source": "current_location" if req.lat is not None and req.lng is not None else "saved_address",
        },
    }


class PickupQuoteRequest(BaseModel):
    user_id: str
    restaurant_id: str
    item_count: int = 2
    lat: float | None = None
    lng: float | None = None
    mode: TravelMode = TravelMode.DRIVING
    lines: list[OrderLine] | None = None


@app.post("/api/predict/pickup")
async def predict_pickup(req: PickupQuoteRequest):
    """Before ordering: when will it be ready, and when should I leave?"""
    user, rest = USERS.get(req.user_id), RESTAURANTS.get(req.restaurant_id)
    if not user or not rest:
        raise HTTPException(404, "user or restaurant not found")
    count = max(1, sum(l.quantity for l in req.lines)) if req.lines else max(1, req.item_count)
    return await app.state.orders.quote_pickup(
        user, rest, item_count=count, lat=req.lat, lng=req.lng, mode=req.mode, lines=req.lines)


@app.get("/api/predict/model")
async def model_info():
    p = app.state.predictor
    return {
        "metrics": {**p.metrics, **app.state.orders.ready.metrics},
        "feature_importance": p.feature_importance(),
    }


# ---- notifications -------------------------------------------------------

@app.get("/api/notifications")
async def list_notifications(user_id: str):
    svc: NotificationService = app.state.notifications
    return [
        {**n.model_dump(mode="json"), "deliveries": svc.deliveries_for(n.id)}
        for n in reversed(svc.for_user(user_id))
    ]


@app.post("/api/notifications/flush-deferred")
async def flush_deferred():
    return {"sent": await app.state.notifications.flush_deferred()}


@app.websocket("/ws/{user_id}")
async def websocket_endpoint(ws: WebSocket, user_id: str):
    if user_id not in USERS:
        await ws.close(code=4404)
        return
    channel: WebSocketChannel = app.state.ws_channel
    await ws.accept()
    channel.connect(user_id, ws)
    try:
        while True:
            await ws.receive_text()  # keepalive; client never needs to send
    except WebSocketDisconnect:
        pass
    finally:
        channel.disconnect(user_id, ws)


# ---- merchant: menu catalog & inventory --------------------------------------
# Restaurant-side API used by the Mini Eats Merchant app. No auth in this demo;
# a real deployment would scope these routes to the signed-in restaurant.

M = "/api/merchant/restaurants/{rid}"


def _inventory() -> InventoryService:
    return app.state.orders.inventory


def _catalog(rid: str) -> CatalogService:
    if rid not in RESTAURANTS:
        raise HTTPException(404, "restaurant not found")
    return CatalogService(RESTAURANTS, _inventory())


def _call(fn, *args):
    """Map service errors to HTTP: KeyError -> 404, ValueError -> 422."""
    try:
        return fn(*args)
    except KeyError:
        raise HTTPException(404, "not found")
    except ValueError as exc:
        raise HTTPException(422, str(exc))


@app.get(M + "/menu")
async def merchant_menu(rid: str):
    return _catalog(rid).menu(rid)


@app.post(M + "/categories", status_code=201)
async def add_category(rid: str, req: CategoryIn):
    return _call(_catalog(rid).add_category, rid, req)


@app.put(M + "/categories/{cid}")
async def update_category(rid: str, cid: str, req: CategoryUpdate):
    return _call(_catalog(rid).update_category, rid, cid, req)


@app.delete(M + "/categories/{cid}", status_code=204)
async def delete_category(rid: str, cid: str):
    _call(_catalog(rid).delete_category, rid, cid)


class ReorderRequest(BaseModel):
    ids: list[str]


@app.post(M + "/categories/reorder")
async def reorder_categories(rid: str, req: ReorderRequest):
    return _call(_catalog(rid).reorder_categories, rid, req.ids)


@app.post(M + "/items", status_code=201)
async def add_item(rid: str, req: MenuItemIn):
    return _call(_catalog(rid).add_item, rid, req)


@app.put(M + "/items/{iid}")
async def update_item(rid: str, iid: str, req: MenuItemUpdate):
    return _call(_catalog(rid).update_item, rid, iid, req)


@app.delete(M + "/items/{iid}", status_code=204)
async def delete_item(rid: str, iid: str):
    _call(_catalog(rid).delete_item, rid, iid)


@app.get(M + "/inventory")
async def list_inventory(rid: str):
    _catalog(rid)
    return _inventory().views(rid)


class IngredientIn(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    unit: str = Field(min_length=1, max_length=12)
    on_hand: float = Field(ge=0)
    low_threshold: float = Field(ge=0)
    par: float = Field(gt=0)
    daily_usage: float = Field(ge=0)


class IngredientUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=60)
    unit: str | None = Field(default=None, min_length=1, max_length=12)
    low_threshold: float | None = Field(default=None, ge=0)
    par: float | None = Field(default=None, gt=0)
    daily_usage: float | None = Field(default=None, ge=0)


@app.post(M + "/inventory", status_code=201)
async def add_ingredient(rid: str, req: IngredientIn):
    _catalog(rid)
    ing = _inventory().add(Ingredient(restaurant_id=rid, **req.model_dump()))
    return _inventory().view(ing)


@app.put(M + "/inventory/{ing_id}")
async def update_ingredient(rid: str, ing_id: str, req: IngredientUpdate):
    _catalog(rid)
    ing = _call(_inventory().update, rid, ing_id, req.model_dump(exclude_unset=True))
    return _inventory().view(ing)


@app.delete(M + "/inventory/{ing_id}", status_code=204)
async def delete_ingredient(rid: str, ing_id: str):
    _catalog(rid)
    _call(_inventory().delete, rid, ing_id)


class StockMove(BaseModel):
    kind: Literal["restock", "waste", "count"]
    quantity: float = Field(ge=0)  # restock/waste: amount; count: the counted total
    note: str = Field(default="", max_length=200)


@app.post(M + "/inventory/{ing_id}/adjust")
async def adjust_stock(rid: str, ing_id: str, req: StockMove):
    _catalog(rid)
    inv = _inventory()
    fn = {"restock": inv.restock, "waste": inv.waste, "count": inv.count}[req.kind]
    ing = _call(fn, rid, ing_id, req.quantity, req.note)
    return inv.view(ing)


@app.get(M + "/inventory/{ing_id}/history")
async def stock_history(rid: str, ing_id: str):
    _catalog(rid)
    _call(_inventory().get, rid, ing_id)
    return _inventory().history(ing_id)


@app.get(M + "/alerts")
async def inventory_alerts(rid: str):
    _catalog(rid)
    return _inventory().alerts_for(rid)



# ---- merchant: demand by time of day ----------------------------------------

def _demand() -> DemandService:
    # One per OrderService, so a fresh build_services() (tests) gets fresh history.
    if getattr(app.state, "demand_owner", None) is not app.state.orders:
        # QA restaurants are judged on their QA orders alone.
        app.state.demand = DemandService(
            RESTAURANTS, simulate=[rid for rid in RESTAURANTS if rid != qa.QA_RESTAURANT_ID])
        app.state.demand_owner = app.state.orders
    return app.state.demand


@app.get(M + "/demand")
async def demand_report(rid: str, days: int = Query(28, ge=1, le=90), include_simulated: bool = True):
    """Orders by meal period, what sells when, and menu suggestions."""
    _catalog(rid)
    return _demand().report(rid, app.state.orders.orders.values(), days=days,
                            include_simulated=include_simulated)

app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
