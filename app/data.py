"""Seed data: a few restaurants and users so the app is usable immediately."""

from app.models import Channel, Courier, MenuItem, NotificationPreferences, Restaurant, User

RESTAURANTS: dict[str, Restaurant] = {
    r.id: r
    for r in [
        Restaurant(
            id="rest_sushi",
            name="Sakura Sushi",
            cuisine="Japanese",
            lat=25.7617,
            lng=-80.1918,
            avg_prep_min=18,
            menu=[
                MenuItem(id="sushi_1", name="Salmon Roll", price=11.5),
                MenuItem(id="sushi_2", name="Tuna Nigiri", price=9.0),
                MenuItem(id="sushi_3", name="Miso Soup", price=4.0),
            ],
        ),
        Restaurant(
            id="rest_pizza",
            name="Napoli Pizza",
            cuisine="Italian",
            lat=25.7743,
            lng=-80.1937,
            avg_prep_min=22,
            menu=[
                MenuItem(id="pizza_1", name="Margherita", price=13.0),
                MenuItem(id="pizza_2", name="Pepperoni", price=15.0),
                MenuItem(id="pizza_3", name="Garlic Knots", price=6.5),
            ],
        ),
        Restaurant(
            id="rest_burger",
            name="Grill House",
            cuisine="American",
            lat=25.7907,
            lng=-80.1300,
            avg_prep_min=12,
            menu=[
                MenuItem(id="burger_1", name="Classic Burger", price=10.0),
                MenuItem(id="burger_2", name="Fries", price=4.5),
                MenuItem(id="burger_3", name="Milkshake", price=5.5),
            ],
        ),
    ]
}

COURIERS: dict[str, Courier] = {
    c.id: c
    for c in [
        Courier(id="cour_maria", name="Maria", lat=25.7700, lng=-80.1950),
        Courier(id="cour_dev", name="Dev", lat=25.7850, lng=-80.1400),
        Courier(id="cour_lee", name="Lee", lat=25.7550, lng=-80.2100),
    ]
}

USERS: dict[str, User] = {
    u.id: u
    for u in [
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
}
