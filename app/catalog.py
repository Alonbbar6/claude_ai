"""Menu catalog management for restaurant staff: categories and items.

Edits apply to the live menu customers see. Recipes link items to inventory
ingredients and are validated against the restaurant's own stock list.
"""

from __future__ import annotations

from pydantic import BaseModel, Field, field_validator

from app.inventory import InventoryService
from app.models import MenuCategory, MenuItem, Restaurant, recipe_from_wire


class CategoryIn(BaseModel):
    name: str = Field(min_length=1, max_length=40)


class CategoryUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=40)


class Recipe(BaseModel):
    recipe: dict[str, float] = Field(default_factory=dict)

    _recipe_in = field_validator("recipe", mode="before")(classmethod(lambda cls, v: recipe_from_wire(v)))

    @field_validator("recipe")
    @classmethod
    def positive(cls, v: dict[str, float]) -> dict[str, float]:
        if any(q <= 0 for q in v.values()):
            raise ValueError("recipe quantities must be positive")
        return v


class MenuItemIn(Recipe):
    name: str = Field(min_length=1, max_length=80)
    price: float = Field(gt=0, le=1000)
    description: str = Field(default="", max_length=300)
    category_id: str | None = None
    available: bool = True


class MenuItemUpdate(Recipe):
    """Partial update; only fields that are sent change."""

    name: str | None = Field(default=None, min_length=1, max_length=80)
    price: float | None = Field(default=None, gt=0, le=1000)
    description: str | None = Field(default=None, max_length=300)
    category_id: str | None = None
    available: bool | None = None
    recipe: dict[str, float] | None = None  # type: ignore[assignment]

    @field_validator("recipe")
    @classmethod
    def positive(cls, v):
        if v is not None and any(q <= 0 for q in v.values()):
            raise ValueError("recipe quantities must be positive")
        return v


class CatalogService:
    def __init__(self, restaurants: dict[str, Restaurant], inventory: InventoryService):
        self.restaurants = restaurants
        self.inventory = inventory

    def _r(self, restaurant_id: str) -> Restaurant:
        return self.restaurants[restaurant_id]  # KeyError -> 404

    def menu(self, restaurant_id: str) -> dict:
        r = self._r(restaurant_id)
        return {
            "categories": sorted(r.categories, key=lambda c: c.sort),
            "items": r.menu,
        }

    # ---- categories ----------------------------------------------------

    def add_category(self, restaurant_id: str, req: CategoryIn) -> MenuCategory:
        r = self._r(restaurant_id)
        cat = MenuCategory(name=req.name.strip(), sort=max((c.sort for c in r.categories), default=-1) + 1)
        r.categories.append(cat)
        return cat

    def update_category(self, restaurant_id: str, category_id: str, req: CategoryUpdate) -> MenuCategory:
        cat = self._category(restaurant_id, category_id)
        if req.name is not None:
            cat.name = req.name.strip()
        return cat

    def delete_category(self, restaurant_id: str, category_id: str) -> None:
        """Items in it stay on the menu, uncategorised."""
        r = self._r(restaurant_id)
        cat = self._category(restaurant_id, category_id)
        r.categories.remove(cat)
        for item in r.menu:
            if item.category_id == category_id:
                item.category_id = None

    def reorder_categories(self, restaurant_id: str, ids: list[str]) -> list[MenuCategory]:
        r = self._r(restaurant_id)
        if sorted(ids) != sorted(c.id for c in r.categories):
            raise ValueError("send every category id exactly once")
        by_id = {c.id: c for c in r.categories}
        for i, cid in enumerate(ids):
            by_id[cid].sort = i
        return sorted(r.categories, key=lambda c: c.sort)

    def _category(self, restaurant_id: str, category_id: str) -> MenuCategory:
        for c in self._r(restaurant_id).categories:
            if c.id == category_id:
                return c
        raise KeyError(category_id)

    # ---- items ---------------------------------------------------------

    def add_item(self, restaurant_id: str, req: MenuItemIn) -> MenuItem:
        r = self._r(restaurant_id)
        self._validate_refs(restaurant_id, req.category_id, req.recipe)
        item = MenuItem(
            name=req.name.strip(), price=round(req.price, 2), description=req.description.strip(),
            category_id=req.category_id, available=req.available, recipe=req.recipe,
        )
        r.menu.append(item)
        self.inventory.refresh_availability(restaurant_id)
        return item

    def update_item(self, restaurant_id: str, item_id: str, req: MenuItemUpdate) -> MenuItem:
        item = self._item(restaurant_id, item_id)
        fields = req.model_dump(exclude_unset=True)
        self._validate_refs(restaurant_id, fields.get("category_id"), fields.get("recipe") or {})
        for key, value in fields.items():
            if key == "price":
                value = round(value, 2)
            elif key in ("name", "description"):
                value = value.strip()
            setattr(item, key, value)
        self.inventory.refresh_availability(restaurant_id)
        return item

    def delete_item(self, restaurant_id: str, item_id: str) -> None:
        r = self._r(restaurant_id)
        r.menu.remove(self._item(restaurant_id, item_id))

    def _item(self, restaurant_id: str, item_id: str) -> MenuItem:
        for m in self._r(restaurant_id).menu:
            if m.id == item_id:
                return m
        raise KeyError(item_id)

    def _validate_refs(self, restaurant_id: str, category_id: str | None, recipe: dict[str, float]) -> None:
        if category_id is not None:
            try:
                self._category(restaurant_id, category_id)
            except KeyError:
                raise ValueError(f"unknown category {category_id}") from None
        for ing_id in recipe:
            try:
                self.inventory.get(restaurant_id, ing_id)
            except KeyError:
                raise ValueError(f"unknown ingredient {ing_id}") from None
