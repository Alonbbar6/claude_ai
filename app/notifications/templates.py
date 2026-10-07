"""Message templates keyed by notification kind."""

from __future__ import annotations

from app.models import OrderStatus

# kind -> (title, body template, urgent)
TEMPLATES: dict[str, tuple[str, str, bool]] = {
    OrderStatus.PLACED.value: (
        "Order received",
        "Thanks {user}! {restaurant} has your order. Estimated arrival: {eta_min} min.",
        False,
    ),
    OrderStatus.CONFIRMED.value: (
        "Order confirmed",
        "{restaurant} confirmed your order and will start cooking shortly.",
        False,
    ),
    OrderStatus.PREPARING.value: (
        "Being prepared",
        "{restaurant} is preparing your food. About {eta_min} min to go.",
        False,
    ),
    OrderStatus.COURIER_DISPATCHED.value: (
        "Courier on the way to the restaurant",
        "{courier} is heading to {restaurant}, timed to arrive as your food is ready "
        "(pickup in about {pickup_min} min).",
        False,
    ),
    OrderStatus.PICKED_UP.value: (
        "On the way",
        "Your courier picked up your order and is heading to you. ETA {eta_min} min.",
        True,
    ),
    OrderStatus.DELIVERED.value: (
        "Delivered",
        "Enjoy your meal from {restaurant}! Tap to rate your order.",
        True,
    ),
    OrderStatus.CANCELLED.value: (
        "Order cancelled",
        "Your order from {restaurant} was cancelled. You will not be charged.",
        True,
    ),
    "delayed": (
        "Running late",
        "Sorry, your order from {restaurant} is running about {delay_min} min "
        "behind. New ETA: {eta_min} min.",
        True,
    ),
    "high_delay_risk": (
        "Heads up",
        "Demand is high right now; your {restaurant} order may take longer than usual.",
        False,
    ),
}


def render(kind: str, **ctx: object) -> tuple[str, str, bool]:
    title, body, urgent = TEMPLATES[kind]
    return title, body.format(**ctx), urgent
