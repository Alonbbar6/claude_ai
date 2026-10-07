"""Simulate a pickup order end to end, in real time.

Temporarily adds Miami Dade College (Wolfson Campus) as a restaurant (in memory
only; app/data.py is untouched), places a pickup order from a spot about
--walk-min minutes' walk away, forces the kitchen to finish in --ready-min
minutes, and prints every notification with the time since the order was placed.

    set -a && . ./.env && set +a
    .venv/bin/python scripts/simulate_pickup.py --mode walking --walk-min 5 --ready-min 2
    .venv/bin/python scripts/simulate_pickup.py --mode driving --walk-min 5 --ready-min 2

Uses the Google Routes API when GOOGLE_MAPS_API_KEY is set, else the
straight-line fallback (the output says which).
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import math
import sys
import time
from datetime import timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.maps import LatLng, get_provider  # noqa: E402
from app.models import (  # noqa: E402
    Channel, CreateOrderRequest, Fulfillment, MenuItem, NotificationPreferences,
    OrderLine, OrderStatus, Restaurant, TravelMode, User,
)
from app.notifications.channels import BaseChannel  # noqa: E402
from app.notifications.events import EventBus  # noqa: E402
from app.notifications.service import NotificationService  # noqa: E402
from app.orders import OrderService  # noqa: E402
from app.prediction.eta import EtaPredictor  # noqa: E402
from app.prediction.ready import ReadyEstimate  # noqa: E402

# 300 NE 2nd Ave, Miami, FL 33132 (approximate campus centre).
WOLFSON = Restaurant(
    id="rest_mdc_wolfson",
    name="MDC Wolfson Campus",
    cuisine="Campus",
    lat=25.7776,
    lng=-80.1907,
    avg_prep_min=2,
    menu=[MenuItem(id="mdc_1", name="Cafe Cubano", price=2.5)],
)

T0 = time.monotonic()


def stamp() -> str:
    s = int(time.monotonic() - T0)
    return f"[{s // 60}:{s % 60:02d}]"


class FixedReady:
    """Stands in for the kitchen model: the food is ready exactly N minutes
    after the order is placed, at every confidence level."""

    def __init__(self, minutes: float) -> None:
        self.minutes = minutes

    def predict(self, *, elapsed_min: float = 0.0, **_) -> ReadyEstimate:
        r = max(self.minutes - elapsed_min, 0.1)
        return ReadyEstimate(r, r, r)


class PrintChannel(BaseChannel):
    name = Channel.PUSH

    async def send(self, user: User, n) -> str:
        print(f"{stamp()} PUSH  {n.title}: {n.body}", flush=True)
        return "printed"


async def find_origin(routes, dest: LatLng, walk_min: float) -> tuple[LatLng, float]:
    """A point north of ``dest`` whose walking time is closest to ``walk_min``."""
    best = None
    for metres in range(200, 701, 50):
        p = LatLng(dest.lat + metres / 111_000, dest.lng)
        est = await routes.route(p, dest, mode="walking")
        err = abs(est.duration_min - walk_min)
        if best is None or err < best[0]:
            best = (err, p, est.duration_min)
    return best[1], best[2]


async def main(args) -> None:
    routes = get_provider()
    dest = LatLng(WOLFSON.lat, WOLFSON.lng)
    origin, walk = await find_origin(routes, dest, args.walk_min)
    trip = await routes.route(origin, dest, mode=args.mode)

    user = User(
        id="user_sim", name="Student", phone="+15550199", email="sim@example.com",
        lat=origin.lat, lng=origin.lng,
        prefs=NotificationPreferences(channels=[Channel.PUSH], quiet_start=0, quiet_end=0),
    )
    bus = EventBus()
    NotificationService(bus, {Channel.PUSH: PrintChannel()}, {user.id: user}, {WOLFSON.id: WOLFSON})
    eta = EtaPredictor()
    eta.load_or_train()
    orders = OrderService(
        bus, eta, routes, {user.id: user}, {WOLFSON.id: WOLFSON}, {},
        ready_predictor=FixedReady(args.ready_min), plan_refresh_seconds=args.refresh,
    )

    print(f"Routing: {trip.source}")
    print(f"You are at {origin}, a {walk:.1f} min walk from {WOLFSON.name}")
    print(f"By {args.mode}: {trip.distance_km} km, {trip.duration_min} min")
    print(f"Kitchen forced to finish {args.ready_min} min after ordering\n")

    global T0
    T0 = time.monotonic()
    order = await orders.create(CreateOrderRequest(
        user_id=user.id, restaurant_id=WOLFSON.id, lines=[OrderLine(item_id="mdc_1")],
        fulfillment=Fulfillment.PICKUP, pickup_lat=origin.lat, pickup_lng=origin.lng,
        pickup_mode=TravelMode(args.mode),
    ))
    # create() draws a noisy "real" finish time (min 3 min); pin it.
    orders._actual_ready[order.id] = order.created_at + timedelta(minutes=args.ready_min)
    await orders.refresh_pickup_plan(order)

    last = None
    while order.status not in (OrderStatus.READY, OrderStatus.COLLECTED, OrderStatus.CANCELLED):
        pk = order.pickup
        now = (order.status.value, pk.decision, pk.leave_at.replace(microsecond=0))
        if now != last:
            leave_in = (pk.leave_at - order.created_at).total_seconds()
            print(f"{stamp()} PLAN  status={order.status.value} decision={pk.decision} "
                  f"leave at {int(leave_in) // 60}:{int(leave_in) % 60:02d} | {pk.message}", flush=True)
            last = now
        await asyncio.sleep(1)
    await asyncio.sleep(1)
    pk = order.pickup
    print(f"\n{stamp()} Done. status={order.status.value}. If you left when told you'd "
          f"arrive {pk.trip_min} min after leaving.")
    await orders.shutdown()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["walking", "driving"], default="walking")
    ap.add_argument("--walk-min", type=float, default=5.0, help="how far away you start, in walking minutes")
    ap.add_argument("--ready-min", type=float, default=2.0, help="kitchen finishes this many minutes after ordering")
    ap.add_argument("--refresh", type=float, default=5.0, help="seconds between re-plans (app default 30)")
    logging.basicConfig(level=logging.WARNING)
    asyncio.run(main(ap.parse_args()))
