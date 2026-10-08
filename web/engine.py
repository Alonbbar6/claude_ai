"""Inventory engine for the Barmade restaurant demo.

Every number here — depletion, alert status, servings remaining, sales totals,
overstock, close-day facts — is computed deterministically from recipes and
recorded events. Stock figures are *estimates*; only a manager-confirmed count
resets them. The AI (web/summary.py) only phrases the close-day summary.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field
from datetime import date, datetime
from typing import Callable

from web.data import (
    CHANNELS, CHANNELS_BY_ID, INGREDIENTS, MENU, RESTAURANT,
    normalize, seed_history, to_channel_payload,
)

EPS = 1e-9
OVERSTOCK_FACTOR = 1.5      # on hand >= 1.5 x par counts as overstocked
SPECIAL_DISCOUNT = 0.15
COUNT_WEEKDAY = 6           # Sunday: the regular weekly inventory count


class OrderError(Exception):
    def __init__(self, code: str, message: str, details: dict | None = None):
        super().__init__(message)
        self.code, self.message, self.details = code, message, details or {}


@dataclass
class Ingredient:
    id: str
    name: str
    category: str
    unit: str
    par: float
    low_threshold: float
    daily_usage: float
    on_hand: float = 0.0            # estimated, from recipes and events
    last_counted_at: datetime | None = None


@dataclass
class RecipeLine:
    ingredient_id: str
    quantity: float


@dataclass
class MenuItem:
    id: str
    name: str
    price: float
    description: str
    recipe: list[RecipeLine]
    paused: bool = False            # manager pause (simulated; no channel is really changed)


@dataclass
class Event:
    """One inventory-affecting movement: sale, delivery, waste or count."""
    id: str
    type: str
    at: datetime
    ingredient_id: str
    delta: float
    before: float
    after: float
    note: str = ""
    order_id: str | None = None


@dataclass
class OrderLine:
    menu_item_id: str
    name: str
    quantity: int
    unit_price: float
    line_total: float


@dataclass
class Order:
    id: str
    channel: str
    channel_label: str
    raw_payload: dict               # what the simulated channel sent
    lines: list[OrderLine]          # canonical form
    total: float
    created_at: datetime
    customer: str | None = None
    event_ids: list[str] = field(default_factory=list)
    status: str = "accepted"


@dataclass
class Alert:
    id: str
    ingredient_id: str
    kind: str                       # low | out
    message: str
    created_at: datetime
    order_id: str | None = None
    status: str = "active"
    resolved_at: datetime | None = None


def _iso(d: datetime | date | None) -> str | None:
    return d.isoformat() if d else None


def fmt(v: float) -> str:
    return f"{v:,.0f}" if abs(v - round(v)) < 1e-6 else f"{v:,.1f}"


class Store:
    def __init__(self, clock: Callable[[], datetime] | None = None, seed: bool = True):
        self.clock = clock or (lambda: datetime.now().replace(microsecond=0))
        self.ingredients = {i[0]: Ingredient(*i[:4], par=i[4], low_threshold=i[5], daily_usage=i[6]) for i in INGREDIENTS}
        self.menu = {m[0]: MenuItem(m[0], m[1], m[2], m[3], [RecipeLine(k, v) for k, v in m[4].items()]) for m in MENU}
        self.orders: list[Order] = []
        self.events: list[Event] = []
        self.alerts: list[Alert] = []
        self.closed_days: dict[date, dict] = {}
        self._seq = {"ORD": 0, "EVT": 0, "ALT": 0}
        if seed:
            seed_history(self)

    def _next(self, prefix: str) -> str:
        self._seq[prefix] += 1
        return f"{prefix}-{self._seq[prefix]:04d}"

    # ---- stock status --------------------------------------------------------

    def smallest_need(self, ing_id: str) -> float:
        needs = [l.quantity for m in self.menu.values() for l in m.recipe if l.ingredient_id == ing_id]
        return min(needs) if needs else 0.0

    def status(self, ing: Ingredient) -> str:
        if ing.on_hand <= EPS or ing.on_hand + EPS < self.smallest_need(ing.id):
            return "out"
        if ing.on_hand <= ing.low_threshold + EPS:
            return "low"
        return "ok"

    def used_in(self, ing_id: str) -> list[str]:
        return [m.name for m in self.menu.values() if any(l.ingredient_id == ing_id for l in m.recipe)]

    def servings(self, item: MenuItem) -> dict:
        """Explainable estimate: which ingredient constrains the dish and why."""
        basis = []
        for line in item.recipe:
            ing = self.ingredients[line.ingredient_id]
            n = math.floor(max(ing.on_hand, 0) / line.quantity + EPS)
            basis.append({"ingredient_id": ing.id, "ingredient": ing.name, "unit": ing.unit,
                          "on_hand": round(ing.on_hand, 2), "per_serving": line.quantity, "servings": n,
                          "calc": f"{fmt(ing.on_hand)} {ing.unit} ÷ {fmt(line.quantity)} {ing.unit} = {n}"})
        limit = min(basis, key=lambda b: b["servings"])
        return {"servings": limit["servings"], "constraint": limit, "basis": basis,
                "estimate_note": "Based on estimated stock, not a physical count."}

    # ---- movements -----------------------------------------------------------

    def _move(self, ing_id: str, delta: float, type_: str, note: str = "", order_id: str | None = None) -> Event:
        ing = self.ingredients[ing_id]
        before = ing.on_hand
        ing.on_hand = round(before + delta, 4)
        ev = Event(self._next("EVT"), type_, self.clock(), ing_id, round(delta, 4), round(before, 4), ing.on_hand, note, order_id)
        self.events.append(ev)
        return ev

    def receive(self, ing_id: str, qty: float, note: str = "Delivery") -> Event:
        if qty <= 0:
            raise OrderError("INVALID_QUANTITY", "Delivery quantity must be greater than 0.")
        ev = self._move(ing_id, qty, "delivery", note)
        self._check_alerts({ing_id})
        return ev

    def waste(self, ing_id: str, qty: float, note: str = "Waste") -> Event:
        if qty <= 0:
            raise OrderError("INVALID_QUANTITY", "Waste quantity must be greater than 0.")
        ev = self._move(ing_id, -qty, "waste", note)
        self._check_alerts({ing_id})
        return ev

    # ---- orders --------------------------------------------------------------

    def place_order(self, channel: str, lines: list[tuple[str, int]], customer: str | None = None,
                    rng: random.Random | None = None) -> Order:
        if channel not in CHANNELS_BY_ID:
            raise OrderError("UNKNOWN_CHANNEL", f"Channel '{channel}' is not one of the simulated channels.")
        lines = [(m, int(q)) for m, q in lines if int(q) > 0] if all(
            isinstance(q, (int, float)) and float(q).is_integer() and q >= 0 for _, q in lines) else None
        if lines is None:
            raise OrderError("INVALID_QUANTITY", "Quantities must be whole numbers of 0 or more.")
        if not lines:
            raise OrderError("EMPTY_ORDER", "Add at least one dish.")
        for mid, _ in lines:
            if mid not in self.menu:
                raise OrderError("UNKNOWN_ITEM", f"Menu item {mid} was not found.")
        # Simulate the channel's own format, then normalize it back: the same
        # path a real adapter would take.
        payload = to_channel_payload(channel, lines, customer, rng)
        canonical = normalize(channel, payload)

        need: dict[str, float] = {}
        order_lines = []
        for mid, qty in canonical:
            item = self.menu[mid]
            if item.paused:
                raise OrderError("ITEM_PAUSED", f"{item.name} is paused by the manager while stock is low.")
            for l in item.recipe:
                need[l.ingredient_id] = need.get(l.ingredient_id, 0) + l.quantity * qty
            order_lines.append(OrderLine(mid, item.name, qty, item.price, round(item.price * qty, 2)))
        shortages = [{"ingredient_id": i, "ingredient": self.ingredients[i].name, "unit": self.ingredients[i].unit,
                      "needed": q, "estimated_on_hand": round(self.ingredients[i].on_hand, 2)}
                     for i, q in need.items() if self.ingredients[i].on_hand + EPS < q]
        if shortages:
            names = ", ".join(s["ingredient"] for s in shortages)
            raise OrderError("INSUFFICIENT_ESTIMATED_STOCK",
                             f"Estimated stock can't cover this order: {names}.", {"shortages": shortages})

        order = Order(self._next("ORD"), channel, CHANNELS_BY_ID[channel]["label"], payload, order_lines,
                      round(sum(l.line_total for l in order_lines), 2), self.clock(), customer)
        for ing_id, qty in need.items():
            ev = self._move(ing_id, -qty, "sale", f"{order.id} via {order.channel_label}", order.id)
            order.event_ids.append(ev.id)
        self.orders.append(order)
        self._check_alerts(set(need), order)
        return order

    def simulate_rush(self, n: int = 12, seed: int | None = None) -> dict:
        """Fallback when the classroom can't place enough live orders."""
        rng = random.Random(seed)
        from web.data import _CHANNEL_WEIGHTS, _ITEM_WEIGHTS, _NAMES
        placed, rejected = [], []
        for _ in range(max(1, min(n, 50))):
            channel = rng.choices(list(_CHANNEL_WEIGHTS), weights=list(_CHANNEL_WEIGHTS.values()))[0]
            picks = rng.sample(list(_ITEM_WEIGHTS), k=rng.choice([1, 2, 2, 3]), counts=list(_ITEM_WEIGHTS.values()))
            lines = [(m, rng.choice([1, 1, 2])) for m in dict.fromkeys(picks)]
            try:
                placed.append(self.place_order(channel, lines, customer=rng.choice(_NAMES), rng=rng).id)
            except OrderError as e:
                rejected.append({"channel": channel, "reason": e.message})
        return {"placed": placed, "rejected": rejected}

    # ---- alerts --------------------------------------------------------------

    def _alert_message(self, ing: Ingredient, kind: str, order: Order | None) -> str:
        left = ", ".join(f"{m.name} {self.servings(m)['servings']}" for m in self.menu.values()
                         if any(l.ingredient_id == ing.id for l in m.recipe))
        cause = f" Last movement: {order.id} via {order.channel_label}." if order else ""
        if kind == "out":
            return (f"{ing.name} is effectively out — estimated {fmt(ing.on_hand)} {ing.unit}, less than one serving needs. "
                    f"Dishes affected: {left}.{cause} Pause those dishes or restock before accepting more orders.")
        return (f"{ing.name} is down to an estimated {fmt(ing.on_hand)} {ing.unit}, at or below the "
                f"{fmt(ing.low_threshold)} {ing.unit} alert level. Estimated servings left: {left}.{cause} "
                f"Restock to par ({fmt(ing.par)} {ing.unit}) or pause the affected dishes.")

    def _check_alerts(self, ing_ids: set[str], order: Order | None = None) -> None:
        now = self.clock()
        for ing_id in ing_ids:
            ing = self.ingredients[ing_id]
            st = self.status(ing)
            active = [a for a in self.alerts if a.ingredient_id == ing_id and a.status == "active"]
            if st == "ok":
                for a in active:
                    a.status, a.resolved_at = "resolved", now
            elif not active or active[-1].kind != st:
                for a in active:
                    a.status, a.resolved_at = "resolved", now
                self.alerts.append(Alert(self._next("ALT"), ing_id, st, self._alert_message(ing, st, order), now,
                                         order.id if order else None))

    # ---- inventory counts (review, then confirm) ------------------------------

    def count_sheet(self) -> dict:
        today = self.clock().date()
        return {"date": today.isoformat(), "scheduled": today.weekday() == COUNT_WEEKDAY,
                "schedule": "Regular count: every Sunday after close (demo convention)",
                "rows": [{"id": i.id, "name": i.name, "unit": i.unit, "expected": round(i.on_hand, 2),
                          "last_counted_at": _iso(i.last_counted_at)} for i in self.ingredients.values()]}

    def review_count(self, counts: dict[str, float]) -> dict:
        """Diff a proposed count against the estimate. Saves nothing."""
        rows = []
        for ing_id, counted in counts.items():
            if ing_id not in self.ingredients:
                raise OrderError("UNKNOWN_INGREDIENT", f"Ingredient {ing_id} was not found.")
            if counted is None or float(counted) < 0:
                raise OrderError("INVALID_QUANTITY", f"Count for {self.ingredients[ing_id].name} must be 0 or more.")
            ing = self.ingredients[ing_id]
            delta = round(float(counted) - ing.on_hand, 2)
            pct = (delta / ing.on_hand * 100) if ing.on_hand > EPS else (100.0 if delta > 0 else 0.0)
            rows.append({"id": ing.id, "name": ing.name, "unit": ing.unit, "expected": round(ing.on_hand, 2),
                         "counted": float(counted), "delta": delta, "pct": round(pct, 1),
                         "flag": abs(pct) >= 10 and abs(delta) > EPS})
        changes = [r for r in rows if abs(r["delta"]) > EPS]
        return {"rows": rows, "changes": changes, "note": "Nothing is saved until you confirm."}

    def confirm_count(self, counts: dict[str, float], note: str = "") -> list[Event]:
        review = self.review_count(counts)
        now = self.clock()
        events = []
        for r in review["rows"]:
            if abs(r["delta"]) > EPS:
                events.append(self._move(r["id"], r["delta"], "count", note or "Manager count"))
            self.ingredients[r["id"]].last_counted_at = now
        self._check_alerts({r["id"] for r in review["rows"]})
        return events

    # ---- overstock ----------------------------------------------------------

    def overstock_specials(self) -> list[dict]:
        out = []
        for ing in self.ingredients.values():
            if ing.on_hand + EPS < ing.par * OVERSTOCK_FACTOR:
                continue
            users = [(m, next(l.quantity for l in m.recipe if l.ingredient_id == ing.id))
                     for m in self.menu.values() if any(l.ingredient_id == ing.id for l in m.recipe)]
            if not users:
                continue
            dish, per = max(users, key=lambda u: u[1])
            excess = ing.on_hand - ing.par
            n = math.floor(excess / per)
            days = round(ing.on_hand / ing.daily_usage, 1) if ing.daily_usage else None
            price = round(dish.price * (1 - SPECIAL_DISCOUNT), 2)
            out.append({
                "ingredient_id": ing.id, "ingredient": ing.name, "unit": ing.unit,
                "on_hand": round(ing.on_hand, 2), "par": ing.par, "ratio": round(ing.on_hand / ing.par, 1),
                "days_of_cover": days, "dish_id": dish.id, "dish": dish.name, "per_serving": per,
                "servings_to_par": n, "regular_price": dish.price, "special_price": price,
                "discount_pct": int(SPECIAL_DISCOUNT * 100),
                "reason": (f"{ing.name} is at an estimated {fmt(ing.on_hand)} {ing.unit}, {round(ing.on_hand / ing.par, 1)}× par "
                           f"({fmt(ing.par)} {ing.unit}) — about {days} days of cover at the usual {fmt(ing.daily_usage)} {ing.unit}/day. "
                           f"{dish.name} uses {fmt(per)} {ing.unit} per serving, so selling {n} more at ${price:.2f} "
                           f"({int(SPECIAL_DISCOUNT * 100)}% off) brings it back to par."),
            })
        return out

    # ---- day facts and history ----------------------------------------------

    def day_facts(self, day: date | None = None) -> dict:
        day = day or self.clock().date()
        orders = [o for o in self.orders if o.created_at.date() == day]
        by_channel: dict[str, dict] = {}
        dishes: dict[str, int] = {}
        for o in orders:
            c = by_channel.setdefault(o.channel_label, {"orders": 0, "revenue": 0.0})
            c["orders"] += 1
            c["revenue"] = round(c["revenue"] + o.total, 2)
            for l in o.lines:
                dishes[l.name] = dishes.get(l.name, 0) + l.quantity
        evs = [e for e in self.events if e.at.date() == day]
        used: dict[str, float] = {}
        for e in evs:
            if e.type == "sale":
                used[e.ingredient_id] = used.get(e.ingredient_id, 0) - e.delta
        top_used = sorted(used.items(), key=lambda kv: kv[1] / max(self.ingredients[kv[0]].daily_usage, 1), reverse=True)[:5]
        low_now = [{"ingredient": i.name, "estimated_on_hand": round(i.on_hand, 2), "unit": i.unit,
                    "threshold": i.low_threshold, "status": self.status(i),
                    "servings": {m.name: self.servings(m)["servings"] for m in self.menu.values()
                                 if any(l.ingredient_id == i.id for l in m.recipe)}}
                   for i in self.ingredients.values() if self.status(i) != "ok"]
        return {
            "restaurant": RESTAURANT["name"], "date": day.isoformat(),
            "data_note": "All figures are synthetic demo data. Stock levels are recipe-based estimates, not physical counts.",
            "sales": {"orders": len(orders), "revenue": round(sum(o.total for o in orders), 2),
                      "by_channel": by_channel,
                      "top_dishes": [{"dish": k, "quantity": v} for k, v in sorted(dishes.items(), key=lambda kv: -kv[1])[:5]]},
            "inventory": {
                "ingredients_used": [{"ingredient": self.ingredients[i].name, "used": round(q, 2),
                                      "unit": self.ingredients[i].unit, "estimated_on_hand": round(self.ingredients[i].on_hand, 2)}
                                     for i, q in top_used],
                "deliveries": [{"ingredient": self.ingredients[e.ingredient_id].name, "quantity": e.delta,
                                "unit": self.ingredients[e.ingredient_id].unit, "note": e.note} for e in evs if e.type == "delivery"],
                "waste": [{"ingredient": self.ingredients[e.ingredient_id].name, "quantity": -e.delta,
                           "unit": self.ingredients[e.ingredient_id].unit, "note": e.note} for e in evs if e.type == "waste"],
                "count_adjustments": [{"ingredient": self.ingredients[e.ingredient_id].name, "adjustment": e.delta,
                                       "unit": self.ingredients[e.ingredient_id].unit, "before": e.before, "after": e.after}
                                      for e in evs if e.type == "count"],
                "low_or_out_now": low_now,
            },
            "alerts_raised": [{"ingredient": self.ingredients[a.ingredient_id].name, "kind": a.kind,
                               "at": a.created_at.strftime("%H:%M"), "triggered_by": a.order_id}
                              for a in self.alerts if a.created_at.date() == day],
            "overstock_specials": [{"ingredient": s["ingredient"], "dish": s["dish"], "special_price": s["special_price"],
                                    "servings_to_par": s["servings_to_par"], "days_of_cover": s["days_of_cover"]}
                                   for s in self.overstock_specials()],
            "paused_dishes": [m.name for m in self.menu.values() if m.paused],
        }

    def close_day(self) -> dict:
        facts = self.day_facts()
        facts["closed_at"] = self.clock().strftime("%H:%M")
        self.closed_days[self.clock().date()] = facts
        return facts

    def history(self, days: int = 60) -> list[dict]:
        out = []
        for day, f in sorted(self.closed_days.items())[-days:]:
            out.append({"date": day.isoformat(), "orders": f["sales"]["orders"], "revenue": f["sales"]["revenue"],
                        "by_channel": {k: v["orders"] for k, v in f["sales"]["by_channel"].items()}})
        return out

    # ---- views ---------------------------------------------------------------

    def ingredient_view(self, ing: Ingredient) -> dict:
        return {"id": ing.id, "name": ing.name, "category": ing.category, "unit": ing.unit,
                "estimated_on_hand": round(ing.on_hand, 2), "low_threshold": ing.low_threshold, "par": ing.par,
                "daily_usage": ing.daily_usage, "status": self.status(ing),
                "fill": round(min(ing.on_hand / ing.par, 1.0), 3) if ing.par else 0,
                "days_of_cover": round(ing.on_hand / ing.daily_usage, 1) if ing.daily_usage else None,
                "overstock": ing.on_hand + EPS >= ing.par * OVERSTOCK_FACTOR,
                "used_in": self.used_in(ing.id), "last_counted_at": _iso(ing.last_counted_at)}

    def menu_view(self, item: MenuItem) -> dict:
        s = self.servings(item)
        return {"id": item.id, "name": item.name, "price": item.price, "description": item.description,
                "paused": item.paused, "servings": s,
                "recipe": [{"ingredient_id": l.ingredient_id, "ingredient": self.ingredients[l.ingredient_id].name,
                            "quantity": l.quantity, "unit": self.ingredients[l.ingredient_id].unit} for l in item.recipe]}

    def event_view(self, e: Event) -> dict:
        return {"id": e.id, "type": e.type, "at": _iso(e.at), "ingredient_id": e.ingredient_id,
                "ingredient": self.ingredients[e.ingredient_id].name, "unit": self.ingredients[e.ingredient_id].unit,
                "delta": e.delta, "before": e.before, "after": e.after, "note": e.note, "order_id": e.order_id}

    def order_view(self, o: Order, trace: bool = False) -> dict:
        d = {"id": o.id, "channel": o.channel, "channel_label": o.channel_label, "customer": o.customer,
             "created_at": _iso(o.created_at), "total": o.total, "status": o.status,
             "lines": [{"menu_item_id": l.menu_item_id, "name": l.name, "quantity": l.quantity,
                        "unit_price": l.unit_price, "line_total": l.line_total} for l in o.lines]}
        if trace:
            d["raw_payload"] = o.raw_payload
            d["movements"] = [self.event_view(e) for e in self.events if e.order_id == o.id]
            d["recipes"] = [{"dish": l.name, "quantity": l.quantity, "recipe": self.menu_view(self.menu[l.menu_item_id])["recipe"]}
                            for l in o.lines]
        return d

    def alert_view(self, a: Alert) -> dict:
        return {"id": a.id, "ingredient_id": a.ingredient_id, "ingredient": self.ingredients[a.ingredient_id].name,
                "kind": a.kind, "message": a.message, "created_at": _iso(a.created_at), "order_id": a.order_id,
                "status": a.status, "resolved_at": _iso(a.resolved_at)}

    def state(self) -> dict:
        today = self.clock().date()
        todays = [o for o in self.orders if o.created_at.date() == today]
        return {
            "restaurant": RESTAURANT, "now": _iso(self.clock()), "channels": CHANNELS,
            "today": {"orders": len(todays), "revenue": round(sum(o.total for o in todays), 2),
                      "closed": today in self.closed_days},
            "inventory": [self.ingredient_view(i) for i in self.ingredients.values()],
            "menu": [self.menu_view(m) for m in self.menu.values()],
            "alerts": [self.alert_view(a) for a in reversed(self.alerts) if a.status == "active"],
            "recent_orders": [self.order_view(o) for o in reversed(self.orders[-25:])],
            "specials": self.overstock_specials(),
            "history": self.history(14),
            "history_days": len(self.closed_days),
        }
