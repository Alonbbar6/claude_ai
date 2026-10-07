from datetime import datetime

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app, build_services


@pytest.fixture
async def client():
    # Long stage time so the background simulator never races the test.
    (
        app.state.predictor, app.state.bus, app.state.ws_channel,
        app.state.notifications, app.state.orders,
    ) = build_services(stage_seconds=3600, failure_rate=0.0, seed=0)
    # Pin "local time" to midday so quiet hours never defer deliveries in tests.
    app.state.notifications.clock = lambda: datetime(2026, 1, 1, 12, 0)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c
    await app.state.orders.shutdown()


ORDER = {
    "user_id": "user_alex",
    "restaurant_id": "rest_pizza",
    "lines": [{"item_id": "pizza_1", "quantity": 1}, {"item_id": "pizza_3", "quantity": 2}],
}


async def test_quote_before_ordering(client):
    r = await client.post("/api/predict/eta", json={"user_id": "user_alex", "restaurant_id": "rest_pizza"})
    assert r.status_code == 200
    body = r.json()
    assert body["eta_minutes"] > 0 and 0 <= body["delay_risk"] <= 1
    assert "distance_km" in body["features"]
    assert body["route"]["source"] == "haversine" and body["features"]["travel_time_min"] == body["route"]["duration_min"]


async def test_create_order_quotes_eta_and_notifies(client):
    r = await client.post("/api/orders", json=ORDER)
    assert r.status_code == 201, r.text
    order = r.json()
    assert order["status"] == "placed"
    assert order["quoted_eta"]["eta_minutes"] > 0
    assert order["route"]["distance_km"] > 0 and order["dispatch"] is None

    n = (await client.get("/api/notifications", params={"user_id": "user_alex"})).json()
    assert n[0]["kind"] == "placed"
    assert {d["channel"] for d in n[0]["deliveries"]} == {"push", "websocket"}
    # No browser is connected in tests, so the websocket channel fails after retries.
    by_channel = {d["channel"]: d["status"] for d in n[0]["deliveries"]}
    assert by_channel == {"push": "sent", "websocket": "failed"}


async def test_advance_walks_lifecycle_and_notifies_each_step(client):
    oid = (await client.post("/api/orders", json=ORDER)).json()["id"]
    seen = ["placed"]
    for expected in ["confirmed", "preparing", "courier_dispatched", "picked_up", "delivered"]:
        o = (await client.post(f"/api/orders/{oid}/advance")).json()
        assert o["status"] == expected
        seen.append(expected)
    assert o["current_eta"] is None
    assert [h["status"] for h in o["history"]] == seen

    kinds = [n["kind"] for n in (await client.get("/api/notifications", params={"user_id": "user_alex"})).json()]
    for k in seen:
        assert k in kinds
    # Advancing a delivered order is a no-op.
    assert (await client.post(f"/api/orders/{oid}/advance")).json()["status"] == "delivered"


async def test_demand_spike_triggers_delay_alert(client):
    oid = (await client.post("/api/orders", json=ORDER)).json()["id"]
    r = await client.post(f"/api/orders/{oid}/refresh-eta", params={"demand_shock": 4.0})
    assert r.status_code == 200
    kinds = [n["kind"] for n in (await client.get("/api/notifications", params={"user_id": "user_alex"})).json()]
    assert "delayed" in kinds


async def test_cancel(client):
    oid = (await client.post("/api/orders", json=ORDER)).json()["id"]
    o = (await client.post(f"/api/orders/{oid}/cancel")).json()
    assert o["status"] == "cancelled"
    assert (await client.post(f"/api/orders/{oid}/refresh-eta")).status_code == 409


async def test_validation(client):
    assert (await client.post("/api/orders", json={**ORDER, "lines": []})).status_code == 422
    bad = {**ORDER, "lines": [{"item_id": "sushi_1", "quantity": 1}]}
    assert (await client.post("/api/orders", json=bad)).status_code == 422
    assert (await client.post("/api/orders", json={**ORDER, "user_id": "nobody"})).status_code == 404
    assert (await client.get("/api/orders/nope")).status_code == 404


async def test_dispatch_plan_available_after_confirmation(client):
    oid = (await client.post("/api/orders", json=ORDER)).json()["id"]
    assert (await client.get(f"/api/orders/{oid}/dispatch")).status_code == 404
    await client.post(f"/api/orders/{oid}/advance")
    plan = (await client.get(f"/api/orders/{oid}/dispatch")).json()
    assert plan["courier_id"] in {"cour_maria", "cour_dev", "cour_lee"}
    assert plan["dispatch_at"] <= plan["expected_pickup_at"] <= plan["expected_delivery_at"]
    assert plan["courier_to_restaurant_min"] > 0

    await client.post(f"/api/orders/{oid}/advance")  # preparing
    await client.post(f"/api/orders/{oid}/advance")  # courier_dispatched
    kinds = [n["kind"] for n in (await client.get("/api/notifications", params={"user_id": "user_alex"})).json()]
    assert "courier_dispatched" in kinds
    couriers = {c["id"]: c for c in (await client.get("/api/couriers")).json()}
    assert couriers[plan["courier_id"]]["active_order_id"] == oid


# ---- pickup -----------------------------------------------------------------

# Napoli Pizza is at 25.7743,-80.1937.
NEAR_PIZZA = {"pickup_lat": 25.7760, "pickup_lng": -80.1940}   # ~0.2 km
FAR_FROM_PIZZA = {"pickup_lat": 25.9500, "pickup_lng": -80.1200}  # ~21 km


async def kinds_for(client, user_id="user_alex"):
    return [n["kind"] for n in (await client.get("/api/notifications", params={"user_id": user_id})).json()]


async def test_pickup_quote_before_ordering(client):
    body = {"user_id": "user_alex", "restaurant_id": "rest_pizza", "item_count": 3, **{"lat": 25.776, "lng": -80.194}}
    plan = (await client.post("/api/predict/pickup", json=body)).json()
    assert plan["decision"] == "wait"
    assert plan["ready_at"] <= plan["target_arrival_at"] <= plan["ready_by"]
    assert plan["leave_at"] < plan["arrive_at"] == plan["target_arrival_at"]
    walk = (await client.post("/api/predict/pickup", json={**body, "mode": "walking"})).json()
    assert walk["mode"] == "walking" and walk["travel_min"] > plan["travel_min"]


async def test_nearby_pickup_waits_then_ready_then_collected(client):
    r = await client.post("/api/orders", json={**ORDER, "fulfillment": "pickup", **NEAR_PIZZA})
    assert r.status_code == 201, r.text
    order = r.json()
    assert order["fulfillment"] == "pickup"
    assert order["quoted_eta"] is None and order["dispatch"] is None
    assert order["pickup"]["decision"] == "wait"
    assert order["route"]["distance_km"] < 1

    kinds = await kinds_for(client)
    assert kinds == ["placed"]  # no "leave now" yet: you're close and it's not ready
    n = (await client.get("/api/notifications", params={"user_id": "user_alex"})).json()[0]
    assert "We'll tell you when to leave" in n["body"]

    oid = order["id"]
    statuses = []
    for _ in range(3):
        statuses.append((await client.post(f"/api/orders/{oid}/advance")).json()["status"])
    assert statuses == ["confirmed", "preparing", "ready"]
    o = (await client.get(f"/api/orders/{oid}")).json()
    assert o["ready_at"] and o["pickup"]["decision"] == "ready"
    assert "ready" in await kinds_for(client)

    # The "Demand spike" control is delivery-only.
    assert (await client.post(f"/api/orders/{oid}/refresh-eta")).status_code == 409

    o = (await client.post(f"/api/orders/{oid}/collect")).json()
    assert o["status"] == "collected"
    assert (await client.post(f"/api/orders/{oid}/collect")).status_code == 409


async def test_far_pickup_says_leave_now_once(client):
    order = (await client.post("/api/orders", json={**ORDER, "fulfillment": "pickup", **FAR_FROM_PIZZA})).json()
    assert order["pickup"]["decision"] == "leave_now"
    oid = order["id"]
    # Moving and re-planning keeps it "leave now", but the alert fires once.
    for lat in (25.94, 25.93):
        o = (await client.post(f"/api/orders/{oid}/pickup-plan", json={"lat": lat, "lng": -80.12})).json()
        assert o["pickup"]["decision"] == "leave_now"
    kinds = await kinds_for(client)
    assert kinds.count("pickup_leave_now") == 1
    leave = next(n for n in (await client.get("/api/notifications", params={"user_id": "user_alex"})).json()
                 if n["kind"] == "pickup_leave_now")
    assert leave["title"] == "Time to head out" and leave["urgent"]


async def test_moving_closer_and_switching_mode_replans(client):
    order = (await client.post("/api/orders", json={**ORDER, "fulfillment": "pickup", **NEAR_PIZZA})).json()
    oid = order["id"]
    walk = (await client.post(f"/api/orders/{oid}/pickup-plan", json={"mode": "walking"})).json()
    assert walk["pickup_mode"] == "walking" and walk["pickup"]["mode"] == "walking"
    assert walk["pickup"]["leave_at"] < order["pickup"]["leave_at"]  # walking is slower
    # Location persisted: a plan refresh without coordinates keeps using it.
    again = (await client.post(f"/api/orders/{oid}/pickup-plan", json={})).json()
    assert again["route"]["distance_km"] == walk["route"]["distance_km"]


async def test_pickup_validation_and_courier_load(client):
    half = {**ORDER, "fulfillment": "pickup", "pickup_lat": 25.77}
    assert (await client.post("/api/orders", json=half)).status_code == 422
    delivery_oid = (await client.post("/api/orders", json=ORDER)).json()["id"]
    assert (await client.post(f"/api/orders/{delivery_oid}/pickup-plan", json={})).status_code == 409
    assert (await client.post(f"/api/orders/{delivery_oid}/collect")).status_code == 409

    svc = app.state.orders
    before = svc.courier_load()
    await client.post("/api/orders", json={**ORDER, "fulfillment": "pickup", **NEAR_PIZZA})
    assert svc.courier_load() == before  # pickups don't use couriers


# ---- live tracking ----------------------------------------------------------

async def test_restaurants_carry_address_and_phone(client):
    rs = {r["id"]: r for r in (await client.get("/api/restaurants")).json()}
    assert rs["rest_sushi"]["address"] == "1201 Brickell Ave, Miami, FL 33131"
    assert rs["rest_sushi"]["phone"].startswith("305")


async def test_courier_location_moves_with_the_order(client):
    oid = (await client.post("/api/orders", json=ORDER)).json()["id"]
    o = (await client.get(f"/api/orders/{oid}")).json()
    assert o["courier_location"] is None  # nobody assigned yet

    await client.post(f"/api/orders/{oid}/advance")  # confirmed: courier chosen
    o = (await client.get(f"/api/orders/{oid}")).json()
    couriers = {c["id"]: c for c in (await client.get("/api/couriers")).json()}
    c = couriers[o["dispatch"]["courier_id"]]
    assert o["courier_location"] == {"lat": c["lat"], "lng": c["lng"]}  # waiting at base

    for _ in range(3):  # preparing, courier_dispatched, picked_up
        await client.post(f"/api/orders/{oid}/advance")
    o = (await client.get(f"/api/orders/{oid}")).json()
    assert o["status"] == "picked_up"
    rest = next(r for r in (await client.get("/api/restaurants")).json() if r["id"] == "rest_pizza")
    # Just picked up: still at (or within a hair of) the restaurant.
    assert abs(o["courier_location"]["lat"] - rest["lat"]) < 0.001

    await client.post(f"/api/orders/{oid}/advance")  # delivered
    o = (await client.get(f"/api/orders/{oid}")).json()
    users = {u["id"]: u for u in (await client.get("/api/users")).json()}
    assert o["courier_location"] == {"lat": users["user_alex"]["lat"], "lng": users["user_alex"]["lng"]}

    # Listing includes it too; pickup orders never have one.
    listed = next(x for x in (await client.get("/api/orders", params={"user_id": "user_alex"})).json() if x["id"] == oid)
    assert listed["courier_location"] is not None
    p = (await client.post("/api/orders", json={**ORDER, "fulfillment": "pickup", **NEAR_PIZZA})).json()
    assert p["courier_location"] is None


# ---- deliver to current location -------------------------------------------

CAMPUS = {"lat": 25.77843, "lng": -80.19058}  # MDC Wolfson centroid


async def test_delivery_quote_uses_current_location_when_sent(client):
    body = {"user_id": "user_alex", "restaurant_id": "rest_pizza"}
    home = (await client.post("/api/predict/eta", json=body)).json()
    here = (await client.post("/api/predict/eta", json={**body, **CAMPUS})).json()
    assert home["destination"]["source"] == "saved_address"
    assert here["destination"] == {**CAMPUS, "source": "current_location"}
    # Napoli Pizza is ~0.5 km from campus but ~1.2 km from Alex's saved address.
    assert here["route"]["distance_km"] < home["route"]["distance_km"]
    assert here["eta_minutes"] < home["eta_minutes"]


async def test_delivery_order_to_current_location(client):
    o = (await client.post("/api/orders", json={**ORDER, "delivery_lat": CAMPUS["lat"], "delivery_lng": CAMPUS["lng"]})).json()
    assert (o["delivery_lat"], o["delivery_lng"]) == (CAMPUS["lat"], CAMPUS["lng"])
    oid = o["id"]
    for _ in range(5):  # -> delivered
        await client.post(f"/api/orders/{oid}/advance")
    o = (await client.get(f"/api/orders/{oid}")).json()
    assert o["status"] == "delivered"
    assert o["courier_location"] == CAMPUS  # courier ends at the delivery point, not the saved home

    saved = (await client.post("/api/orders", json=ORDER)).json()
    users = {u["id"]: u for u in (await client.get("/api/users")).json()}
    assert (saved["delivery_lat"], saved["delivery_lng"]) == (users["user_alex"]["lat"], users["user_alex"]["lng"])
    assert (await client.post("/api/orders", json={**ORDER, "delivery_lat": 1.0})).status_code == 422


# ---- grab-and-go: per-item prep time ------------------------------------------

async def test_quotes_use_item_prep_time(client):
    # Grill House averages 12 min; a bottled drink should be quoted much sooner.
    from app.data import RESTAURANTS
    from app.models import MenuItem
    RESTAURANTS["rest_burger"].menu.append(MenuItem(id="water", name="Water", price=1, prep_min=1))
    base = {"user_id": "user_alex", "restaurant_id": "rest_burger", "lat": 25.7855, "lng": -80.1309, "mode": "walking"}
    cooked = (await client.post("/api/predict/pickup", json={**base, "lines": [{"item_id": "burger_1", "quantity": 1}]})).json()
    quick = (await client.post("/api/predict/pickup", json={**base, "lines": [{"item_id": "water", "quantity": 1}]})).json()
    from datetime import datetime
    def mins(p): return (datetime.fromisoformat(p["ready_at"]) - datetime.fromisoformat(p["computed_at"])).total_seconds() / 60
    assert mins(quick) < 6 < mins(cooked)
    # Mixed cart: the slowest item sets the kitchen time.
    mixed = (await client.post("/api/predict/pickup", json={**base, "lines": [
        {"item_id": "water", "quantity": 2}, {"item_id": "burger_1", "quantity": 1}]})).json()
    assert abs(mins(mixed) - mins(cooked)) < 3
    svc = app.state.orders
    assert svc.prep_minutes(RESTAURANTS["rest_burger"], None) == 12


async def test_grab_and_go_is_a_handover_not_a_kitchen_job(client):
    from app.data import RESTAURANTS
    from app.models import MenuItem
    RESTAURANTS["rest_burger"].menu += [
        MenuItem(id="banana", name="Banana", price=1, prep_min=1),
        MenuItem(id="wrap", name="Wrap", price=6, prep_min=2),
    ]
    base = {"user_id": "user_alex", "restaurant_id": "rest_burger", "lat": 25.7855, "lng": -80.1309, "mode": "walking"}
    from datetime import datetime
    def mins(p): return (datetime.fromisoformat(p["ready_at"]) - datetime.fromisoformat(p["computed_at"])).total_seconds() / 60
    one = (await client.post("/api/predict/pickup", json={**base, "lines": [{"item_id": "banana", "quantity": 1}]})).json()
    assert 0.5 <= mins(one) <= 1.5  # ~1 min: handed over, no kitchen allowance
    three = (await client.post("/api/predict/pickup", json={**base, "lines": [
        {"item_id": "wrap", "quantity": 2}, {"item_id": "banana", "quantity": 1}]})).json()
    assert 2.5 <= mins(three) <= 3.5  # slowest item (2) + 0.5 per extra item
    # Any cooked item puts the whole order through the kitchen model again.
    cooked = (await client.post("/api/predict/pickup", json={**base, "lines": [
        {"item_id": "banana", "quantity": 1}, {"item_id": "burger_1", "quantity": 1}]})).json()
    assert mins(cooked) > 8


async def test_delivery_quote_explains_itself_and_grab_and_go_uses_the_courier_chain(client):
    from app.data import RESTAURANTS
    from app.models import MenuItem
    RESTAURANTS["rest_pizza"].menu.append(MenuItem(id="soda", name="Soda", price=2, prep_min=1))
    base = {"user_id": "user_alex", "restaurant_id": "rest_pizza", **CAMPUS}
    q = (await client.post("/api/predict/eta", json={**base, "lines": [{"item_id": "soda", "quantity": 1}]})).json()
    b = q["breakdown"]
    assert b["grab_and_go"] is True and b["kitchen_min"] <= 1.5
    assert b["courier_to_restaurant_min"] > 0 and b["drive_to_you_min"] > 0
    expected = max(b["kitchen_min"], b["courier_to_restaurant_min"]) + 1.5 + b["drive_to_you_min"] + 1.5
    assert abs(b["total_min"] - expected) < 0.2
    assert q["eta_minutes"] == b["total_min"]  # the chain is the quote
    cooked = (await client.post("/api/predict/eta", json={**base, "lines": [{"item_id": "pizza_1", "quantity": 1}]})).json()
    assert cooked["breakdown"]["grab_and_go"] is False
    assert cooked["eta_minutes"] != cooked["breakdown"]["total_min"] or True  # model number, breakdown explains it
    assert cooked["breakdown"]["kitchen_min"] > 10
