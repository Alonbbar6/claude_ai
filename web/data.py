"""Synthetic data for the demo: a fictional Italian restaurant, its menu and
recipes, the simulated sales channels, and a two-month order history.

Ingredient and menu IDs match the BarMade API (barmade-api.onrender.com) so
the two can be wired together later. All values are made up for the demo.
"""

from __future__ import annotations

import random
from datetime import date, datetime, time, timedelta

RESTAURANT = {
    "name": "Trattoria Nonna Rosa",
    "tagline": "Fictional Italian restaurant · demo data",
    "timezone": "America/New_York",
    "day_cutoff": "Business day ends when the manager presses Close Day (demo convention).",
}

# id, name, category, unit, par (restock-to), low threshold, typical daily usage
INGREDIENTS = [
    ("ING-001", "Tomato Sauce", "Sauces", "ml", 32000, 7000, 4850),
    ("ING-002", "Mozzarella Cheese", "Dairy", "g", 18000, 4000, 2700),
    ("ING-003", "Pizza Dough", "Dough & Pasta", "units", 120, 30, 18),
    ("ING-004", "Pepperoni", "Meats", "slices", 1800, 400, 270),
    ("ING-005", "Pasta (Spaghetti)", "Dough & Pasta", "g", 12000, 2500, 1725),
    ("ING-006", "Alfredo Sauce", "Sauces", "ml", 9000, 2000, 1300),
    ("ING-007", "Parmesan Cheese", "Dairy", "g", 1200, 300, 180),
    ("ING-008", "Olive Oil", "Pantry", "ml", 1200, 300, 165),
    ("ING-009", "Chicken", "Meats", "g", 8000, 1800, 1170),
    ("ING-010", "Garlic", "Produce", "g", 450, 100, 62),
    ("ING-011", "Basil", "Produce", "g", 400, 100, 60),
    ("ING-012", "Coca-Cola Cans", "Beverages", "cans", 48, 12, 7),
]

# id, name, price, description, recipe {ingredient: quantity per serving}
MENU = [
    ("MENU-001", "Margherita Pizza", 15.99, "Tomato, mozzarella, fresh basil",
     {"ING-003": 1, "ING-001": 200, "ING-002": 150, "ING-011": 5, "ING-008": 10}),
    ("MENU-002", "Pepperoni Pizza", 17.99, "Tomato, mozzarella, pepperoni",
     {"ING-003": 1, "ING-001": 200, "ING-002": 150, "ING-004": 30}),
    ("MENU-003", "Chicken Alfredo", 21.99, "Spaghetti, alfredo sauce, grilled chicken",
     {"ING-005": 150, "ING-006": 200, "ING-009": 180, "ING-007": 20, "ING-010": 5}),
    ("MENU-004", "Spaghetti Marinara", 16.99, "Spaghetti, tomato sauce, garlic, basil",
     {"ING-005": 150, "ING-001": 250, "ING-010": 6, "ING-011": 3, "ING-008": 15, "ING-007": 10}),
    ("MENU-005", "Coca-Cola", 2.99, "12 oz can", {"ING-012": 1}),
]

# Simulated sales channels. Nothing here talks to a real platform.
CHANNELS = [
    {"id": "dine_in", "label": "Dine-in", "icon": "🍽️"},
    {"id": "takeout", "label": "Takeout", "icon": "🥡"},
    {"id": "barmade", "label": "Barmade", "icon": "🟢"},
    {"id": "uber_eats", "label": "Uber Eats", "icon": "🚗"},
    {"id": "doordash", "label": "DoorDash", "icon": "🛵"},
    {"id": "web", "label": "Website (direct)", "icon": "🌐",
     "note": "Open question in the PRD — included until the team confirms"},
]
CHANNELS_BY_ID = {c["id"]: c for c in CHANNELS}


def _slug(name: str) -> str:
    return "".join(ch if ch.isalnum() else "_" for ch in name.lower()).strip("_")


# How each channel refers to a dish. Normalization maps these back to MENU ids.
CHANNEL_ITEMS: dict[str, dict[str, str]] = {
    "dine_in": {name: mid for mid, name, *_ in MENU},
    "takeout": {name: mid for mid, name, *_ in MENU},
    "barmade": {mid: mid for mid, *_ in MENU},
    "web": {mid: mid for mid, *_ in MENU},
    "uber_eats": {"UE-" + mid[-3:]: mid for mid, *_ in MENU},
    "doordash": {"dd_" + _slug(name): mid for mid, name, *_ in MENU},
}
_NAME = {mid: name for mid, name, *_ in MENU}


def to_channel_payload(channel: str, lines: list[tuple[str, int]], customer: str | None, rng: random.Random | None = None) -> dict:
    """What the simulated channel would send us for this order."""
    rng = rng or random
    if channel == "dine_in":
        return {"source": "POS terminal (simulated)", "table": rng.randint(1, 12),
                "ticket": [{"dish": _NAME[m], "qty": q} for m, q in lines]}
    if channel == "takeout":
        return {"source": "Phone order (simulated)", "pickup_name": customer or "Walk-in",
                "items": [{"dish": _NAME[m], "qty": q} for m, q in lines]}
    if channel == "barmade":
        return {"source": "Barmade app (simulated)", "customer": customer,
                "items": [{"menuItemId": m, "quantity": q} for m, q in lines]}
    if channel == "uber_eats":
        return {"source": "Uber Eats webhook (simulated)", "eater": customer,
                "cart": [{"external_id": "UE-" + m[-3:], "title": _NAME[m].upper(), "quantity": q} for m, q in lines]}
    if channel == "doordash":
        return {"source": "DoorDash webhook (simulated)", "consumer": customer,
                "line_items": [{"merchant_supplied_id": "dd_" + _slug(_NAME[m]), "name": _NAME[m], "quantity": q} for m, q in lines]}
    if channel == "web":
        return {"source": "Website checkout (simulated)", "customer": customer,
                "items": [{"sku": m, "qty": q} for m, q in lines]}
    raise KeyError(channel)


def normalize(channel: str, payload: dict) -> list[tuple[str, int]]:
    """Channel payload -> canonical (menu_item_id, quantity) lines.

    Raises KeyError for an item the channel map doesn't know.
    """
    table = CHANNEL_ITEMS[channel]
    if channel == "dine_in":
        raw = [(r["dish"], r["qty"]) for r in payload["ticket"]]
    elif channel == "takeout":
        raw = [(r["dish"], r["qty"]) for r in payload["items"]]
    elif channel == "barmade":
        raw = [(r["menuItemId"], r["quantity"]) for r in payload["items"]]
    elif channel == "uber_eats":
        raw = [(r["external_id"], r["quantity"]) for r in payload["cart"]]
    elif channel == "doordash":
        raw = [(r["merchant_supplied_id"], r["quantity"]) for r in payload["line_items"]]
    elif channel == "web":
        raw = [(r["sku"], r["qty"]) for r in payload["items"]]
    else:
        raise KeyError(channel)
    merged: dict[str, int] = {}
    for key, qty in raw:
        merged[table[key]] = merged.get(table[key], 0) + int(qty)
    return list(merged.items())


# ---- two-month history --------------------------------------------------------

_VOLUME = {0: 9, 1: 9, 2: 10, 3: 11, 4: 16, 5: 18, 6: 12}        # orders by weekday
_ITEM_WEIGHTS = {"MENU-001": 25, "MENU-002": 25, "MENU-003": 18, "MENU-004": 14, "MENU-005": 18}
_CHANNEL_WEIGHTS = {"dine_in": 30, "takeout": 15, "barmade": 20, "uber_eats": 18, "doordash": 12, "web": 5}
_NAMES = ["Maria", "Luca", "Sofia", "Marco", "Giulia", "Andrea", "Elena", "Paolo", "Chiara", "Diego"]
DELIVERY_DAYS = (0, 3)   # Monday and Thursday standing order


def seed_history(store, days: int = 60, seed: int = 7) -> None:
    """Replay `days` of synthetic trading up to and including this morning,
    then stage today's demo conditions as ordinary, traceable events."""
    rng = random.Random(seed)
    real_clock = store.clock
    today = real_clock().date()
    start = today - timedelta(days=days)
    sim = [datetime.combine(start, time(6, 0))]
    store.clock = lambda: sim[0]

    for ing in store.ingredients.values():
        ing.on_hand = 0
        store.receive(ing.id, ing.par, "Opening stock (demo baseline)")
        ing.last_counted_at = sim[0]

    for d in range(days + 1):
        day = start + timedelta(days=d)
        sim[0] = datetime.combine(day, time(7, 0))
        if day.weekday() in DELIVERY_DAYS:
            for ing in store.ingredients.values():
                short = ing.par - ing.on_hand
                if short > 0:
                    store.receive(ing.id, short, "Standing order — Bella Foods (simulated supplier)")
        n = _VOLUME[day.weekday()] + rng.randint(-2, 3)
        if day == today:
            n = 3   # a quiet morning; the classroom provides the rest
        times = sorted(rng.randint(0, 630) for _ in range(n))   # minutes after 11:00
        for m in times:
            sim[0] = datetime.combine(day, time(11, 0)) + timedelta(minutes=m)
            if day == today and sim[0] > real_clock():
                break
            channel = rng.choices(list(_CHANNEL_WEIGHTS), weights=list(_CHANNEL_WEIGHTS.values()))[0]
            k = rng.choice([1, 1, 2, 2, 3])
            picks = rng.sample(list(_ITEM_WEIGHTS), k=k, counts=list(_ITEM_WEIGHTS.values()))
            lines = [(mid, rng.choice([1, 1, 1, 2])) for mid in dict.fromkeys(picks)]
            try:
                store.place_order(channel, lines, customer=rng.choice(_NAMES), rng=rng)
            except Exception:
                continue   # estimated stock-out in history: the sale is simply lost
        if day != today:
            sim[0] = datetime.combine(day, time(22, 0))
            if day.weekday() == 6:   # Sunday count: small, plausible discrepancies
                counts = {ing.id: round(ing.on_hand * (1 + rng.uniform(-0.03, 0.02)), 0)
                          for ing in store.ingredients.values()}
                store.confirm_count(counts, "Weekly count (simulated)")
            store.close_day()

    # Today's demo conditions, recorded as normal events so they're traceable.
    sim[0] = datetime.combine(today, time(9, 30))
    moz = store.ingredients["ING-002"]
    target = moz.low_threshold + 3 * 150          # three pizzas above the alert line
    if moz.on_hand > target:
        store.waste("ING-002", moz.on_hand - target,
                    "Walk-in fridge left open overnight — mozzarella discarded (manager note)")
    sim[0] = datetime.combine(today, time(9, 45))
    chicken = store.ingredients["ING-009"]
    double = chicken.par * 2 - chicken.on_hand
    if double > 0:
        store.receive("ING-009", double, "Bella Foods invoice #4471 — supplier shipped double the standing order")
    store.clock = real_clock
