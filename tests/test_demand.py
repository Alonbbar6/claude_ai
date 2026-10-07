"""Demand by time of day: meal periods, item lift, suggestions and the API."""

from datetime import datetime, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient

from app.data import RESTAURANTS
from app.demand import OrderRecord, analyze, period_of, simulate_history
from app.main import app, build_services

NOW = datetime(2026, 10, 7, 16, 0, tzinfo=timezone.utc)  # 12 PM in Miami (EDT, UTC-4)


def local(day: int, hour: int, minute: int = 0) -> datetime:
    """A time ``day`` days before NOW at the given Miami (EDT) hour, in UTC."""
    return datetime(2026, 10, 7, hour, minute, tzinfo=timezone.utc) + timedelta(days=-day, hours=4)


@pytest.mark.parametrize("hour,minute,key", [
    (5, 59, "late_night"), (6, 0, "breakfast"), (10, 59, "breakfast"), (11, 0, "lunch"),
    (15, 0, "afternoon"), (17, 0, "dinner"), (21, 59, "dinner"), (22, 0, "late_night"), (0, 30, "late_night"),
])
def test_periods_use_restaurant_local_time(hour, minute, key):
    assert period_of(local(1, hour, minute)).key == key


def rec(rid, at, **items):
    return OrderRecord(rid, at, items, total=10.0 * sum(items.values()))


def test_counts_lift_and_feature_suggestion():
    grill = RESTAURANTS["rest_burger"]
    records = []
    for d in range(1, 29):
        records += [rec("rest_burger", local(d, 15, 30), burger_3=2, burger_2=1),  # afternoon: shakes
                    rec("rest_burger", local(d, 19), burger_1=2, burger_2=1),
                    rec("rest_burger", local(d, 20), burger_1=1)]
    r = analyze(grill, records, now=NOW, days=28)

    assert r.total_orders == 84 and r.peak_period == "dinner"
    afternoon = next(p for p in r.periods if p.key == "afternoon")
    assert afternoon.orders == 28 and afternoon.orders_per_day == 1.0
    shake = afternoon.top_items[0]
    assert shake.name == "Milkshake" and shake.share == pytest.approx(2 / 3, abs=1e-3)
    # 56 of 196 items all day; 2/3 in the afternoon -> lift ~2.33
    assert shake.lift == pytest.approx((2 / 3) / (56 / 196), abs=0.01)

    kinds = {(s.kind, s.period) for s in r.suggestions}
    assert ("peak", "dinner") in kinds
    assert ("feature", "afternoon") in kinds
    feat = next(s for s in r.suggestions if s.kind == "feature" and s.period == "afternoon")
    assert feat.item_ids == ["burger_3"] and "in the afternoon" in feat.title


def test_thin_periods_get_no_feature_suggestion():
    grill = RESTAURANTS["rest_burger"]
    records = [rec("rest_burger", local(d, 19), burger_1=1) for d in range(1, 29)]
    records += [rec("rest_burger", local(d, 8), burger_3=3) for d in range(1, 6)]  # 5 breakfasts in 28 days
    r = analyze(grill, records, now=NOW, days=28)
    assert not any(s.kind == "feature" and s.period == "breakfast" for s in r.suggestions)


def test_add_item_when_others_get_demand_you_dont():
    sushi = RESTAURANTS["rest_sushi"]
    records = []
    for d in range(1, 28):  # 28 days back at 8 AM is just outside the window
        records += [rec("rest_burger", local(d, 8), burger_1=1),  # others: breakfast is busy
                    rec("rest_burger", local(d, 19), burger_1=1),
                    rec("rest_sushi", local(d, 19), sushi_1=1)]
    r = analyze(sushi, records, now=NOW, days=28)
    add = [s for s in r.suggestions if s.kind == "add_item"]
    assert [s.period for s in add] == ["breakfast"]
    assert "Onigiri rice balls" in add[0].ideas
    breakfast = next(p for p in r.periods if p.key == "breakfast")
    assert breakfast.share_of_orders == 0 and breakfast.others_share_of_orders == 0.5


def test_window_excludes_old_orders():
    grill = RESTAURANTS["rest_burger"]
    records = [rec("rest_burger", local(3, 19), burger_1=1), rec("rest_burger", local(40, 19), burger_1=1)]
    assert analyze(grill, records, now=NOW, days=28).total_orders == 1


def test_simulated_history_is_deterministic_and_marked():
    a = simulate_history(RESTAURANTS, now=NOW, days=7)
    b = simulate_history(RESTAURANTS, now=NOW, days=7)
    assert a and [(r.restaurant_id, r.at, r.items) for r in a] == [(r.restaurant_id, r.at, r.items) for r in b]
    assert all(r.simulated and r.at < NOW for r in a)


# ---- API ---------------------------------------------------------------------

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


async def test_demand_api_counts_live_orders(client):
    live_only = (await client.get(M + "/demand", params={"include_simulated": "false"})).json()
    assert live_only["total_orders"] == 0 and live_only["suggestions"] == []

    order = {"user_id": "user_sam", "restaurant_id": "rest_burger",
             "lines": [{"item_id": "burger_3", "quantity": 2}]}
    assert (await client.post("/api/orders", json=order)).status_code == 201
    cancelled = (await client.post("/api/orders", json=order)).json()
    await client.post(f"/api/orders/{cancelled['id']}/cancel")

    live_only = (await client.get(M + "/demand", params={"include_simulated": "false"})).json()
    assert live_only["sources"] == {"live_orders": 1, "simulated_orders": 0}
    assert live_only["total_orders"] == 1
    assert sum(p["revenue"] for p in live_only["periods"]) == 11.0

    full = (await client.get(M + "/demand")).json()
    assert full["sources"]["live_orders"] == 1 and full["sources"]["simulated_orders"] > 500
    assert [p["key"] for p in full["periods"]] == ["breakfast", "lunch", "afternoon", "dinner", "late_night"]
    assert full["suggestions"]


async def test_demand_api_validates(client):
    assert (await client.get("/api/merchant/restaurants/nope/demand")).status_code == 404
    assert (await client.get(M + "/demand", params={"days": 0})).status_code == 422


# ---- QA fixture: MDC Wolfson ------------------------------------------------------

async def test_qa_wolfson_seed_shapes_a_campus_day(client):
    from app import qa

    n = qa.seed(app.state.orders)
    assert n > 200
    rid = qa.QA_RESTAURANT_ID
    assert any(r["id"] == rid for r in (await client.get("/api/restaurants")).json())

    report = (await client.get(f"/api/merchant/restaurants/{rid}/demand")).json()
    assert report["sources"] == {"live_orders": n, "simulated_orders": 0}
    by = {p["key"]: p for p in report["periods"]}
    assert report["peak_period"] == "lunch"
    assert by["late_night"]["orders"] == 0
    assert by["breakfast"]["top_items"][0]["name"] in {"Café con leche", "Guava pastelito", "Cafecito"}
    assert by["afternoon"]["top_items"][0]["name"] == "Iced coffee"

    # A live pickup order from the QA student, on foot.
    order = (await client.post("/api/orders", json={
        "user_id": qa.QA_USER_ID, "restaurant_id": rid, "fulfillment": "pickup",
        "pickup_mode": "walking", "lines": [{"item_id": "qa_cafecito", "quantity": 1}],
    })).json()
    assert order["pickup"]["mode"] == "walking" and order["pickup"]["decision"] in {"wait", "leave_now"}
