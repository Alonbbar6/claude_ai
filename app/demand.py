"""Demand by time of day: when each restaurant's orders come in, what sells in
each meal period, and menu suggestions that follow that demand.

Orders are bucketed by the restaurant's local time into meal periods
(breakfast, lunch, afternoon, dinner, late night). For each period we report
volume, revenue and the items that over-index there (``lift`` = an item's
share of the period's items / its share of all the restaurant's items).

Suggestions, each with the numbers behind it:

  * feature  – an item that sells far better in one period than all day:
               put it first on the menu / promote it then.
  * peak     – the busiest period and what to have prepped for it.
  * add_item – a period where customers order from other restaurants but
               this one barely gets orders: ideas for items that fit it.

A new app has no order history, so by default the analysis also includes a
seeded, *simulated* 28-day history (clearly counted separately in
``sources``). Pass ``include_simulated=False`` for live orders only.
"""

from __future__ import annotations

import zlib
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import numpy as np
from pydantic import BaseModel

from app.models import OrderStatus, Restaurant

LOCAL_TZ = ZoneInfo("America/New_York")  # every seeded restaurant is in Miami


@dataclass(frozen=True)
class Period:
    key: str
    label: str
    start: int  # local hour, inclusive
    end: int  # local hour, exclusive; may wrap past midnight
    when: str  # "Feature X {when}"


PERIODS = [
    Period("breakfast", "Breakfast", 6, 11, "at breakfast"),
    Period("lunch", "Lunch", 11, 15, "at lunch"),
    Period("afternoon", "Afternoon", 15, 17, "in the afternoon"),
    Period("dinner", "Dinner", 17, 22, "at dinner"),
    Period("late_night", "Late night", 22, 6, "late at night"),
]
PERIOD_BY_KEY = {p.key: p for p in PERIODS}

# Thresholds for suggestions.
MIN_PERIOD_ORDERS_PER_DAY = 1.0  # below this a period's mix is noise
MIN_ITEM_QTY = 5
FEATURE_LIFT = 1.25
GAP_RATIO = 0.5  # your share of orders in a period <= half other restaurants' share
GAP_MIN_POINTS = 0.02  # ...and at least 2 points below it
MIN_GAP_PLATFORM_ORDERS = 20


def period_of(at: datetime) -> Period:
    hour = at.astimezone(LOCAL_TZ).hour
    for p in PERIODS:
        if p.start < p.end and p.start <= hour < p.end:
            return p
        if p.start > p.end and (hour >= p.start or hour < p.end):
            return p
    raise AssertionError(f"no period covers hour {hour}")


def hours_label(p: Period) -> str:
    def h(x: int) -> str:
        return f"{(x % 12) or 12} {'AM' if x < 12 else 'PM'}"
    return f"{h(p.start)} – {h(p.end)}"


# ---- order records -----------------------------------------------------------

@dataclass
class OrderRecord:
    restaurant_id: str
    at: datetime
    items: dict[str, int]  # item_id -> quantity
    total: float
    simulated: bool = False


def records_from_orders(orders, restaurants: dict[str, Restaurant]) -> list[OrderRecord]:
    """Live orders that weren't cancelled."""
    out = []
    for o in orders:
        if o.status == OrderStatus.CANCELLED or o.restaurant_id not in restaurants:
            continue
        prices = {m.id: m.price for m in restaurants[o.restaurant_id].menu}
        items: dict[str, int] = {}
        for line in o.lines:
            items[line.item_id] = items.get(line.item_id, 0) + line.quantity
        total = sum(prices.get(i, 0.0) * q for i, q in items.items())
        out.append(OrderRecord(o.restaurant_id, o.created_at, items, round(total, 2)))
    return out


# ---- simulated history -------------------------------------------------------

# Orders per day per period for an average restaurant, and how each cuisine
# deviates from that. These are the simulation's "true" habits.
BASE_ORDERS_PER_DAY = {"breakfast": 6, "lunch": 14, "afternoon": 5, "dinner": 18, "late_night": 4}
CUISINE_PERIOD = {
    "Japanese": {"breakfast": 0.15, "late_night": 0.6},
    "Italian": {"breakfast": 0.1, "late_night": 1.6},
    "American": {"breakfast": 0.6, "afternoon": 1.4},
}
# How much more (or less) likely an item is to be picked in a period.
ITEM_PERIOD = {
    "sushi_1": {"lunch": 1.2, "dinner": 1.3},
    "sushi_2": {"lunch": 0.8, "dinner": 1.6},
    "sushi_3": {"breakfast": 2.5, "lunch": 2.0, "late_night": 0.5},
    "pizza_1": {"lunch": 1.3},
    "pizza_2": {"dinner": 1.3, "late_night": 1.5},
    "pizza_3": {"afternoon": 1.8, "late_night": 2.5},
    "burger_1": {"lunch": 1.4, "dinner": 1.3},
    "burger_2": {"afternoon": 1.5, "late_night": 2.0},
    "burger_3": {"breakfast": 0.3, "afternoon": 3.0, "late_night": 1.5},
}


def simulate_history(restaurants: dict[str, Restaurant], *, now: datetime, days: int = 28) -> list[OrderRecord]:
    """Deterministic per restaurant and day, so repeated calls agree."""
    out: list[OrderRecord] = []
    today = now.astimezone(LOCAL_TZ).replace(hour=0, minute=0, second=0, microsecond=0)
    for r in restaurants.values():
        menu = [m for m in r.menu if m.available]
        if not menu:
            continue
        rng = np.random.default_rng(zlib.crc32(r.id.encode()))
        cuisine = CUISINE_PERIOD.get(r.cuisine, {})
        for d in range(days, 0, -1):
            day = today - timedelta(days=d)
            weekend = day.weekday() >= 5
            for p in PERIODS:
                rate = BASE_ORDERS_PER_DAY[p.key] * cuisine.get(p.key, 1.0)
                if weekend:
                    rate *= {"breakfast": 1.3, "dinner": 1.2, "late_night": 1.3}.get(p.key, 1.0)
                weights = np.array([ITEM_PERIOD.get(m.id, {}).get(p.key, 1.0) for m in menu])
                weights = weights / weights.sum()
                span = (p.end - p.start) % 24
                for _ in range(rng.poisson(rate)):
                    at = day + timedelta(hours=p.start + rng.uniform(0, span))
                    items: dict[str, int] = {}
                    for idx in rng.choice(len(menu), size=1 + rng.poisson(0.8), p=weights):
                        items[menu[idx].id] = items.get(menu[idx].id, 0) + 1
                    total = sum(next(m.price for m in menu if m.id == i) * q for i, q in items.items())
                    out.append(OrderRecord(r.id, at.astimezone(timezone.utc), items, round(total, 2), True))
    return out


# ---- report ------------------------------------------------------------------

class ItemStat(BaseModel):
    item_id: str
    name: str
    quantity: int
    share: float  # of this period's items
    lift: float  # share here / share all day


class PeriodStat(BaseModel):
    key: str
    label: str
    hours: str
    orders: int
    orders_per_day: float
    share_of_orders: float
    revenue: float
    avg_order_value: float
    others_share_of_orders: float  # same period, the app's other restaurants
    top_items: list[ItemStat]


class Suggestion(BaseModel):
    kind: str  # feature | peak | add_item
    period: str
    title: str
    detail: str
    item_ids: list[str] = []
    ideas: list[str] = []


class DemandReport(BaseModel):
    restaurant_id: str
    timezone: str
    days: int
    sources: dict[str, int]  # live_orders, simulated_orders
    total_orders: int
    peak_period: str | None
    periods: list[PeriodStat]
    suggestions: list[Suggestion]


# Item ideas for a period the restaurant under-serves, by cuisine.
IDEAS = {
    "Japanese": {
        "breakfast": ["Onigiri rice balls", "Tamagoyaki", "Breakfast miso set"],
        "afternoon": ["Matcha mochi", "Edamame"],
        "late_night": ["Spicy ramen", "Gyoza"],
    },
    "Italian": {
        "breakfast": ["Cornetto & espresso", "Frittata slice"],
        "afternoon": ["Pizza by the slice", "Tiramisu cup"],
        "late_night": ["Calzone", "Mozzarella sticks"],
    },
    "American": {
        "breakfast": ["Bacon, egg & cheese sandwich", "Pancake stack", "Breakfast burrito"],
        "afternoon": ["Loaded fries", "Iced coffee"],
        "late_night": ["Chicken tenders", "Double smash burger"],
    },
}
DEFAULT_IDEAS = {
    "breakfast": ["Coffee & pastry", "Breakfast wrap"],
    "lunch": ["Lunch combo with a drink"],
    "afternoon": ["Snack box", "Iced coffee"],
    "dinner": ["Family meal deal"],
    "late_night": ["Late-night combo"],
}


@dataclass
class _Bucket:
    orders: int = 0
    revenue: float = 0.0
    items: dict[str, int] = field(default_factory=dict)


def analyze(
    restaurant: Restaurant,
    records: list[OrderRecord],
    *,
    now: datetime,
    days: int = 28,
) -> DemandReport:
    since = now - timedelta(days=days)
    window = [r for r in records if since <= r.at <= now]
    mine = [r for r in window if r.restaurant_id == restaurant.id]
    names = {m.id: m.name for m in restaurant.menu}

    buckets = {p.key: _Bucket() for p in PERIODS}
    # Other restaurants are the baseline, so a restaurant isn't compared with itself.
    others = {p.key: 0 for p in PERIODS}
    for r in window:
        if r.restaurant_id != restaurant.id:
            others[period_of(r.at).key] += 1
    all_day: dict[str, int] = {}
    for r in mine:
        b = buckets[period_of(r.at).key]
        b.orders += 1
        b.revenue += r.total
        for i, q in r.items.items():
            b.items[i] = b.items.get(i, 0) + q
            all_day[i] = all_day.get(i, 0) + q

    total = len(mine)
    others_total = sum(others.values())
    all_items = sum(all_day.values())
    stats: list[PeriodStat] = []
    for p in PERIODS:
        b = buckets[p.key]
        n_items = sum(b.items.values())
        top = []
        for i, q in sorted(b.items.items(), key=lambda kv: -kv[1]):
            share = q / n_items
            base = all_day[i] / all_items
            top.append(ItemStat(item_id=i, name=names.get(i, i), quantity=q,
                                share=round(share, 3), lift=round(share / base, 2)))
        stats.append(PeriodStat(
            key=p.key, label=p.label, hours=hours_label(p), orders=b.orders,
            orders_per_day=round(b.orders / days, 1),
            share_of_orders=round(b.orders / total, 3) if total else 0.0,
            revenue=round(b.revenue, 2),
            avg_order_value=round(b.revenue / b.orders, 2) if b.orders else 0.0,
            others_share_of_orders=round(others[p.key] / others_total, 3) if others_total else 0.0,
            top_items=top[:5],
        ))

    peak = max(stats, key=lambda s: s.orders) if total else None
    return DemandReport(
        restaurant_id=restaurant.id,
        timezone=str(LOCAL_TZ),
        days=days,
        sources={"live_orders": sum(not r.simulated for r in mine),
                 "simulated_orders": sum(r.simulated for r in mine)},
        total_orders=total,
        peak_period=peak.key if peak else None,
        periods=stats,
        suggestions=suggest(restaurant, stats, others, peak),
    )


def suggest(restaurant: Restaurant, stats: list[PeriodStat], others: dict[str, int],
            peak: PeriodStat | None) -> list[Suggestion]:
    out: list[Suggestion] = []

    if peak and peak.orders_per_day >= MIN_PERIOD_ORDERS_PER_DAY:
        best = peak.top_items[:2]
        start = hours_label(PERIOD_BY_KEY[peak.key]).split(" – ")[0]
        out.append(Suggestion(
            kind="peak", period=peak.key,
            title=f"{peak.label} is your busiest time",
            detail=(f"{peak.share_of_orders:.0%} of your orders (about {peak.orders_per_day:g} a day). "
                    f"Have {' and '.join(i.name for i in best)} prepped before {start}."),
            item_ids=[i.item_id for i in best],
        ))

    for s in stats:
        if s.orders_per_day < MIN_PERIOD_ORDERS_PER_DAY:
            continue
        picks = [i for i in s.top_items if i.lift >= FEATURE_LIFT and i.quantity >= MIN_ITEM_QTY]
        if not picks:
            continue
        i = max(picks, key=lambda x: x.lift * x.quantity)
        out.append(Suggestion(
            kind="feature", period=s.key,
            title=f"Feature {i.name} {PERIOD_BY_KEY[s.key].when}",
            detail=(f"{i.share:.0%} of items ordered {PERIOD_BY_KEY[s.key].when} vs {i.share / i.lift:.0%} "
                    f"all day ({i.lift:g}× more popular then). Put it first on the menu {s.hours}."),
            item_ids=[i.item_id],
        ))

    menu_names = " ".join(m.name.lower() for m in restaurant.menu)
    for s in stats:
        under = (s.share_of_orders <= s.others_share_of_orders * GAP_RATIO
                 and s.others_share_of_orders - s.share_of_orders >= GAP_MIN_POINTS)
        if not under or others[s.key] < MIN_GAP_PLATFORM_ORDERS:
            continue
        ideas = IDEAS.get(restaurant.cuisine, {}).get(s.key) or DEFAULT_IDEAS[s.key]
        ideas = [x for x in ideas if x.lower() not in menu_names]
        if not ideas:
            continue
        out.append(Suggestion(
            kind="add_item", period=s.key,
            title=f"Add {s.label.lower()} items",
            detail=(f"{s.others_share_of_orders:.0%} of other restaurants' orders come in {PERIOD_BY_KEY[s.key].when} "
                    f"({s.hours}), but only {s.share_of_orders:.1%} of yours. Items that fit "
                    f"{s.label.lower()} could win those customers."),
            ideas=ideas,
        ))
    return out


class DemandService:
    """Holds the simulated history (generated once) and builds reports."""

    def __init__(self, restaurants: dict[str, Restaurant], *, clock=None, history_days: int = 28,
                 simulate: list[str] | None = None):
        """``simulate``: restaurant ids that get simulated history (default all)."""
        self.restaurants = restaurants
        self.clock = clock or (lambda: datetime.now(timezone.utc))
        sim = {rid: r for rid, r in restaurants.items() if simulate is None or rid in simulate}
        self.history = simulate_history(sim, now=self.clock(), days=history_days)

    def report(self, restaurant_id: str, live_orders, *, days: int = 28,
               include_simulated: bool = True) -> DemandReport:
        restaurant = self.restaurants[restaurant_id]  # KeyError -> 404
        records = records_from_orders(live_orders, self.restaurants)
        if include_simulated:
            records += self.history
        return analyze(restaurant, records, now=self.clock(), days=days)

