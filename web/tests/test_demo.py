"""Acceptance checks for the PRD's functional requirements (FR-1 .. FR-10)."""

from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from web import app as app_module
from web.data import normalize, to_channel_payload
from web.engine import OrderError, Store
from web.summary import fallback_summary, grounding_check


@pytest.fixture
def store():
    return Store()


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("BARMADE_SUMMARY_AI", "off")
    app_module.app.state.store = Store()
    return TestClient(app_module.app)


def test_seed_gives_two_months_of_context(store):
    assert len(store.closed_days) == 60
    assert len(store.orders) > 500
    assert all(store.status(i) == "ok" for i in store.ingredients.values())   # clean slate for the class
    assert [s["ingredient"] for s in store.overstock_specials()] == ["Chicken"]


def test_fr3_channels_normalize_to_the_same_dish():
    lines = [("MENU-001", 2), ("MENU-005", 1)]
    for channel in ["dine_in", "takeout", "barmade", "uber_eats", "doordash", "web"]:
        payload = to_channel_payload(channel, lines, "Ana")
        assert "simulated" in payload["source"]
        assert normalize(channel, payload) == lines


def test_fr4_order_depletes_by_recipe_deterministically(store):
    moz, dough = store.ingredients["ING-002"], store.ingredients["ING-003"]
    m0, d0 = moz.on_hand, dough.on_hand
    o = store.place_order("uber_eats", [("MENU-001", 2)])
    assert moz.on_hand == m0 - 300 and dough.on_hand == d0 - 2
    evs = [e for e in store.events if e.order_id == o.id]
    assert {e.ingredient_id for e in evs} == {"ING-003", "ING-001", "ING-002", "ING-011", "ING-008"}
    assert all(e.type == "sale" and e.after == e.before + e.delta for e in evs)


def test_fr5_low_stock_alert_fires_with_explanation(store):
    store.place_order("dine_in", [("MENU-001", 2)])
    assert not [a for a in store.alerts if a.status == "active"]
    store.place_order("doordash", [("MENU-002", 1)])         # third pizza crosses the line
    active = [a for a in store.alerts if a.status == "active"]
    assert len(active) == 1 and active[0].kind == "low" and active[0].ingredient_id == "ING-002"
    assert "Margherita Pizza" in active[0].message and "DoorDash" in active[0].message
    store.receive("ING-002", 5000, "Emergency top-up")
    assert active[0].status == "resolved"


def test_fr6_servings_remaining_names_the_constraint(store):
    s = store.servings(store.menu["MENU-001"])
    assert s["constraint"]["ingredient_id"] == "ING-002"
    assert s["servings"] == 29 and "÷" in s["constraint"]["calc"]


def test_order_rejected_when_estimate_cannot_cover_it(store):
    with pytest.raises(OrderError) as e:
        store.place_order("web", [("MENU-001", 40)])
    assert e.value.code == "INSUFFICIENT_ESTIMATED_STOCK"
    assert e.value.details["shortages"][0]["ingredient"] == "Mozzarella Cheese"
    store.menu["MENU-005"].paused = True
    with pytest.raises(OrderError, match="paused"):
        store.place_order("barmade", [("MENU-005", 1)])


def test_fr7_fr10_count_review_does_not_save_confirm_does(store):
    basil = store.ingredients["ING-011"]
    before = basil.on_hand
    review = store.review_count({"ING-011": before - 50})
    assert review["changes"][0]["delta"] == -50 and basil.on_hand == before
    events = store.confirm_count({"ING-011": before - 50}, "Found wilted")
    assert basil.on_hand == before - 50 and events[0].type == "count"


def test_fr8_overstock_special_is_reasoned(store):
    sp = store.overstock_specials()[0]
    assert sp["dish"] == "Chicken Alfredo" and sp["special_price"] == round(21.99 * 0.85, 2)
    assert "days of cover" in sp["reason"] and sp["servings_to_par"] > 0


def test_fr9_summary_is_grounded_in_facts(store):
    store.place_order("takeout", [("MENU-003", 1)])
    facts = store.close_day()
    text = fallback_summary(facts)
    assert text.startswith("### Sales") and "### Tomorrow" in text
    assert grounding_check(text, facts) == []
    assert grounding_check("We sold 999 pizzas", facts) == ["999"]


def test_fr1_fr2_api_order_flow(client):
    r = client.post("/api/orders", json={"channel": "uber_eats", "customer": "Ana",
                                         "lines": [{"menu_item_id": "MENU-002", "quantity": 1}]})
    assert r.status_code == 201
    body = r.json()
    assert body["order"]["channel_label"] == "Uber Eats"
    assert body["order"]["raw_payload"]["cart"][0]["external_id"] == "UE-002"
    assert body["order"]["movements"][0]["delta"] < 0
    trace = client.get(f"/api/orders/{body['order']['id']}").json()
    assert trace["recipes"][0]["dish"] == "Pepperoni Pizza"
    assert client.get("/api/orders").json()[0]["id"] == body["order"]["id"]


def test_api_errors_and_guardrails(client):
    assert client.post("/api/orders", json={"channel": "fax", "lines": []}).status_code == 404
    assert client.post("/api/orders", json={"channel": "web", "lines": []}).status_code == 400
    r = client.post("/api/orders", json={"channel": "web", "lines": [{"menu_item_id": "MENU-001", "quantity": 99}]})
    assert r.status_code == 409 and r.json()["error"]["code"] == "INSUFFICIENT_ESTIMATED_STOCK"
    r = client.post("/api/inventory/count/confirm", json={"counts": {"ING-001": 1}})
    assert r.status_code == 400 and r.json()["error"]["code"] == "CONFIRMATION_REQUIRED"


def test_api_rush_close_day_and_reset(client):
    rush = client.post("/api/simulate-rush", json={"orders": 8, "seed": 1}).json()
    assert len(rush["placed"]) + len(rush["rejected"]) == 8
    day = client.post("/api/close-day").json()
    assert day["summary"]["source"] == "fallback" and day["facts"]["sales"]["orders"] >= len(rush["placed"])
    assert client.get("/api/state").json()["today"]["closed"] is True
    assert client.post("/api/reset").json()["ok"]
    assert client.get("/api/state").json()["today"]["closed"] is False
    assert client.get("/").status_code == 200 and client.get("/order").status_code == 200
