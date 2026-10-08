"""Restaurant groups: a chain or owner running several locations.

A group is a thin layer over restaurants: a restaurant carries a ``group_id``,
and the group views aggregate what the per-restaurant services already know
(stock, alerts, orders), so an owner sees every location at once and can spot
stock that could move between kitchens instead of waiting for a delivery.
"""

from __future__ import annotations

from typing import Iterable

from pydantic import BaseModel, Field

from app.inventory import InventoryService
from app.models import CLOSED, Order, OrderStatus, Restaurant, RestaurantGroup

EPS = 1e-9
STATUS_RANK = {"out": 0, "low": 1, "ok": 2}


class GroupIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    owner: str = Field(default="", max_length=80)
    description: str = Field(default="", max_length=300)


class GroupUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=80)
    owner: str | None = Field(default=None, max_length=80)
    description: str | None = Field(default=None, max_length=300)


class GroupService:
    def __init__(self, groups: dict[str, RestaurantGroup], restaurants: dict[str, Restaurant],
                 inventory: InventoryService):
        self.groups = groups
        self.restaurants = restaurants
        self.stock = inventory   # not `inventory`: that name is the group-wide view below

    # ---- lookups -----------------------------------------------------

    def _g(self, group_id: str) -> RestaurantGroup:
        return self.groups[group_id]  # KeyError -> 404

    def locations(self, group_id: str) -> list[Restaurant]:
        return [r for r in self.restaurants.values() if r.group_id == group_id]

    def view(self, group: RestaurantGroup) -> dict:
        locs = self.locations(group.id)
        return {
            **group.model_dump(mode="json"),
            "location_count": len(locs),
            "restaurants": [
                {"id": r.id, "name": r.name, "cuisine": r.cuisine, "address": r.address, "phone": r.phone}
                for r in locs
            ],
        }

    def list(self) -> list[dict]:
        return [self.view(g) for g in self.groups.values()]

    def get(self, group_id: str) -> dict:
        return self.view(self._g(group_id))

    # ---- group CRUD ----------------------------------------------------

    def create(self, req: GroupIn) -> dict:
        group = RestaurantGroup(**req.model_dump())
        self.groups[group.id] = group
        return self.view(group)

    def update(self, group_id: str, fields: dict) -> dict:
        group = self._g(group_id)
        for key, value in fields.items():
            setattr(group, key, value)
        return self.view(group)

    def delete(self, group_id: str) -> None:
        """Deleting a group leaves its restaurants in place, just ungrouped."""
        self._g(group_id)
        for r in self.locations(group_id):
            r.group_id = None
        del self.groups[group_id]

    # ---- membership ----------------------------------------------------

    def add_restaurant(self, group_id: str, restaurant_id: str) -> dict:
        """A restaurant belongs to at most one group; adding moves it."""
        group = self._g(group_id)
        self.restaurants[restaurant_id].group_id = group.id
        return self.view(group)

    def remove_restaurant(self, group_id: str, restaurant_id: str) -> dict:
        group = self._g(group_id)
        r = self.restaurants[restaurant_id]
        if r.group_id != group.id:
            raise ValueError(f"{r.name} is not in {group.name}")
        r.group_id = None
        return self.view(group)

    # ---- group-wide views ------------------------------------------------

    def inventory(self, group_id: str) -> dict:
        """Stock across locations, matched by ingredient name and unit, with a
        transfer suggestion wherever one kitchen is short and another holds
        more than its par level."""
        group = self._g(group_id)
        rows: dict[tuple[str, str], dict] = {}
        for r in self.locations(group.id):
            for v in self.stock.views(r.id):
                key = (v["name"].casefold(), v["unit"])
                row = rows.setdefault(key, {"name": v["name"], "unit": v["unit"], "total_on_hand": 0.0,
                                            "status": "ok", "locations": [], "transfer": None})
                row["total_on_hand"] = round(row["total_on_hand"] + v["on_hand"], 3)
                if STATUS_RANK[v["status"]] < STATUS_RANK[row["status"]]:
                    row["status"] = v["status"]
                row["locations"].append({
                    "restaurant_id": r.id, "restaurant": r.name, "ingredient_id": v["id"],
                    "on_hand": v["on_hand"], "low_threshold": v["low_threshold"], "par": v["par"],
                    "status": v["status"], "hours_left": v["hours_left"], "portions_left": v["portions_left"],
                })
        for row in rows.values():
            row["transfer"] = self._transfer(row)
        ingredients = sorted(rows.values(), key=lambda x: (STATUS_RANK[x["status"]], x["name"]))
        return {
            "group_id": group.id, "name": group.name,
            "summary": {
                "locations": len(self.locations(group.id)),
                "ingredients": len(ingredients),
                "out": sum(1 for x in ingredients if x["status"] == "out"),
                "low": sum(1 for x in ingredients if x["status"] == "low"),
                "transfers": sum(1 for x in ingredients if x["transfer"]),
            },
            "ingredients": ingredients,
        }

    @staticmethod
    def _transfer(row: dict) -> dict | None:
        short = [l for l in row["locations"] if l["status"] != "ok"]
        donors = [l for l in row["locations"] if l["status"] == "ok" and l["on_hand"] - l["par"] > EPS]
        if not short or not donors:
            return None
        to = min(short, key=lambda l: l["on_hand"] - l["low_threshold"])
        frm = max(donors, key=lambda l: l["on_hand"] - l["par"])
        qty = round(min(frm["on_hand"] - frm["par"], to["par"] - to["on_hand"]), 3)
        if qty <= EPS:
            return None
        return {
            "from_restaurant_id": frm["restaurant_id"], "from": frm["restaurant"],
            "to_restaurant_id": to["restaurant_id"], "to": to["restaurant"],
            "quantity": qty, "unit": row["unit"],
            "reason": (f"{to['restaurant']} is {to['status']} on {row['name']} ({to['on_hand']} {row['unit']}, alert at "
                       f"{to['low_threshold']}); {frm['restaurant']} holds {frm['on_hand']} {row['unit']}, "
                       f"{round(frm['on_hand'] - frm['par'], 3)} above its par of {frm['par']}."),
        }

    def alerts(self, group_id: str) -> list[dict]:
        group = self._g(group_id)
        out = []
        for r in self.locations(group.id):
            for a in self.stock.alerts_for(r.id):
                out.append({**a.model_dump(mode="json"), "restaurant": r.name})
        return sorted(out, key=lambda a: a.get("at") or "", reverse=True)

    def orders(self, group_id: str, orders: Iterable[Order], open_only: bool = False) -> list[Order]:
        ids = {r.id for r in self.locations(self._g(group_id).id)}
        picked = [o for o in orders if o.restaurant_id in ids and not (open_only and o.status in CLOSED)]
        return sorted(picked, key=lambda o: o.created_at, reverse=True)

    def sales(self, group_id: str, orders: Iterable[Order]) -> dict:
        """Orders and revenue per location (cancelled orders excluded)."""
        group = self._g(group_id)
        per: dict[str, dict] = {
            r.id: {"restaurant_id": r.id, "restaurant": r.name, "orders": 0, "open": 0, "revenue": 0.0}
            for r in self.locations(group.id)
        }
        for o in orders:
            loc = per.get(o.restaurant_id)
            if loc is None or o.status == OrderStatus.CANCELLED:
                continue
            prices = {m.id: m.price for m in self.restaurants[o.restaurant_id].menu}
            loc["orders"] += 1
            loc["open"] += o.status not in CLOSED
            loc["revenue"] = round(loc["revenue"] + sum(prices.get(l.item_id, 0.0) * l.quantity for l in o.lines), 2)
        locations = sorted(per.values(), key=lambda x: -x["revenue"])
        return {
            "group_id": group.id, "name": group.name,
            "totals": {"orders": sum(x["orders"] for x in locations), "open": sum(x["open"] for x in locations),
                       "revenue": round(sum(x["revenue"] for x in locations), 2)},
            "locations": locations,
        }
