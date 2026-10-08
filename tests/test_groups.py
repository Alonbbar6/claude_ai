"""Restaurant groups: chains / multi-location owners."""

from datetime import datetime

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app, build_services

GROUP = "grp_napoli"


@pytest.fixture
async def client():
    (
        app.state.predictor, app.state.bus, app.state.ws_channel,
        app.state.notifications, app.state.orders,
    ) = build_services(stage_seconds=3600, failure_rate=0.0, seed=0)
    app.state.notifications.clock = lambda: datetime(2026, 1, 1, 12, 0)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c
    await app.state.orders.shutdown()


async def test_seeded_chain_has_two_locations(client):
    groups = (await client.get("/api/groups")).json()
    napoli = next(g for g in groups if g["id"] == GROUP)
    assert napoli["name"] == "Napoli Pizza Group" and napoli["location_count"] == 2
    assert {r["id"] for r in napoli["restaurants"]} == {"rest_pizza", "rest_pizza_wynwood"}

    members = (await client.get("/api/restaurants", params={"group_id": GROUP})).json()
    assert {r["id"] for r in members} == {"rest_pizza", "rest_pizza_wynwood"}
    assert all(r["group"] == "Napoli Pizza Group" for r in members)
    sushi = next(r for r in (await client.get("/api/restaurants")).json() if r["id"] == "rest_sushi")
    assert sushi["group_id"] is None and sushi["group"] is None


async def test_group_crud_and_membership(client):
    r = await client.post("/api/groups", json={"name": "Brickell Hospitality", "owner": "Ana Lima"})
    assert r.status_code == 201
    gid = r.json()["id"]
    assert r.json()["restaurants"] == []

    r = await client.post(f"/api/groups/{gid}/restaurants", json={"restaurant_id": "rest_sushi"})
    assert r.status_code == 201 and r.json()["location_count"] == 1
    assert (await client.get("/api/restaurants", params={"group_id": gid})).json()[0]["id"] == "rest_sushi"

    r = await client.put(f"/api/groups/{gid}", json={"name": "Brickell Hospitality Group"})
    assert r.json()["name"] == "Brickell Hospitality Group" and r.json()["owner"] == "Ana Lima"

    # A restaurant is in one group at a time: moving it out of Napoli is explicit.
    assert (await client.delete(f"/api/groups/{gid}/restaurants/rest_pizza")).status_code == 422
    assert (await client.delete(f"/api/groups/{gid}/restaurants/rest_sushi")).status_code == 204
    assert (await client.get(f"/api/groups/{gid}")).json()["location_count"] == 0

    assert (await client.post(f"/api/groups/{gid}/restaurants", json={"restaurant_id": "nope"})).status_code == 404
    assert (await client.get("/api/groups/nope")).status_code == 404

    await client.post(f"/api/groups/{gid}/restaurants", json={"restaurant_id": "rest_sushi"})
    assert (await client.delete(f"/api/groups/{gid}")).status_code == 204
    sushi = next(r for r in (await client.get("/api/restaurants")).json() if r["id"] == "rest_sushi")
    assert sushi["group_id"] is None  # deleting a group never deletes restaurants


async def test_group_inventory_merges_locations_and_suggests_transfer(client):
    inv = (await client.get(f"/api/groups/{GROUP}/inventory")).json()
    assert inv["summary"]["locations"] == 2
    pep = next(i for i in inv["ingredients"] if i["name"] == "Pepperoni")
    assert {l["restaurant_id"] for l in pep["locations"]} == {"rest_pizza", "rest_pizza_wynwood"}
    assert pep["total_on_hand"] == 2.55 and pep["status"] == "low"      # worst location wins
    t = pep["transfer"]
    assert t["from_restaurant_id"] == "rest_pizza_wynwood" and t["to_restaurant_id"] == "rest_pizza"
    assert t["quantity"] == 0.4 and t["unit"] == "kg" and "above its par" in t["reason"]
    assert inv["summary"]["transfers"] >= 1
    # Downtown-only ingredient still appears, with one location and no transfer.
    garlic = next(i for i in inv["ingredients"] if i["name"] == "Garlic butter")
    assert len(garlic["locations"]) == 1 and garlic["transfer"] is None
    assert inv["ingredients"][0]["status"] != "ok"  # problems sort first


async def test_group_orders_sales_and_alerts(client):
    order = {"user_id": "user_alex", "restaurant_id": "rest_pizza",
             "lines": [{"item_id": "pizza_1", "quantity": 1}, {"item_id": "pizza_3", "quantity": 2}]}
    assert (await client.post("/api/orders", json=order)).status_code == 201
    other = {"user_id": "user_alex", "restaurant_id": "rest_sushi", "lines": [{"item_id": "sushi_3", "quantity": 1}]}
    assert (await client.post("/api/orders", json=other)).status_code == 201

    orders = (await client.get(f"/api/groups/{GROUP}/orders")).json()
    assert len(orders) == 1 and orders[0]["restaurant"] == "Napoli Pizza"
    assert len((await client.get(f"/api/groups/{GROUP}/orders", params={"open_only": True})).json()) == 1

    sales = (await client.get(f"/api/groups/{GROUP}/sales")).json()
    downtown = next(l for l in sales["locations"] if l["restaurant_id"] == "rest_pizza")
    assert downtown["orders"] == 1 and downtown["revenue"] == 13.0 + 2 * 6.5
    assert sales["totals"]["orders"] == 1 and sales["totals"]["revenue"] == 26.0

    alerts = (await client.get(f"/api/groups/{GROUP}/alerts")).json()
    assert all(a["restaurant"] in {"Napoli Pizza", "Napoli Pizza Wynwood"} for a in alerts)
