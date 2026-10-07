"""Pickup planner: leave so you arrive as the food comes out."""

from datetime import datetime, timedelta, timezone

from app.maps import RouteEstimate
from app.models import TravelMode
from app.pickup import ARRIVAL_OVERHEAD_MIN, FRESH_HOLD_MIN, plan_pickup
from app.prediction.ready import ReadyEstimate

NOW = datetime(2026, 3, 4, 15, 0, tzinfo=timezone.utc)
READY = ReadyEstimate(p50=20.0, p75=23.0, p90=27.0)


def route(minutes, km=3.0):
    return RouteEstimate(distance_km=km, duration_min=minutes, source="test")


def test_close_by_waits_and_arrives_at_p75():
    plan = plan_pickup(now=NOW, route=route(8), mode=TravelMode.DRIVING, ready=READY)
    trip = 8 + ARRIVAL_OVERHEAD_MIN[TravelMode.DRIVING]
    assert plan.decision == "wait"
    assert plan.trip_min == trip
    assert plan.target_arrival_at == NOW + timedelta(minutes=23)
    assert plan.leave_at == NOW + timedelta(minutes=23 - trip)
    assert plan.arrive_at == plan.target_arrival_at
    # Arriving at p75: food sits ~3 min (fresh), customer doesn't wait (at the median).
    assert plan.food_wait_min == 3.0 and plan.your_wait_min == 0
    assert "Leave in 13 min" in plan.message


def test_far_away_leaves_now_and_reports_food_wait():
    plan = plan_pickup(now=NOW, route=route(35, km=20), mode=TravelMode.DRIVING, ready=READY)
    assert plan.decision == "leave_now"
    assert plan.leave_at == NOW
    assert plan.food_wait_min == 35 + 2 - 20  # arrive at 37 min, ready at 20
    assert plan.food_wait_min > FRESH_HOLD_MIN
    assert "ready about 17 min before you arrive" in plan.message


def test_just_in_time_says_leave_now_without_cold_food_warning():
    plan = plan_pickup(now=NOW, route=route(21), mode=TravelMode.DRIVING, ready=READY)
    assert plan.decision == "leave_now"
    assert plan.food_wait_min <= FRESH_HOLD_MIN
    assert "gets you there as your food is ready" in plan.message


def test_walking_leaves_earlier_than_driving_for_same_distance():
    drive = plan_pickup(now=NOW, route=route(5), mode=TravelMode.DRIVING, ready=READY)
    walk = plan_pickup(now=NOW, route=route(15), mode=TravelMode.WALKING, ready=READY)
    assert walk.leave_at < drive.leave_at
    assert "walk" in walk.message


def test_food_already_ready_means_go_now():
    ready_at = NOW - timedelta(minutes=2)
    plan = plan_pickup(now=NOW, route=route(6), mode=TravelMode.DRIVING, ready=None, actual_ready_at=ready_at)
    assert plan.decision == "ready"
    assert plan.ready_at == ready_at and plan.leave_at == NOW
    assert plan.food_wait_min == 2 + 6 + 2


def test_too_far():
    plan = plan_pickup(now=NOW, route=route(300, km=250), mode=TravelMode.DRIVING, ready=READY)
    assert plan.decision == "too_far"
    assert "too far" in plan.message
