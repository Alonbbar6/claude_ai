"""Kitchen ready-time model: when will the food come out?

Quantile gradient boosting predicts a range instead of a single number:

  * p50 – most likely ready time
  * p75 – what pickups are planned against
  * p90 – almost surely ready by

Planning against p75 rather than p50 trades a minute or two of food sitting on
the counter for rarely making the customer stand around waiting.

Also used by delivery dispatch (p50) to time couriers.
"""

from __future__ import annotations

import logging
import pickle
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.model_selection import train_test_split

from app.prediction.features import is_rush_hour

log = logging.getLogger(__name__)

MODEL_PATH = Path(__file__).resolve().parents[2] / "models" / "ready.pkl"

FEATURE_NAMES = ["prep_time_min", "item_count", "restaurant_busy", "hour", "is_rush_hour", "is_weekend"]
QUANTILES = (0.5, 0.75, 0.9)


@dataclass
class ReadyEstimate:
    """Minutes from now until the food is ready, at three confidence levels."""

    p50: float
    p75: float
    p90: float


def ready_features(*, prep_time_min: float, item_count: int, restaurant_busy: float, when: datetime) -> list[float]:
    return [
        float(prep_time_min),
        float(item_count),
        float(restaurant_busy),
        float(when.hour),
        float(is_rush_hour(when.hour)),
        float(when.weekday() >= 5),
    ]


def true_ready_minutes(x: list[float], rng: np.random.Generator) -> float:
    """Synthetic ground truth (unknown to the model). Right-skewed: kitchens
    run late far more often than early."""
    prep, items, busy, _hour, rush, weekend = x
    base = prep + 1.2 * items + 1.8 * busy + 2.0 * rush + 1.0 * weekend
    return max(4.0, base + rng.normal(0, 1.5) + rng.exponential(1.5))


def generate(n: int = 5000, seed: int = 7) -> tuple[np.ndarray, np.ndarray]:
    rng = np.random.default_rng(seed)
    start = datetime(2026, 1, 1)
    X, y = [], []
    for _ in range(n):
        x = ready_features(
            prep_time_min=float(rng.choice([2, 3, 5, 8, 10, 12, 15, 18, 20, 22, 25, 30])),
            item_count=int(rng.integers(1, 7)),
            restaurant_busy=float(rng.integers(0, 10)),
            when=start + timedelta(minutes=int(rng.integers(0, 60 * 24 * 90))),
        )
        X.append(x)
        y.append(true_ready_minutes(x, rng))
    return np.array(X), np.array(y)


class ReadyTimePredictor:
    def __init__(self) -> None:
        self.models: dict[float, GradientBoostingRegressor] = {}
        self.metrics: dict[str, float] = {}

    def train(self, n: int = 5000, seed: int = 7) -> dict[str, float]:
        X, y = generate(n=n, seed=seed)
        Xtr, Xte, ytr, yte = train_test_split(X, y, test_size=0.2, random_state=seed)
        self.models = {
            q: GradientBoostingRegressor(
                loss="quantile", alpha=q, n_estimators=200, max_depth=3,
                learning_rate=0.05, random_state=seed,
            ).fit(Xtr, ytr)
            for q in QUANTILES
        }
        pred = self._raw(Xte)
        self.metrics = {
            "ready_mae_p50_min": float(np.mean(np.abs(pred[:, 0] - yte))),
            # Share of orders actually ready by each quantile; should be ~0.75 / ~0.9.
            "ready_p75_coverage": float(np.mean(yte <= pred[:, 1])),
            "ready_p90_coverage": float(np.mean(yte <= pred[:, 2])),
            "ready_train_rows": int(len(Xtr)),
        }
        log.info("Ready-time model trained: %s", self.metrics)
        return self.metrics

    def _raw(self, X: np.ndarray) -> np.ndarray:
        # Independently fitted quantiles can cross; sorting restores order.
        return np.sort(np.column_stack([self.models[q].predict(X) for q in QUANTILES]), axis=1)

    def save(self, path: Path = MODEL_PATH) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as fh:
            pickle.dump({"models": self.models, "metrics": self.metrics}, fh)

    def load(self, path: Path = MODEL_PATH) -> bool:
        if not path.exists():
            return False
        with path.open("rb") as fh:
            blob = pickle.load(fh)
        self.models, self.metrics = blob["models"], blob.get("metrics", {})
        return True

    def load_or_train(self, path: Path = MODEL_PATH) -> None:
        if not self.load(path):
            self.train()
            self.save(path)

    def predict(
        self,
        *,
        prep_time_min: float,
        item_count: int,
        restaurant_busy: float,
        when: datetime,
        elapsed_min: float = 0.0,
    ) -> ReadyEstimate:
        """Minutes from now until ready. ``elapsed_min`` is how long the
        kitchen has had the order already."""
        assert self.models, "not trained"
        x = np.array([ready_features(
            prep_time_min=prep_time_min, item_count=item_count,
            restaurant_busy=restaurant_busy, when=when,
        )])
        q50, q75, q90 = (float(v) for v in self._raw(x)[0])
        # Once past the median the kitchen is running late; keep part of the
        # spread instead of claiming the food is ready this instant.
        r50 = max(q50 - elapsed_min, 1.0)
        r75 = max(q75 - elapsed_min, r50 + (q75 - q50) * 0.5)
        r90 = max(q90 - elapsed_min, r75 + (q90 - q75) * 0.5)
        return ReadyEstimate(round(r50, 1), round(r75, 1), round(r90, 1))
