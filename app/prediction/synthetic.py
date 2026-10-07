"""Synthetic order history used to train the models.

There is no real delivery data in a from-scratch app, so we generate orders
from a plausible generative process. The ground-truth formula below is what
the models have to learn; swap this module for a real data loader later
(e.g. a table of delivered orders with their Google travel-time quotes).
"""

from __future__ import annotations

from datetime import datetime, timedelta

import numpy as np

from app.prediction.features import FEATURE_NAMES, build_features, to_vector

# Delivered more than this many minutes after the quote counts as "late".
LATE_THRESHOLD_MIN = 10.0


def expected_delivery_minutes(f: dict[str, float]) -> float:
    """Noise-free ground truth. The courier's leg is the Google travel time
    (already traffic-aware) plus a handoff buffer; the rest is kitchen and
    dispatch effects."""
    travel = f["travel_time_min"] * 1.1 + 2.0
    prep = f["prep_time_min"] + 1.2 * f["item_count"]
    queue = 1.8 * f["restaurant_busy"]
    dispatch = 2.0 + 4.5 * f["courier_load"]
    weather = 6.0 * f["raining"]
    rush = 4.0 * f["is_rush_hour"]
    weekend = 2.0 * f["is_weekend"]
    return travel + prep + queue + dispatch + weather + rush + weekend


def realised_delivery_minutes(f: dict[str, float], rng: np.random.Generator) -> float:
    base = expected_delivery_minutes(f)
    # Heavy right tail: most orders are on time, some are badly late.
    noise = rng.normal(0, 2.5) + rng.exponential(2.0) * (1 + 1.5 * f["raining"])
    return max(8.0, base + noise)


def generate(n: int = 6000, seed: int = 42) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Return (X, y_minutes, y_late)."""
    rng = np.random.default_rng(seed)
    start = datetime(2026, 1, 1, 0, 0)
    X, y, late = [], [], []
    for _ in range(n):
        when = start + timedelta(minutes=int(rng.integers(0, 60 * 24 * 90)))
        distance = float(rng.gamma(2.0, 1.6))
        # Google's traffic-aware time: ~19 km/h with route/traffic variation.
        travel = distance / 19.0 * 60 * float(rng.lognormal(0.0, 0.25))
        f = build_features(
            distance_km=distance,
            travel_time_min=travel,
            prep_time_min=float(rng.choice([2, 3, 5, 8, 10, 12, 15, 18, 20, 22, 25, 30])),
            item_count=int(rng.integers(1, 7)),
            when=when,
            raining=bool(rng.random() < 0.2),
            courier_load=float(np.clip(rng.normal(1.0, 0.5), 0.1, 3.0)),
            restaurant_busy=float(rng.integers(0, 10)),
        )
        minutes = realised_delivery_minutes(f, rng)
        X.append(to_vector(f))
        y.append(minutes)
        late.append(1.0 if minutes - expected_delivery_minutes(f) > LATE_THRESHOLD_MIN else 0.0)
    return np.array(X), np.array(y), np.array(late)


__all__ = ["generate", "FEATURE_NAMES", "LATE_THRESHOLD_MIN"]
