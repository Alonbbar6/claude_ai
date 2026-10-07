"""QA fixture: Miami Dade College, Wolfson Campus as a test restaurant, a QA
student a five-minute walk away, and two weeks of backdated QA orders shaped
like a campus café's day (busy breakfast and lunch, quiet evenings, closed
late at night).

Off by default. Start the server with ``QA_SEED=1`` to load it:

    set -a && . ./.env && set +a
    QA_SEED=1 .venv/bin/uvicorn app.main:app --port 8001

Everything here is in memory and marked "QA"; nothing touches the normal seed.
"""

from __future__ import annotations

import random
from datetime import datetime, timedelta, timezone

from app.demand import LOCAL_TZ
from app.models import (
    Channel,
    MenuCategory,
    MenuItem,
    NotificationPreferences,
    Order,
    OrderLine,
    OrderStatus,
    Restaurant,
    Route,
    TravelMode,
    User,
    Fulfillment,
)

QA_RESTAURANT_ID = "rest_qa_mdc_wolfson"
QA_USER_ID = "user_qa_student"

# Official address per mdc.edu/wolfson: 300 NE Second Ave, Miami, FL 33132,
# main line 305-237-3000. Coordinates are OpenStreetMap's centroid for
# "Miami Dade College - Wolfson Campus" (checked 2026-10-07).
WOLFSON = (25.77843, -80.19058)
WOLFSON_ADDRESS = "300 NE 2nd Ave, Miami, FL 33132"
WOLFSON_PHONE = "305-237-3000"
# A 5.0 min walk north per the Google Routes API (checked 2026-10-07).
STUDENT = (25.780753, -80.1907)


def restaurant() -> Restaurant:
    return Restaurant(
        id=QA_RESTAURANT_ID,
        name="MDC Wolfson Café (QA)",
        cuisine="Campus café",
        lat=WOLFSON[0],
        lng=WOLFSON[1],
        address=WOLFSON_ADDRESS,
        phone=WOLFSON_PHONE,
        avg_prep_min=6,
        categories=[
            MenuCategory(id="cat_qa_quick", name="Grab & go · ready in ~2 min", sort=0),
            MenuCategory(id="cat_qa_coffee", name="Coffee", sort=1),
            MenuCategory(id="cat_qa_bakery", name="Bakery", sort=2),
            MenuCategory(id="cat_qa_lunch", name="Lunch", sort=3),
            MenuCategory(id="cat_qa_snacks", name="Snacks", sort=4),
        ],
        menu=[
            # Pre-made or bottled: handed over in about two minutes.
            MenuItem(id="qa_turkey_wrap", name="Turkey & cheese wrap", price=6.50, category_id="cat_qa_quick",
                     description="Pre-made, from the cooler.", prep_min=2),
            MenuItem(id="qa_yogurt", name="Greek yogurt parfait", price=4.75, category_id="cat_qa_quick",
                     description="Granola and berries.", prep_min=2),
            MenuItem(id="qa_water", name="Bottled water", price=1.50, category_id="cat_qa_quick", prep_min=1),
            MenuItem(id="qa_banana", name="Banana", price=0.95, category_id="cat_qa_quick", prep_min=1),
            MenuItem(id="qa_cafecito", name="Cafecito", price=1.75, category_id="cat_qa_coffee", prep_min=2),
            MenuItem(id="qa_con_leche", name="Café con leche", price=3.25, category_id="cat_qa_coffee", prep_min=3),
            MenuItem(id="qa_iced_coffee", name="Iced coffee", price=3.75, category_id="cat_qa_coffee", prep_min=2),
            MenuItem(id="qa_pastelito", name="Guava pastelito", price=1.95, category_id="cat_qa_bakery", prep_min=2),
            MenuItem(id="qa_croqueta", name="Ham croqueta", price=1.50, category_id="cat_qa_bakery", prep_min=2),
            MenuItem(id="qa_cubano", name="Cuban sandwich", price=8.95, category_id="cat_qa_lunch"),
            MenuItem(id="qa_empanada", name="Beef empanada", price=3.50, category_id="cat_qa_lunch", prep_min=4),
            MenuItem(id="qa_fruit", name="Fruit cup", price=4.25, category_id="cat_qa_snacks", prep_min=2),
        ],
    )


def student() -> User:
    return User(
        id=QA_USER_ID, name="QA Student", phone="+15550142", email="qa.student@example.com",
        lat=STUDENT[0], lng=STUDENT[1],
        prefs=NotificationPreferences(channels=[Channel.PUSH, Channel.WEBSOCKET], quiet_start=0, quiet_end=0),
    )


# (local hour range, orders on a weekday, item weights) per part of the day.
DAY_SHAPE = [
    ((7, 11), 14, {"qa_cafecito": 5, "qa_con_leche": 6, "qa_pastelito": 6, "qa_croqueta": 4, "qa_fruit": 1}),
    ((11, 15), 18, {"qa_cubano": 6, "qa_empanada": 5, "qa_croqueta": 2, "qa_cafecito": 2, "qa_iced_coffee": 2}),
    ((15, 17), 6, {"qa_iced_coffee": 5, "qa_cafecito": 3, "qa_fruit": 3, "qa_pastelito": 2}),
    ((17, 21), 4, {"qa_empanada": 3, "qa_cubano": 2, "qa_cafecito": 3, "qa_iced_coffee": 1}),
]


def qa_orders(*, now: datetime, days: int = 14, seed: int = 7) -> list[Order]:
    """Backdated, finished orders. Weekends are quiet (few classes)."""
    rng = random.Random(seed)
    today = now.astimezone(LOCAL_TZ).replace(hour=0, minute=0, second=0, microsecond=0)
    out = []
    for d in range(days, 0, -1):
        day = today - timedelta(days=d)
        scale = 0.25 if day.weekday() >= 5 else 1.0
        for (start, end), n, weights in DAY_SHAPE:
            ids, w = zip(*weights.items())
            for _ in range(round(n * scale * rng.uniform(0.8, 1.2))):
                at = (day + timedelta(hours=rng.uniform(start, end))).astimezone(timezone.utc)
                picks: dict[str, int] = {}
                for i in rng.choices(ids, weights=w, k=rng.choice([1, 1, 2, 2, 3])):
                    picks[i] = picks.get(i, 0) + 1
                pickup = rng.random() < 0.7
                out.append(Order(
                    id=f"ord_qa_{len(out):04d}",
                    user_id=QA_USER_ID,
                    restaurant_id=QA_RESTAURANT_ID,
                    lines=[OrderLine(item_id=i, quantity=q) for i, q in picks.items()],
                    status=OrderStatus.COLLECTED if pickup else OrderStatus.DELIVERED,
                    fulfillment=Fulfillment.PICKUP if pickup else Fulfillment.DELIVERY,
                    pickup_mode=TravelMode.WALKING,
                    created_at=at,
                    updated_at=at + timedelta(minutes=15),
                    route=Route(distance_km=0.35, duration_min=5.0, source="qa"),
                ))
    return out


def seed(orders_service, *, now: datetime | None = None) -> int:
    """Add the QA restaurant, student and backdated orders. Returns the order count."""
    now = now or datetime.now(timezone.utc)
    orders_service.restaurants[QA_RESTAURANT_ID] = restaurant()
    orders_service.users[QA_USER_ID] = student()
    batch = qa_orders(now=now)
    for o in batch:
        orders_service.orders[o.id] = o
    return len(batch)
