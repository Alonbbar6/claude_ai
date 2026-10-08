"""BarMade kitchen as a Mini Eats restaurant, against a fake BarMade that
answers in the live API's shapes (checked 2026-10-07)."""

import json
from datetime import datetime

import httpx
import pytest
from httpx import ASGITransport, AsyncClient

from app.barmade import BARMADE_RESTAURANT_ID, BarMadeClient, BarMadeSync
from app.main import app, build_services

M = f"/api/merchant/restaurants/{BARMADE_RESTAURANT_ID}"


class FakeBarMade:
    """Menu, batch stock and orders; POST /api/orders deducts stock."""

    def __init__(self):
        self.stock = {
            "ING-003": {"name": "Pizza Dough", "unit": "units", "qty": 3, "reorder": 10},
            "ING-001": {"name": "Tomato Sauce", "unit": "ml", "qty": 17000, "reorder": 10000},
        }
        self.menu = [{"id": "MENU-001", "name": "Margherita Pizza", "price": 15.99, "ingredients": [
            {"ingredientId": "ING-003", "quantity": 1, "ingredientName": "Pizza Dough", "unit": "units"},
            {"ingredientId": "ING-001", "quantity": 120, "ingredientName": "Tomato Sauce", "unit": "ml"},
        ]}]
        self.orders: list[dict] = []
        self.fail_orders = False

    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if request.method == "GET" and path == "/api/menu":
            return self._ok(self.menu)
        if request.method == "GET" and path == "/api/inventory":
            return self._ok([{
                "id": i, "name": s["name"], "category": "x", "unit": s["unit"], "reorderPoint": s["reorder"],
                "totalQuantity": s["qty"], "expiredQuantity": 0, "status": "IN_STOCK", "batches": [],
            } for i, s in self.stock.items()])
        if request.method == "GET" and path == "/api/inventory/forecast":
            return self._ok([{"ingredient_id": "ING-003", "average_daily_usage": 12}])
        if request.method == "POST" and path == "/api/orders":
            if self.fail_orders:
                return httpx.Response(409, json={"error": {"code": "INSUFFICIENT_STOCK", "message": "Not enough Pizza Dough"}})
            body = json.loads(request.content)
            self.orders.append(body)
            for line in body["items"]:
                recipe = next(m for m in self.menu if m["id"] == line["menuItemId"])["ingredients"]
                for r in recipe:
                    self.stock[r["ingredientId"]]["qty"] -= r["quantity"] * line["quantity"]
            return httpx.Response(201, json={"data": {"id": f"ORD-{100 + len(self.orders)}", "status": "COMPLETED"}})
        return httpx.Response(404, json={"error": {"code": "ROUTE_NOT_FOUND", "message": path}})

    @staticmethod
    def _ok(data):
        return httpx.Response(200, json={"count": len(data), "data": data})


@pytest.fixture
async def setup():
    (
        app.state.predictor, app.state.bus, app.state.ws_channel,
        app.state.notifications, app.state.orders,
    ) = build_services(stage_seconds=3600, failure_rate=0.0, seed=0)
    app.state.notifications.clock = lambda: datetime(2026, 1, 1, 12, 0)
    fake = FakeBarMade()
    client = BarMadeClient("http://barmade.test", transport=httpx.MockTransport(fake.handler))
    sync = BarMadeSync(app.state.orders, app.state.bus, client, forward_orders=True)
    app.state.barmade = sync
    await sync.import_kitchen()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c, fake, sync
    app.state.barmade = None
    await client.aclose()
    await app.state.orders.shutdown()


def order(qty=1):
    return {"user_id": "user_sam", "restaurant_id": BARMADE_RESTAURANT_ID,
            "lines": [{"item_id": "MENU-001", "quantity": qty}]}


async def test_kitchen_shows_up_as_a_restaurant_customers_can_order_from(setup):
    c, _, _ = setup
    r = next(r for r in (await c.get("/api/restaurants")).json() if r["id"] == BARMADE_RESTAURANT_ID)
    assert r["name"] == "BarMade Kitchen"
    item = r["menu"][0]
    assert (item["id"], item["price"], item["sold_out"]) == ("MENU-001", 15.99, False)
    assert item["description"] == "Pizza Dough, Tomato Sauce"

    stock = {i["id"]: i for i in (await c.get(M + "/inventory")).json()}
    assert stock["ING-003"]["on_hand"] == 3 and stock["ING-003"]["low_threshold"] == 10
    assert stock["ING-003"]["daily_usage"] == 12  # from BarMade's forecast


async def test_orders_are_forwarded_and_stock_follows_barmade(setup):
    c, fake, sync = setup
    r = await c.post("/api/orders", json=order(2))
    assert r.status_code == 201
    oid = r.json()["id"]
    await sync.drain()

    assert fake.orders == [{"items": [{"menuItemId": "MENU-001", "quantity": 2}],
                            "channel": "mini_eats", "externalId": oid}]
    status = (await c.get("/api/merchant/barmade")).json()
    assert status["orders"][oid]["status"] == "sent" and status["orders"][oid]["barmade_order_id"] == "ORD-101"
    assert app.state.orders.inventory.ingredients["ING-003"].on_hand == 1

    # BarMade's own count wins, e.g. it threw out an expired batch.
    fake.stock["ING-003"]["qty"] = 0
    assert (await c.post("/api/merchant/barmade/sync")).json() == {"imported": True, "changed": 1}
    menu = next(r for r in (await c.get("/api/restaurants")).json() if r["id"] == BARMADE_RESTAURANT_ID)["menu"]
    assert menu[0]["sold_out"]
    assert (await c.post("/api/orders", json=order(1))).status_code == 409


async def test_rejected_forward_is_recorded_not_fatal(setup):
    c, fake, sync = setup
    fake.fail_orders = True
    r = await c.post("/api/orders", json=order(1))
    assert r.status_code == 201  # the customer isn't blocked on BarMade
    await sync.drain()
    rec = sync.forwarded[r.json()["id"]]
    assert rec["status"] == "failed" and "INSUFFICIENT_STOCK" in rec["error"]


async def test_stock_is_read_only_here_and_other_restaurants_unaffected(setup):
    c, _, _ = setup
    r = await c.post(M + "/inventory/ING-003/adjust", json={"kind": "restock", "quantity": 5})
    assert r.status_code == 409 and "BarMade" in r.json()["detail"]
    ok = await c.post("/api/merchant/restaurants/rest_burger/inventory/ing_bun/adjust",
                      json={"kind": "restock", "quantity": 5})
    assert ok.status_code == 200


async def test_status_404_when_not_connected(setup):
    c, _, _ = setup
    app.state.barmade = None
    assert (await c.get("/api/merchant/barmade")).status_code == 404


async def test_by_default_orders_stay_local_and_stock_is_editable(setup):
    c, fake, sync = setup
    sync.forward_orders = False
    r = await c.post("/api/orders", json=order(2))
    assert r.status_code == 201
    await sync.drain()
    assert fake.orders == [] and sync.forwarded == {}  # BarMade untouched
    assert fake.stock["ING-003"]["qty"] == 3
    assert app.state.orders.inventory.ingredients["ING-003"].on_hand == 1  # deducted locally

    r = await c.post(M + "/inventory/ING-003/adjust", json={"kind": "restock", "quantity": 5})
    assert r.status_code == 200 and r.json()["on_hand"] == 6

    rest = next(r for r in (await c.get("/api/restaurants")).json() if r["id"] == BARMADE_RESTAURANT_ID)
    assert rest["address"] == "120 E Flagler St, Miami, FL 33131" and rest["phone"] == "305-555-0104"
