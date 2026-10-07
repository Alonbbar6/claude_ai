"""Restaurant inventory: ingredients, stock movements, sold-out logic, alerts
and a stock-out forecast.

Each menu item has a recipe (ingredient -> quantity per item). Placing an
order deducts stock; cancelling puts it back. Whenever stock changes, items
whose recipe can't be made even once are flagged ``sold_out`` so customers
can't order them, and they come back automatically on restock.

Forecast: usage rate is the larger of the ingredient's typical daily usage and
the pace of the last hour's orders, so a rush pulls the "runs out in" estimate
in immediately.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.models import (
    Ingredient,
    InventoryAdjustment,
    InventoryAlert,
    Order,
    OrderLine,
    Restaurant,
)

EPS = 1e-9
OBSERVED_WINDOW = timedelta(hours=1)


class OutOfStock(Exception):
    """The order can't be made with current stock or availability."""


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class InventoryService:
    def __init__(self, restaurants: dict[str, Restaurant], ingredients: list[Ingredient], *, clock=utcnow):
        self.restaurants = restaurants
        self.ingredients: dict[str, Ingredient] = {i.id: i for i in ingredients}
        self.adjustments: list[InventoryAdjustment] = []
        self.alerts: list[InventoryAlert] = []
        self.clock = clock
        for rid in restaurants:
            self.refresh_availability(rid)

    # ---- lookups -----------------------------------------------------

    def for_restaurant(self, restaurant_id: str) -> list[Ingredient]:
        return [i for i in self.ingredients.values() if i.restaurant_id == restaurant_id]

    def get(self, restaurant_id: str, ingredient_id: str) -> Ingredient:
        ing = self.ingredients.get(ingredient_id)
        if ing is None or ing.restaurant_id != restaurant_id:
            raise KeyError(ingredient_id)
        return ing

    def history(self, ingredient_id: str, limit: int = 50) -> list[InventoryAdjustment]:
        return [a for a in reversed(self.adjustments) if a.ingredient_id == ingredient_id][:limit]

    def alerts_for(self, restaurant_id: str) -> list[InventoryAlert]:
        return [a for a in reversed(self.alerts) if a.restaurant_id == restaurant_id]

    # ---- orders ------------------------------------------------------

    def requirements(self, restaurant_id: str, lines: list[OrderLine]) -> dict[str, float]:
        items = {m.id: m for m in self.restaurants[restaurant_id].menu}
        need: dict[str, float] = {}
        for line in lines:
            for ing_id, qty in items[line.item_id].recipe.items():
                need[ing_id] = need.get(ing_id, 0.0) + qty * line.quantity
        return need

    def check(self, restaurant_id: str, lines: list[OrderLine]) -> None:
        """Raise OutOfStock if any item is switched off or stock is short."""
        items = {m.id: m for m in self.restaurants[restaurant_id].menu}
        for line in lines:
            item = items[line.item_id]
            if not item.available:
                raise OutOfStock(f"{item.name} is currently unavailable")
        for ing_id, qty in self.requirements(restaurant_id, lines).items():
            ing = self.ingredients.get(ing_id)
            if ing is not None and ing.on_hand + EPS < qty:
                names = [items[l.item_id].name for l in lines if ing_id in items[l.item_id].recipe]
                raise OutOfStock(f"Not enough {ing.name.lower()} for {', '.join(names)}")

    def consume(self, order: Order) -> None:
        for ing_id, qty in self.requirements(order.restaurant_id, order.lines).items():
            if ing_id in self.ingredients:
                self._apply(ing_id, -qty, "order", order_id=order.id)

    def release(self, order: Order) -> None:
        """Return stock for a cancelled order."""
        for ing_id, qty in self.requirements(order.restaurant_id, order.lines).items():
            if ing_id in self.ingredients:
                self._apply(ing_id, qty, "cancel", order_id=order.id)

    # ---- stock movements ---------------------------------------------

    def restock(self, restaurant_id: str, ingredient_id: str, quantity: float, note: str = "") -> Ingredient:
        if quantity <= 0:
            raise ValueError("restock quantity must be positive")
        self.get(restaurant_id, ingredient_id)
        return self._apply(ingredient_id, quantity, "restock", note=note)

    def waste(self, restaurant_id: str, ingredient_id: str, quantity: float, note: str = "") -> Ingredient:
        ing = self.get(restaurant_id, ingredient_id)
        if quantity <= 0:
            raise ValueError("waste quantity must be positive")
        if quantity > ing.on_hand + EPS:
            raise ValueError(f"only {ing.on_hand:g} {ing.unit} on hand")
        return self._apply(ingredient_id, -quantity, "waste", note=note)

    def count(self, restaurant_id: str, ingredient_id: str, counted: float, note: str = "") -> Ingredient:
        """Stock-take: set the on-hand amount to what was physically counted."""
        ing = self.get(restaurant_id, ingredient_id)
        if counted < 0:
            raise ValueError("count can't be negative")
        return self._apply(ingredient_id, counted - ing.on_hand, "count", note=note)

    def _apply(self, ingredient_id: str, delta: float, reason: str, *, note: str = "", order_id: str | None = None) -> Ingredient:
        ing = self.ingredients[ingredient_id]
        before = ing.on_hand
        ing.on_hand = round(max(0.0, before + delta), 3)
        self.adjustments.append(InventoryAdjustment(
            restaurant_id=ing.restaurant_id, ingredient_id=ing.id, delta=round(ing.on_hand - before, 3),
            on_hand_after=ing.on_hand, reason=reason, note=note, order_id=order_id, at=self.clock(),
        ))
        self._maybe_alert(ing, before)
        self.refresh_availability(ing.restaurant_id)
        return ing

    def _maybe_alert(self, ing: Ingredient, before: float) -> None:
        # Alert on crossing a line, not on every movement below it.
        if ing.on_hand <= EPS < before:
            kind, msg = "out", f"{ing.name} is out of stock"
        elif ing.on_hand <= ing.low_threshold < before:
            kind, msg = "low", f"{ing.name} is low: {ing.on_hand:g} {ing.unit} left"
        else:
            return
        used_by = self.used_by(ing)
        if used_by:
            msg += f" (used in {', '.join(used_by)})"
        self.alerts.append(InventoryAlert(
            restaurant_id=ing.restaurant_id, ingredient_id=ing.id, kind=kind, message=msg, at=self.clock()))

    # ---- availability ------------------------------------------------

    def refresh_availability(self, restaurant_id: str) -> None:
        """Flag items sold out when any ingredient can't cover one portion."""
        for item in self.restaurants[restaurant_id].menu:
            item.sold_out = any(
                ing_id in self.ingredients and self.ingredients[ing_id].on_hand + EPS < qty
                for ing_id, qty in item.recipe.items()
            )

    def used_by(self, ing: Ingredient) -> list[str]:
        return [m.name for m in self.restaurants[ing.restaurant_id].menu if ing.id in m.recipe]

    # ---- ingredient CRUD -----------------------------------------------

    def add(self, ing: Ingredient) -> Ingredient:
        if ing.restaurant_id not in self.restaurants:
            raise KeyError(ing.restaurant_id)
        self.ingredients[ing.id] = ing
        if ing.on_hand > 0:
            self.adjustments.append(InventoryAdjustment(
                restaurant_id=ing.restaurant_id, ingredient_id=ing.id, delta=ing.on_hand,
                on_hand_after=ing.on_hand, reason="restock", note="Opening stock", at=self.clock()))
        return ing

    def update(self, restaurant_id: str, ingredient_id: str, fields: dict) -> Ingredient:
        """Edit name/unit/thresholds. Stock levels change via restock/waste/count."""
        ing = self.get(restaurant_id, ingredient_id)
        for key in ("name", "unit", "low_threshold", "par", "daily_usage"):
            if key in fields:
                setattr(ing, key, fields[key])
        return ing

    def delete(self, restaurant_id: str, ingredient_id: str) -> None:
        self.get(restaurant_id, ingredient_id)
        del self.ingredients[ingredient_id]
        for item in self.restaurants[restaurant_id].menu:
            item.recipe.pop(ingredient_id, None)
        self.refresh_availability(restaurant_id)

    # ---- forecast ------------------------------------------------------

    def usage_per_hour(self, ing: Ingredient) -> float:
        since = self.clock() - OBSERVED_WINDOW
        observed = sum(
            -a.delta for a in self.adjustments
            if a.ingredient_id == ing.id and a.reason == "order" and a.at >= since
        )
        observed_rate = observed / (OBSERVED_WINDOW.total_seconds() / 3600)
        return max(ing.daily_usage / 24, observed_rate)

    def status(self, ing: Ingredient) -> str:
        if ing.on_hand <= EPS:
            return "out"
        return "low" if ing.on_hand <= ing.low_threshold else "ok"

    def view(self, ing: Ingredient) -> dict:
        """Ingredient plus status, forecast and reorder suggestion."""
        rate = self.usage_per_hour(ing)
        hours_left = ing.on_hand / rate if rate > 0 else None
        portions = [
            int((ing.on_hand + EPS) // qty)
            for m in self.restaurants[ing.restaurant_id].menu
            if (qty := m.recipe.get(ing.id))
        ]
        return {
            **ing.model_dump(mode="json"),
            "status": self.status(ing),
            "usage_per_hour": round(rate, 3),
            "hours_left": round(hours_left, 1) if hours_left is not None else None,
            "runs_out_at": (self.clock() + timedelta(hours=hours_left)).isoformat() if hours_left is not None else None,
            "reorder_qty": round(max(0.0, ing.par - ing.on_hand), 3),
            "portions_left": min(portions) if portions else None,
            "used_by": self.used_by(ing),
        }

    def views(self, restaurant_id: str) -> list[dict]:
        order = {"out": 0, "low": 1, "ok": 2}
        return sorted(
            (self.view(i) for i in self.for_restaurant(restaurant_id)),
            key=lambda v: (order[v["status"]], v["hours_left"] if v["hours_left"] is not None else 1e9, v["name"]),
        )
