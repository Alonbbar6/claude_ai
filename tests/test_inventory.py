from datetime import datetime, timedelta, timezone

import pytest

from app.inventory import InventoryService, OutOfStock
from app.models import Ingredient, MenuItem, Order, OrderLine, Restaurant, Route

NOW = datetime(2026, 3, 4, 15, 0, tzinfo=timezone.utc)


@pytest.fixture
def setup():
    r = Restaurant(
        id="r", name="R", cuisine="x", lat=0, lng=0, avg_prep_min=10,
        menu=[
            MenuItem(id="burger", name="Burger", price=10, recipe={"bun": 1, "patty": 1}),
            MenuItem(id="fries", name="Fries", price=4, recipe={"potato": 0.25}),
        ],
    )
    ings = [
        Ingredient(id="bun", restaurant_id="r", name="Buns", unit="each", on_hand=10, low_threshold=3, par=20, daily_usage=24),
        Ingredient(id="patty", restaurant_id="r", name="Patties", unit="each", on_hand=4, low_threshold=3, par=20, daily_usage=24),
        Ingredient(id="potato", restaurant_id="r", name="Potatoes", unit="kg", on_hand=1, low_threshold=0.5, par=5, daily_usage=2.4),
    ]
    clock = {"now": NOW}
    inv = InventoryService({"r": r}, ings, clock=lambda: clock["now"])
    return inv, r, clock


def order(lines):
    return Order(user_id="u", restaurant_id="r", lines=[OrderLine(item_id=i, quantity=q) for i, q in lines],
                 route=Route(distance_km=1, duration_min=3, source="t"))


def test_order_consumes_and_cancel_releases(setup):
    inv, r, _ = setup
    o = order([("burger", 2), ("fries", 2)])
    inv.check("r", o.lines)
    inv.consume(o)
    assert inv.ingredients["bun"].on_hand == 8
    assert inv.ingredients["patty"].on_hand == 2
    assert inv.ingredients["potato"].on_hand == 0.5
    inv.release(o)
    assert inv.ingredients["patty"].on_hand == 4
    assert [a.reason for a in inv.history("patty")] == ["cancel", "order"]


def test_running_out_marks_item_sold_out_and_restock_brings_it_back(setup):
    inv, r, _ = setup
    burger = r.menu[0]
    inv.consume(order([("burger", 4)]))
    assert burger.sold_out and not burger.orderable
    assert not r.menu[1].sold_out  # fries unaffected
    with pytest.raises(OutOfStock, match="patties"):
        inv.check("r", [OrderLine(item_id="burger", quantity=1)])
    inv.restock("r", "patty", 10)
    assert not burger.sold_out


def test_check_rejects_quantity_beyond_stock_and_unavailable_items(setup):
    inv, r, _ = setup
    with pytest.raises(OutOfStock):
        inv.check("r", [OrderLine(item_id="burger", quantity=5)])  # only 4 patties
    inv.check("r", [OrderLine(item_id="burger", quantity=4)])
    r.menu[1].available = False
    with pytest.raises(OutOfStock, match="unavailable"):
        inv.check("r", [OrderLine(item_id="fries", quantity=1)])


def test_alerts_fire_once_when_crossing_low_and_out(setup):
    inv, _, _ = setup
    inv.consume(order([("burger", 1)]))  # patties 4 -> 3: crosses low
    inv.consume(order([("burger", 1)]))  # 3 -> 2: already low, no new alert
    kinds = [(a.ingredient_id, a.kind) for a in inv.alerts]
    assert kinds == [("patty", "low")]
    assert "used in Burger" in inv.alerts[0].message
    inv.consume(order([("burger", 2)]))  # -> 0
    assert [a.kind for a in inv.alerts_for("r")][0] == "out"


def test_waste_count_and_validation(setup):
    inv, _, _ = setup
    inv.waste("r", "bun", 2, "dropped")
    assert inv.ingredients["bun"].on_hand == 8
    with pytest.raises(ValueError):
        inv.waste("r", "bun", 99)
    inv.count("r", "bun", 12.0, "stock-take")
    adj = inv.history("bun")[0]
    assert adj.reason == "count" and adj.delta == 4 and adj.on_hand_after == 12
    with pytest.raises(KeyError):
        inv.restock("other", "bun", 1)  # wrong restaurant


def test_forecast_uses_baseline_then_speeds_up_with_rush(setup):
    inv, _, clock = setup
    bun = inv.ingredients["bun"]
    v = inv.view(bun)
    assert v["usage_per_hour"] == 1.0  # 24/day
    assert v["hours_left"] == 10.0
    assert v["reorder_qty"] == 10 and v["portions_left"] == 10
    assert v["used_by"] == ["Burger"]

    # A rush: 4 burgers in the last hour beats the 1/h baseline.
    inv.restock("r", "patty", 10)
    inv.consume(order([("burger", 4)]))
    v = inv.view(bun)
    assert v["usage_per_hour"] == 4.0 and v["hours_left"] == 1.5

    # An hour later the rush no longer counts.
    clock["now"] = NOW + timedelta(hours=2)
    assert inv.view(bun)["usage_per_hour"] == 1.0


def test_status_order_puts_problems_first(setup):
    inv, _, _ = setup
    inv.consume(order([("fries", 4)]))  # potatoes -> 0
    names = [v["id"] for v in inv.views("r")]
    assert names[0] == "potato"
    assert inv.view(inv.ingredients["potato"])["status"] == "out"


def test_deleting_ingredient_removes_it_from_recipes(setup):
    inv, r, _ = setup
    inv.consume(order([("burger", 4)]))
    assert r.menu[0].sold_out
    inv.delete("r", "patty")
    assert r.menu[0].recipe == {"bun": 1}
    assert not r.menu[0].sold_out
