"""Feature engineering shared by training and inference.

Keeping feature construction in one place guarantees the model sees the same
columns, in the same order, at train and predict time.
"""

from __future__ import annotations

import math
from datetime import datetime

FEATURE_NAMES = [
    "distance_km",
    "travel_time_min",  # from Google Distance Matrix (traffic-aware) or fallback
    "prep_time_min",
    "item_count",
    "hour",
    "is_weekend",
    "raining",
    "courier_load",
    "restaurant_busy",
    "is_rush_hour",
]


def haversine_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def is_rush_hour(hour: int) -> bool:
    return 11 <= hour <= 13 or 18 <= hour <= 20


def build_features(
    *,
    distance_km: float,
    travel_time_min: float,
    prep_time_min: float,
    item_count: int,
    when: datetime,
    raining: bool,
    courier_load: float,
    restaurant_busy: float,
) -> dict[str, float]:
    """Return an ordered feature dict. ``courier_load`` is active orders per
    courier; ``restaurant_busy`` is the restaurant's open-order count."""
    return {
        "distance_km": float(distance_km),
        "travel_time_min": float(travel_time_min),
        "prep_time_min": float(prep_time_min),
        "item_count": float(item_count),
        "hour": float(when.hour),
        "is_weekend": float(when.weekday() >= 5),
        "raining": float(raining),
        "courier_load": float(courier_load),
        "restaurant_busy": float(restaurant_busy),
        "is_rush_hour": float(is_rush_hour(when.hour)),
    }


def to_vector(features: dict[str, float]) -> list[float]:
    return [features[name] for name in FEATURE_NAMES]
