from datetime import datetime

import pytest

from app.prediction.ready import ReadyTimePredictor

WHEN = datetime(2026, 3, 4, 15, 0)  # weekday, off-peak


@pytest.fixture(scope="module")
def ready():
    p = ReadyTimePredictor()
    p.train(n=3000, seed=11)
    return p


def _predict(p, **kw):
    base = dict(prep_time_min=15, item_count=2, restaurant_busy=2, when=WHEN)
    base.update(kw)
    return p.predict(**base)


def test_quantiles_are_calibrated(ready):
    m = ready.metrics
    assert m["ready_mae_p50_min"] < 2.5
    # Quantile models should cover roughly their nominal share of orders.
    assert 0.65 <= m["ready_p75_coverage"] <= 0.85
    assert 0.82 <= m["ready_p90_coverage"] <= 0.96


def test_quantiles_are_ordered(ready):
    for busy in range(0, 10, 3):
        e = _predict(ready, restaurant_busy=busy)
        assert 0 < e.p50 <= e.p75 <= e.p90


def test_busier_kitchen_and_bigger_order_take_longer(ready):
    assert _predict(ready, restaurant_busy=8).p50 > _predict(ready, restaurant_busy=0).p50
    assert _predict(ready, item_count=6).p50 > _predict(ready, item_count=1).p50


def test_elapsed_time_shrinks_remaining(ready):
    fresh = _predict(ready)
    later = _predict(ready, elapsed_min=8)
    assert later.p50 < fresh.p50


def test_running_late_never_claims_ready_now(ready):
    # Way past every quantile: still predict a little time left, still ordered.
    late = _predict(ready, elapsed_min=120)
    assert late.p50 >= 1.0
    assert late.p50 <= late.p75 <= late.p90


def test_save_and_load(ready, tmp_path):
    path = tmp_path / "ready.pkl"
    ready.save(path)
    fresh = ReadyTimePredictor()
    assert fresh.load(path)
    assert _predict(fresh) == _predict(ready)
