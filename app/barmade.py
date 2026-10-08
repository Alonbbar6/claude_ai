"""BarMade kitchen as a Mini Eats restaurant.

BarMade (https://barmade-riw5.onrender.com) is a separate kitchen backend: one
kitchen, batch-tracked inventory, recipes, orders. It has no restaurant
profile, so this module:

- imports its menu and stock as the fictional restaurant ``rest_barmade``, so
  customers can order from it and items sell out like the seed restaurants.

By default that's all: orders stay in Mini Eats and stock is local after the
import, so testing never changes BarMade's shared data. With
``BARMADE_FORWARD_ORDERS=on`` it also:

- forwards each order placed here to ``POST /api/orders`` on BarMade, which
  deducts stock from its batches (oldest first), then re-reads BarMade's stock
  so the local copy matches what BarMade counted;
- treats BarMade as the owner of stock: the merchant API refuses manual stock
  moves for this restaurant (they'd be overwritten on the next sync).
  BarMade has no cancel route yet, so a cancelled order is flagged
  ``cancel_not_supported``.

Off unless ``BARMADE_API_URL`` is set. BarMade doesn't publish a location, so
the profile is fictional; override with ``BARMADE_NAME`` / ``BARMADE_LAT`` /
``BARMADE_LNG`` / ``BARMADE_ADDRESS`` / ``BARMADE_PHONE``.
"""

from __future__ import annotations

import asyncio
import logging
import os
from datetime import datetime, timezone

import httpx

from app.models import Ingredient, MenuCategory, MenuItem, Order, OrderStatus, Restaurant
from app.notifications.events import ORDER_STATUS_CHANGED, Event, EventBus

log = logging.getLogger(__name__)

BARMADE_RESTAURANT_ID = "rest_barmade"
CATEGORY_ID = "cat_barmade_menu"
# Fictional downtown Miami location. BarMade has no address.
DEFAULT_LOCATION = (25.7743, -80.1925)
DEFAULT_ADDRESS = "120 E Flagler St, Miami, FL 33131"
DEFAULT_PHONE = "305-555-0104"


class BarMadeError(Exception):
    """BarMade answered with an error or couldn't be reached."""


class BarMadeClient:
    """Thin async client. Responses are {"data": ...}; errors are
    {"error": {"code", "message"}}."""

    def __init__(self, base_url: str, *, transport: httpx.AsyncBaseTransport | None = None, timeout: float = 70.0):
        # Render's free tier sleeps when idle; the first request can take ~50 s.
        self._http = httpx.AsyncClient(base_url=base_url.rstrip("/"), timeout=timeout, transport=transport)
        self.base_url = base_url

    async def _call(self, method: str, path: str, **kw):
        try:
            r = await self._http.request(method, path, **kw)
        except httpx.HTTPError as exc:
            raise BarMadeError(f"{method} {path}: {exc.__class__.__name__}") from exc
        body = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
        if r.status_code >= 400:
            err = body.get("error", {}) if isinstance(body, dict) else {}
            raise BarMadeError(f"{err.get('code', r.status_code)}: {err.get('message', r.text[:200])}")
        return body.get("data", body)

    async def menu(self) -> list[dict]:
        return await self._call("GET", "/api/menu")

    async def inventory(self) -> list[dict]:
        return await self._call("GET", "/api/inventory")

    async def forecast(self) -> list[dict]:
        return await self._call("GET", "/api/inventory/forecast")

    async def place_order(self, items: list[dict], external_id: str) -> dict:
        return await self._call("POST", "/api/orders", json={
            "items": items, "channel": "mini_eats", "externalId": external_id})

    async def aclose(self) -> None:
        await self._http.aclose()


class BarMadeSync:
    def __init__(self, orders, bus: EventBus, client: BarMadeClient, *, profile: dict | None = None,
                 forward_orders: bool | None = None):
        self.orders = orders  # OrderService: restaurants, inventory
        self.client = client
        self.profile = profile or profile_from_env()
        self.forward_orders = forward_orders_from_env() if forward_orders is None else forward_orders
        self.imported = False
        self.last_sync: datetime | None = None
        self.last_error: str | None = None
        # Mini Eats order id -> {"status": sent|failed|cancel_not_supported, ...}
        self.forwarded: dict[str, dict] = {}
        self._tasks: set[asyncio.Task] = set()
        bus.subscribe(ORDER_STATUS_CHANGED, self.on_status_changed)

    @property
    def inventory(self):
        return self.orders.inventory

    # ---- import & sync -------------------------------------------------

    async def import_kitchen(self) -> Restaurant:
        """Create ``rest_barmade`` from BarMade's menu and stock."""
        menu, stock = await asyncio.gather(self.client.menu(), self.client.inventory())
        usage = await self._daily_usage()
        p = self.profile
        r = Restaurant(
            id=BARMADE_RESTAURANT_ID, name=p["name"], cuisine=p["cuisine"],
            lat=p["lat"], lng=p["lng"], address=p["address"], phone=p["phone"], avg_prep_min=p["avg_prep_min"],
            categories=[MenuCategory(id=CATEGORY_ID, name="Menu", sort=0)],
            menu=[
                MenuItem(id=m["id"], name=m["name"], price=m["price"], category_id=CATEGORY_ID,
                         description=", ".join(i["ingredientName"] for i in m["ingredients"]),
                         recipe={i["ingredientId"]: i["quantity"] for i in m["ingredients"]})
                for m in menu
            ],
        )
        self.orders.restaurants[r.id] = r
        inv = self.inventory
        for ing_id in [i.id for i in inv.for_restaurant(r.id)]:
            del inv.ingredients[ing_id]
        for s in stock:
            inv.ingredients[s["id"]] = Ingredient(
                id=s["id"], restaurant_id=r.id, name=s["name"], unit=s["unit"],
                on_hand=s["totalQuantity"], low_threshold=s["reorderPoint"],
                # Par isn't in BarMade; the merchant app draws a full bar at 2x reorder point.
                par=max(s["reorderPoint"] * 2, s["totalQuantity"]),
                daily_usage=usage.get(s["id"], 0.0),
            )
        inv.refresh_availability(r.id)
        self.imported, self.last_sync, self.last_error = True, _now(), None
        log.info("BarMade: imported %d menu items, %d ingredients", len(r.menu), len(stock))
        return r

    async def _daily_usage(self) -> dict[str, float]:
        try:
            return {f["ingredient_id"]: f.get("average_daily_usage") or 0.0 for f in await self.client.forecast()}
        except (BarMadeError, KeyError, TypeError) as exc:
            log.warning("BarMade forecast unavailable: %s", exc)
            return {}

    async def sync_stock(self) -> int:
        """Match local stock to BarMade's. Returns how many ingredients changed."""
        changed = 0
        for s in await self.client.inventory():
            ing = self.inventory.ingredients.get(s["id"])
            if ing is None or ing.restaurant_id != BARMADE_RESTAURANT_ID:
                continue
            if abs(ing.on_hand - s["totalQuantity"]) > 1e-9:
                self.inventory.count(BARMADE_RESTAURANT_ID, ing.id, s["totalQuantity"], "BarMade sync")
                changed += 1
        self.last_sync, self.last_error = _now(), None
        return changed

    async def import_with_retry(self, attempts: int = 3, delay: float = 10.0) -> bool:
        for n in range(1, attempts + 1):
            try:
                await self.import_kitchen()
                return True
            except (BarMadeError, KeyError, TypeError) as exc:
                self.last_error = str(exc)
                log.warning("BarMade import failed (%d/%d): %s", n, attempts, exc)
                if n < attempts:
                    await asyncio.sleep(delay)
        return False

    # ---- orders --------------------------------------------------------

    async def on_status_changed(self, event: Event) -> None:
        order: Order = event.payload["order"]
        if order.restaurant_id != BARMADE_RESTAURANT_ID or not self.forward_orders:
            return
        if order.status == OrderStatus.PLACED:
            # Don't hold up the customer's checkout on BarMade (cold starts).
            self._spawn(self.forward(order))
        elif order.status == OrderStatus.CANCELLED and order.id in self.forwarded:
            self.forwarded[order.id]["status"] = "cancel_not_supported"

    async def forward(self, order: Order) -> dict:
        items = [{"menuItemId": l.item_id, "quantity": l.quantity} for l in order.lines]
        try:
            remote = await self.client.place_order(items, external_id=order.id)
            result = {"status": "sent", "barmade_order_id": remote.get("id"), "at": _now().isoformat()}
            self.forwarded[order.id] = result
            await self.sync_stock()
        except BarMadeError as exc:
            result = {"status": "failed", "error": str(exc), "at": _now().isoformat()}
            self.forwarded[order.id] = result
            log.warning("BarMade: order %s not forwarded: %s", order.id, exc)
        return result

    def _spawn(self, coro) -> None:
        task = asyncio.get_running_loop().create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def drain(self) -> None:
        if self._tasks:
            await asyncio.gather(*list(self._tasks), return_exceptions=True)

    def status(self) -> dict:
        return {
            "source": self.client.base_url,
            "imported": self.imported,
            "forward_orders": self.forward_orders,
            "last_sync": self.last_sync.isoformat() if self.last_sync else None,
            "last_error": self.last_error,
            "orders": self.forwarded,
        }


def profile_from_env() -> dict:
    return {
        "name": os.environ.get("BARMADE_NAME", "BarMade Kitchen"),
        "cuisine": os.environ.get("BARMADE_CUISINE", "Italian"),
        "lat": float(os.environ.get("BARMADE_LAT", DEFAULT_LOCATION[0])),
        "lng": float(os.environ.get("BARMADE_LNG", DEFAULT_LOCATION[1])),
        "address": os.environ.get("BARMADE_ADDRESS", DEFAULT_ADDRESS),
        "phone": os.environ.get("BARMADE_PHONE", DEFAULT_PHONE),
        "avg_prep_min": float(os.environ.get("BARMADE_PREP_MIN", 15)),
    }


def forward_orders_from_env() -> bool:
    return os.environ.get("BARMADE_FORWARD_ORDERS", "off").lower() in ("on", "1", "true")


def _now() -> datetime:
    return datetime.now(timezone.utc)
