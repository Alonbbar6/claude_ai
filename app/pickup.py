"""Pickup timing: tell the customer when to leave so they arrive as the food
comes out. Too early and they wait at the counter; too late and it goes cold.

Pure function so it's easy to test and reason about:

    target_arrival = kitchen p75 ready time (or actual ready time once known)
    trip           = travel time from the customer's location + parking/walk-in
    leave_at       = target_arrival - trip
"""

from __future__ import annotations

from datetime import datetime, timedelta

from app.maps import RouteEstimate
from app.models import PickupPlan, TravelMode
from app.prediction.ready import ReadyEstimate

# Time from "arrived" to "at the counter".
ARRIVAL_OVERHEAD_MIN = {TravelMode.DRIVING: 2.0, TravelMode.WALKING: 0.5}
# How long food can sit before it's noticeably worse.
FRESH_HOLD_MIN = 5.0
# Beyond this, pickup doesn't make sense.
MAX_PICKUP_KM = 80.0
# Don't say "leave in 0 min"; under this, just say "leave now".
LEAVE_NOW_SLACK_MIN = 0.5


def _mins(delta: timedelta) -> float:
    return delta.total_seconds() / 60


def plan_pickup(
    *,
    now: datetime,
    route: RouteEstimate,
    mode: TravelMode,
    ready: ReadyEstimate | None,
    actual_ready_at: datetime | None = None,
) -> PickupPlan:
    trip = route.duration_min + ARRIVAL_OVERHEAD_MIN[mode]

    if actual_ready_at is not None:
        ready_at = ready_by = target = actual_ready_at
    else:
        assert ready is not None, "need a ready estimate until the food is ready"
        ready_at = now + timedelta(minutes=ready.p50)
        target = now + timedelta(minutes=ready.p75)
        ready_by = now + timedelta(minutes=ready.p90)

    ideal_leave = target - timedelta(minutes=trip)
    if route.distance_km > MAX_PICKUP_KM:
        decision, leave_at = "too_far", now
    elif actual_ready_at is not None:
        decision, leave_at = "ready", now
    elif ideal_leave > now + timedelta(minutes=LEAVE_NOW_SLACK_MIN):
        decision, leave_at = "wait", ideal_leave
    else:
        decision, leave_at = "leave_now", now

    arrive_at = leave_at + timedelta(minutes=trip)
    food_wait = max(0.0, _mins(arrive_at - ready_at))
    your_wait = max(0.0, _mins(ready_at - arrive_at))

    return PickupPlan(
        decision=decision,
        message=_message(decision, _mins(leave_at - now), trip, food_wait, mode, route.distance_km),
        mode=mode,
        distance_km=route.distance_km,
        travel_min=route.duration_min,
        trip_min=round(trip, 1),
        route_source=route.source,
        ready_at=ready_at,
        ready_by=ready_by,
        target_arrival_at=target,
        leave_at=leave_at,
        arrive_at=arrive_at,
        food_wait_min=round(food_wait, 1),
        your_wait_min=round(your_wait, 1),
        computed_at=now,
    )


def _message(decision: str, leave_in: float, trip: float, food_wait: float, mode: TravelMode, km: float) -> str:
    verb = "drive" if mode == TravelMode.DRIVING else "walk"
    trip_s = f"{max(1, round(trip))} min {verb}"
    if decision == "too_far":
        return f"You're {km:.0f} km away, too far for pickup. Try delivery instead."
    if decision == "ready":
        return f"Head over now, it's a {trip_s}."
    if decision == "wait":
        return f"Leave in {max(1, round(leave_in))} min so you arrive as your food comes out ({trip_s})."
    if food_wait > FRESH_HOLD_MIN:
        return f"Leave now. Your food will be ready about {round(food_wait)} min before you arrive."
    return f"Leave now. A {trip_s} gets you there as your food is ready."
