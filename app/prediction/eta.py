"""ETA prediction and delay-risk scoring.

Two models:
  * ``GradientBoostingRegressor`` — predicts total minutes from order placed
    to delivered.
  * ``GradientBoostingClassifier`` — predicts the probability that the order
    arrives > 10 minutes later than expected (the "delay risk").

Models are trained on synthetic history at startup and cached to disk so
restarts are fast. Delete ``models/eta.pkl`` to force retraining.
"""

from __future__ import annotations

import logging
import pickle
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
from sklearn.ensemble import GradientBoostingClassifier, GradientBoostingRegressor
from sklearn.metrics import mean_absolute_error, roc_auc_score
from sklearn.model_selection import train_test_split

from app.models import EtaPrediction, OrderStatus
from app.prediction import synthetic
from app.prediction.features import build_features, to_vector

log = logging.getLogger(__name__)

MODEL_PATH = Path(__file__).resolve().parents[2] / "models" / "eta.pkl"

# Fraction of the end-to-end ETA that remains once an order reaches a stage.
# Lets us re-estimate "minutes remaining" without a separate model per stage.
REMAINING_FRACTION = {
    OrderStatus.PLACED: 1.0,
    OrderStatus.CONFIRMED: 0.95,
    OrderStatus.PREPARING: 0.75,
    OrderStatus.COURIER_DISPATCHED: 0.55,
    OrderStatus.PICKED_UP: 0.35,
    OrderStatus.DELIVERED: 0.0,
    OrderStatus.CANCELLED: 0.0,
}


class EtaPredictor:
    def __init__(self) -> None:
        self.regressor: GradientBoostingRegressor | None = None
        self.classifier: GradientBoostingClassifier | None = None
        self.metrics: dict[str, float] = {}

    # ---- training -----------------------------------------------------

    def train(self, n: int = 6000, seed: int = 42) -> dict[str, float]:
        X, y_min, y_late = synthetic.generate(n=n, seed=seed)
        Xtr, Xte, ytr, yte, ltr, lte = train_test_split(
            X, y_min, y_late, test_size=0.2, random_state=seed
        )
        self.regressor = GradientBoostingRegressor(
            n_estimators=300, max_depth=3, learning_rate=0.05, random_state=seed
        ).fit(Xtr, ytr)
        self.classifier = GradientBoostingClassifier(
            n_estimators=200, max_depth=3, learning_rate=0.05, random_state=seed
        ).fit(Xtr, ltr)

        self.metrics = {
            "eta_mae_min": float(mean_absolute_error(yte, self.regressor.predict(Xte))),
            "delay_auc": float(
                roc_auc_score(lte, self.classifier.predict_proba(Xte)[:, 1])
            ),
            "train_rows": int(len(Xtr)),
        }
        log.info("ETA model trained: %s", self.metrics)
        return self.metrics

    def save(self, path: Path = MODEL_PATH) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as fh:
            pickle.dump(
                {"reg": self.regressor, "clf": self.classifier, "metrics": self.metrics},
                fh,
            )

    def load(self, path: Path = MODEL_PATH) -> bool:
        if not path.exists():
            return False
        with path.open("rb") as fh:
            blob = pickle.load(fh)
        self.regressor, self.classifier = blob["reg"], blob["clf"]
        self.metrics = blob.get("metrics", {})
        return True

    def load_or_train(self, path: Path = MODEL_PATH) -> None:
        if not self.load(path):
            self.train()
            self.save(path)

    # ---- inference ----------------------------------------------------

    def predict(
        self,
        *,
        distance_km: float,
        travel_time_min: float,
        prep_time_min: float,
        item_count: int,
        when: datetime,
        raining: bool,
        courier_load: float,
        restaurant_busy: float,
        status: OrderStatus = OrderStatus.PLACED,
        elapsed_min: float = 0.0,
    ) -> EtaPrediction:
        """Predict minutes remaining until delivery for an order in ``status``.

        ``travel_time_min`` is the restaurant->customer driving time from the
        maps provider. ``elapsed_min`` is how long the order has been open; if
        the order is already past its full predicted time we never return a
        negative ETA.
        """
        assert self.regressor is not None and self.classifier is not None, "not trained"
        features = build_features(
            distance_km=distance_km,
            travel_time_min=travel_time_min,
            prep_time_min=prep_time_min,
            item_count=item_count,
            when=when,
            raining=raining,
            courier_load=courier_load,
            restaurant_busy=restaurant_busy,
        )
        x = np.array([to_vector(features)])
        total = float(self.regressor.predict(x)[0])
        risk = float(self.classifier.predict_proba(x)[0, 1])

        remaining = total * REMAINING_FRACTION[status]
        # If elapsed already exceeds what the stage "should" have consumed,
        # push the estimate out rather than pretending the order is on time.
        overrun = max(0.0, elapsed_min - total * (1 - REMAINING_FRACTION[status]))
        remaining = max(1.0, remaining + overrun * 0.5)

        return EtaPrediction(
            eta_minutes=round(remaining, 1),
            eta_at=when + timedelta(minutes=remaining),
            delay_risk=round(risk, 3),
            features=features,
        )

    def feature_importance(self) -> dict[str, float]:
        assert self.regressor is not None, "not trained"
        from app.prediction.features import FEATURE_NAMES

        return {
            name: round(float(v), 4)
            for name, v in sorted(
                zip(FEATURE_NAMES, self.regressor.feature_importances_),
                key=lambda kv: -kv[1],
            )
        }
