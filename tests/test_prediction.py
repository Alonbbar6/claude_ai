from datetime import datetime

import pytest

from app.models import OrderStatus
from app.prediction.eta import EtaPredictor


@pytest.fixture(scope="module")
def predictor():
    p = EtaPredictor()
    p.train(n=2000, seed=1)
    return p


def _predict(p, **kw):
    base = dict(
        distance_km=3.0, travel_time_min=9.5, prep_time_min=15, item_count=2,
        when=datetime(2026, 3, 4, 15, 0), raining=False,
        courier_load=1.0, restaurant_busy=2,
    )
    base.update(kw)
    return p.predict(**base)


def test_model_quality(predictor):
    assert predictor.metrics["eta_mae_min"] < 5.0
    assert predictor.metrics["delay_auc"] > 0.7


def test_eta_is_reasonable(predictor):
    pred = _predict(predictor)
    assert 15 <= pred.eta_minutes <= 60
    assert 0 <= pred.delay_risk <= 1


def test_longer_distance_means_longer_eta(predictor):
    assert _predict(predictor, distance_km=8, travel_time_min=25).eta_minutes > _predict(predictor, distance_km=1, travel_time_min=3).eta_minutes


def test_rain_raises_eta_and_risk(predictor):
    dry, wet = _predict(predictor, raining=False), _predict(predictor, raining=True)
    assert wet.eta_minutes > dry.eta_minutes
    assert wet.delay_risk >= dry.delay_risk


def test_remaining_eta_shrinks_through_lifecycle(predictor):
    placed = _predict(predictor, status=OrderStatus.PLACED).eta_minutes
    picked = _predict(predictor, status=OrderStatus.PICKED_UP).eta_minutes
    assert picked < placed
    assert placed > 0 and picked > 0


def test_overrun_pushes_eta_out(predictor):
    on_time = _predict(predictor, status=OrderStatus.PREPARING, elapsed_min=0)
    late = _predict(predictor, status=OrderStatus.PREPARING, elapsed_min=60)
    assert late.eta_minutes > on_time.eta_minutes


def test_save_and_load(predictor, tmp_path):
    path = tmp_path / "eta.pkl"
    predictor.save(path)
    fresh = EtaPredictor()
    assert fresh.load(path)
    assert _predict(fresh).eta_minutes == _predict(predictor).eta_minutes
