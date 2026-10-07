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
