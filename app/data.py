"""Seed data: restaurants (with categorised menus, recipes and stock), couriers
and users, so the app is usable immediately.

Everything is in memory. ``reset()`` restores the seed in place so the
module-level dicts stay shared with the rest of the app (and tests start clean).
"""

from app.models import (
    Channel,
    Courier,
    Ingredient,
    MenuCategory,
    MenuItem,
    NotificationPreferences,
    Restaurant,
    User,
)


def _restaurants() -> list[Restaurant]:
    return [
        Restaurant(
            id="rest_sushi",
            name="Sakura Sushi",
            cuisine="Japanese",
            lat=25.7617,
            lng=-80.1918,
            avg_prep_min=18,
            categories=[
                MenuCategory(id="cat_sushi_rolls", name="Rolls", sort=0),
                MenuCategory(id="cat_sushi_nigiri", name="Nigiri", sort=1),
                MenuCategory(id="cat_sushi_soup", name="Soups", sort=2),
            ],
            menu=[
                MenuItem(id="sushi_1", name="Salmon Roll", price=11.5, category_id="cat_sushi_rolls",
                         description="Fresh salmon, rice and nori.",
                         recipe={"ing_rice": 0.15, "ing_salmon": 0.08, "ing_nori": 1}),
                MenuItem(id="sushi_2", name="Tuna Nigiri", price=9.0, category_id="cat_sushi_nigiri",
                         description="Two pieces of bluefin tuna over rice.",
                         recipe={"ing_rice": 0.1, "ing_tuna": 0.06}),
                MenuItem(id="sushi_3", name="Miso Soup", price=4.0, category_id="cat_sushi_soup",
                         description="Miso broth, tofu and scallion.",
                         recipe={"ing_miso": 0.03, "ing_tofu": 0.05}),
            ],
        ),
        Restaurant(
            id="rest_pizza",
            name="Napoli Pizza",
            cuisine="Italian",
            lat=25.7743,
            lng=-80.1937,
            avg_prep_min=22,
            categories=[
                MenuCategory(id="cat_pizza_pizzas", name="Pizzas", sort=0),
                MenuCategory(id="cat_pizza_sides", name="Sides", sort=1),
            ],
            menu=[
                MenuItem(id="pizza_1", name="Margherita", price=13.0, category_id="cat_pizza_pizzas",
                         description="Tomato, mozzarella, basil.",
                         recipe={"ing_dough": 1, "ing_mozz": 0.15, "ing_sauce": 0.1}),
                MenuItem(id="pizza_2", name="Pepperoni", price=15.0, category_id="cat_pizza_pizzas",
                         description="Tomato, mozzarella, pepperoni.",
                         recipe={"ing_dough": 1, "ing_mozz": 0.15, "ing_sauce": 0.1, "ing_pepperoni": 0.06}),
                MenuItem(id="pizza_3", name="Garlic Knots", price=6.5, category_id="cat_pizza_sides",
                         description="Six knots with garlic butter.",
                         recipe={"ing_dough": 0.5, "ing_garlic": 0.02}),
            ],
        ),
        Restaurant(
            id="rest_burger",
            name="Grill House",
            cuisine="American",
            lat=25.7907,
            lng=-80.1300,
            avg_prep_min=12,
            categories=[
                MenuCategory(id="cat_grill_burgers", name="Burgers", sort=0),
                MenuCategory(id="cat_grill_sides", name="Sides", sort=1),
                MenuCategory(id="cat_grill_drinks", name="Drinks", sort=2),
            ],
            menu=[
                MenuItem(id="burger_1", name="Classic Burger", price=10.0, category_id="cat_grill_burgers",
                         description="Beef patty, lettuce, tomato, house sauce.",
                         recipe={"ing_bun": 1, "ing_patty": 1}),
                MenuItem(id="burger_2", name="Fries", price=4.5, category_id="cat_grill_sides",
                         description="Hand-cut, sea salt.",
                         recipe={"ing_potato": 0.25}),
                MenuItem(id="burger_3", name="Milkshake", price=5.5, category_id="cat_grill_drinks",
                         description="Vanilla, chocolate or strawberry.",
                         recipe={"ing_icecream": 0.2, "ing_milk": 0.15}),
            ],
        ),
    ]


def _ingredients() -> list[Ingredient]:
    def ing(id, rid, name, unit, on_hand, low, par, daily):
        return Ingredient(id=id, restaurant_id=rid, name=name, unit=unit, on_hand=on_hand,
                          low_threshold=low, par=par, daily_usage=daily)

    return [
        ing("ing_rice", "rest_sushi", "Sushi rice", "kg", 12, 3, 15, 6),
        ing("ing_salmon", "rest_sushi", "Salmon", "kg", 4, 1, 5, 2.5),
        ing("ing_tuna", "rest_sushi", "Tuna", "kg", 1.2, 1, 3, 1.5),  # already low
        ing("ing_nori", "rest_sushi", "Nori", "sheets", 80, 20, 100, 40),
        ing("ing_miso", "rest_sushi", "Miso paste", "kg", 2, 0.5, 3, 0.6),
        ing("ing_tofu", "rest_sushi", "Tofu", "kg", 3, 0.8, 4, 1.2),
        ing("ing_dough", "rest_pizza", "Dough balls", "each", 40, 10, 60, 45),
        ing("ing_mozz", "rest_pizza", "Mozzarella", "kg", 8, 2, 10, 6),
        ing("ing_sauce", "rest_pizza", "Tomato sauce", "L", 6, 1.5, 8, 4),
        ing("ing_pepperoni", "rest_pizza", "Pepperoni", "kg", 0.15, 0.5, 2, 1),  # 2 pizzas left
        ing("ing_garlic", "rest_pizza", "Garlic butter", "kg", 1, 0.2, 1.5, 0.4),
        ing("ing_bun", "rest_burger", "Burger buns", "each", 60, 15, 80, 50),
        ing("ing_patty", "rest_burger", "Beef patties", "each", 14, 15, 80, 50),  # below threshold
        ing("ing_potato", "rest_burger", "Potatoes", "kg", 20, 5, 25, 12),
        ing("ing_icecream", "rest_burger", "Ice cream", "L", 5, 1, 6, 3),
        ing("ing_milk", "rest_burger", "Milk", "L", 6, 1.5, 8, 3),
    ]


def _couriers() -> list[Courier]:
    return [
        Courier(id="cour_maria", name="Maria", lat=25.7700, lng=-80.1950),
        Courier(id="cour_dev", name="Dev", lat=25.7850, lng=-80.1400),
        Courier(id="cour_lee", name="Lee", lat=25.7550, lng=-80.2100),
    ]


def _users() -> list[User]:
    return [
        User(
            id="user_alex",
            name="Alex",
            phone="+15550100",
            email="alex@example.com",
            lat=25.7680,
            lng=-80.2000,
        ),
        User(
            id="user_sam",
            name="Sam",
            phone="+15550101",
            email="sam@example.com",
            lat=25.8100,
            lng=-80.1400,
            prefs=NotificationPreferences(
                channels=[Channel.SMS, Channel.EMAIL, Channel.WEBSOCKET],
                quiet_start=0,
                quiet_end=0,  # quiet hours disabled
            ),
        ),
    ]


RESTAURANTS: dict[str, Restaurant] = {}
COURIERS: dict[str, Courier] = {}
USERS: dict[str, User] = {}


def seed_ingredients() -> list[Ingredient]:
    return _ingredients()


def reset() -> None:
    """Restore the seed data in place."""
    for target, items in ((RESTAURANTS, _restaurants()), (COURIERS, _couriers()), (USERS, _users())):
        target.clear()
        target.update({x.id: x for x in items})


reset()
