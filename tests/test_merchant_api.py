"""Restaurant-side API: menu catalog and inventory, and how they affect ordering."""

from datetime import datetime

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app, build_services

M = "/api/merchant/restaurants/rest_burger"


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


def burger_order(qty=1, item="burger_1"):
    return {"user_id": "user_sam", "restaurant_id": "rest_burger", "lines": [{"item_id": item, "quantity": qty}]}


async def inventory(client):
    return {i["id"]: i for i in (await client.get(M + "/inventory")).json()}


async def test_menu_has_categories_and_customers_dont_see_recipes(client):
    menu = (await client.get(M + "/menu")).json()
    assert [c["name"] for c in menu["categories"]] == ["Burgers", "Sides", "Drinks"]
    assert menu["items"][0]["recipe"] == [
        {"ingredient_id": "ing_bun", "quantity": 1}, {"ingredient_id": "ing_patty", "quantity": 1}]

    customer = (await client.get("/api/restaurants")).json()
    grill = next(r for r in customer if r["id"] == "rest_burger")
    assert "recipe" not in grill["menu"][0]
    assert grill["menu"][0]["category_id"] == "cat_grill_burgers"
    assert grill["categories"][0]["name"] == "Burgers"


async def test_category_crud_and_reorder(client):
    cat = (await client.post(M + "/categories", json={"name": "Desserts"})).json()
    assert cat["sort"] == 3
    r = await client.put(M + f"/categories/{cat['id']}", json={"name": "Sweets"})
    assert r.json()["name"] == "Sweets"

    ids = [c["id"] for c in (await client.get(M + "/menu")).json()["categories"]]
    new_order = [ids[-1], *ids[:-1]]
    ordered = (await client.post(M + "/categories/reorder", json={"ids": new_order})).json()
    assert [c["id"] for c in ordered] == new_order
    assert (await client.post(M + "/categories/reorder", json={"ids": ids[:2]})).status_code == 422

    # Deleting a category keeps its items, uncategorised.
    assert (await client.delete(M + "/categories/cat_grill_drinks")).status_code == 204
    shake = next(i for i in (await client.get(M + "/menu")).json()["items"] if i["id"] == "burger_3")
    assert shake["category_id"] is None


async def test_item_crud_shows_up_for_customers(client):
    body = {"name": "Cheeseburger", "price": 11.99, "description": "With cheddar",
            "category_id": "cat_grill_burgers",
            # Wire format is a list of entries; ids stay values, not keys.
            "recipe": [{"ingredient_id": "ing_bun", "quantity": 1}, {"ingredient_id": "ing_patty", "quantity": 1}]}
    item = (await client.post(M + "/items", json=body)).json()
    assert item["id"].startswith("item_") and item["price"] == 11.99

    order = await client.post("/api/orders", json=burger_order(1, item["id"]))
    assert order.status_code == 201

    upd = (await client.put(M + f"/items/{item['id']}", json={"price": 12.5, "available": False})).json()
    assert upd["price"] == 12.5 and upd["available"] is False and upd["name"] == "Cheeseburger"
    r = await client.post("/api/orders", json=burger_order(1, item["id"]))
    assert r.status_code == 409 and "unavailable" in r.json()["detail"]

    assert (await client.delete(M + f"/items/{item['id']}")).status_code == 204
    assert (await client.put(M + f"/items/{item['id']}", json={"price": 1})).status_code == 404


async def test_item_validation(client):
    bad = [
        {"name": "", "price": 5},
        {"name": "X", "price": 0},
        {"name": "X", "price": 5, "category_id": "nope"},
        {"name": "X", "price": 5, "recipe": {"ing_rice": 1}},  # another restaurant's ingredient
        {"name": "X", "price": 5, "recipe": {"ing_bun": -1}},
    ]
    for body in bad:
        assert (await client.post(M + "/items", json=body)).status_code == 422, body


async def test_orders_deduct_stock_and_sell_out(client):
    # Seed: 14 patties.
    assert (await inventory(client))["ing_patty"]["on_hand"] == 14
    assert (await client.post("/api/orders", json=burger_order(10))).status_code == 201
    inv = await inventory(client)
    assert inv["ing_patty"]["on_hand"] == 4 and inv["ing_bun"]["on_hand"] == 50

    r = await client.post("/api/orders", json=burger_order(5))
    assert r.status_code == 409 and "beef patties" in r.json()["detail"]

    oid = (await client.post("/api/orders", json=burger_order(4))).json()["id"]
    inv = await inventory(client)
    assert inv["ing_patty"]["status"] == "out"
    grill = next(r for r in (await client.get("/api/restaurants")).json() if r["id"] == "rest_burger")
    assert next(m for m in grill["menu"] if m["id"] == "burger_1")["sold_out"] is True

    alerts = (await client.get(M + "/alerts")).json()
    assert alerts[0]["kind"] == "out" and "Beef patties" in alerts[0]["message"]

    # Cancelling returns stock and the burger is back on the menu.
    await client.post(f"/api/orders/{oid}/cancel")
    grill = next(r for r in (await client.get("/api/restaurants")).json() if r["id"] == "rest_burger")
    assert next(m for m in grill["menu"] if m["id"] == "burger_1")["sold_out"] is False


async def test_restock_waste_count_and_history(client):
    r = await client.post(M + "/inventory/ing_patty/adjust", json={"kind": "restock", "quantity": 66, "note": "Sysco"})
    assert r.json()["on_hand"] == 80 and r.json()["status"] == "ok" and r.json()["reorder_qty"] == 0
    await client.post(M + "/inventory/ing_patty/adjust", json={"kind": "waste", "quantity": 2})
    r = await client.post(M + "/inventory/ing_patty/adjust", json={"kind": "count", "quantity": 75})
    assert r.json()["on_hand"] == 75
    assert (await client.post(M + "/inventory/ing_patty/adjust", json={"kind": "waste", "quantity": 999})).status_code == 422
    assert (await client.post(M + "/inventory/ing_rice/adjust", json={"kind": "restock", "quantity": 1})).status_code == 404

    hist = (await client.get(M + "/inventory/ing_patty/history")).json()
    assert [h["reason"] for h in hist] == ["count", "waste", "restock"]
    assert hist[2]["note"] == "Sysco"


async def test_ingredient_crud_and_forecast_fields(client):
    ing = (await client.post(M + "/inventory", json={
        "name": "Cheddar", "unit": "kg", "on_hand": 2, "low_threshold": 0.5, "par": 4, "daily_usage": 1.2,
    })).json()
    assert ing["status"] == "ok" and ing["hours_left"] == 40.0 and ing["reorder_qty"] == 2
    assert ing["used_by"] == [] and ing["portions_left"] is None

    upd = (await client.put(M + f"/inventory/{ing['id']}", json={"low_threshold": 3})).json()
    assert upd["status"] == "low"

    # Use it in a recipe, then delete it: the recipe drops it.
    await client.put(M + "/items/burger_1", json={"recipe": {"ing_bun": 1, "ing_patty": 1, ing["id"]: 0.03}})
    assert (await inventory(client))[ing["id"]]["used_by"] == ["Classic Burger"]
    assert (await client.delete(M + f"/inventory/{ing['id']}")).status_code == 204
    burger = next(i for i in (await client.get(M + "/menu")).json()["items"] if i["id"] == "burger_1")
    assert ing["id"] not in [e["ingredient_id"] for e in burger["recipe"]]


async def test_inventory_sorted_problems_first(client):
    inv = (await client.get(M + "/inventory")).json()
    assert inv[0]["id"] == "ing_patty" and inv[0]["status"] == "low"  # seeded below threshold
    assert (await client.get("/api/merchant/restaurants/nope/inventory")).status_code == 404
