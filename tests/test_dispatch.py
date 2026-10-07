"""Dispatch timing: the courier should be sent so they arrive as the food
is ready, using the maps provider for the courier -> restaurant leg."""

from datetime import timedelta

import pytest

from app.maps import LatLng, RouteEstimate, RouteProvider
from app.models import Courier, CreateOrderRequest, MenuItem, OrderLine, Restaurant, User
from app.notifications.events import EventBus
from app.orders import HANDOFF_MIN, OrderService
from app.prediction.eta import EtaPredictor


class FixedRoutes(RouteProvider):
    """Returns a per-origin travel time so tests control courier distance."""

    def __init__(self, minutes_by_origin: dict[tuple[float, float], float], default=10.0):
        self.by_origin = minutes_by_origin
        self.default = default

    async def route(self, origin: LatLng, dest: LatLng, mode: str = "driving") -> RouteEstimate:
        m = self.by_origin.get((origin.lat, origin.lng), self.default)
        return RouteEstimate(distance_km=m / 3, duration_min=m, source="fixed")


REST = Restaurant(id="r", name="R", cuisine="x", lat=1.0, lng=1.0, avg_prep_min=15,
                  menu=[MenuItem(id="i", name="I", price=5)])
USER = User(id="u", name="U", phone="1", email="u@x", lat=2.0, lng=2.0)


@pytest.fixture(scope="module")
def predictor():
    p = EtaPredictor()
    p.train(n=1500, seed=3)
    return p


def make_service(predictor, couriers, routes):
    return OrderService(
        EventBus(), predictor, routes, {"u": USER}, {"r": REST},
        {c.id: c for c in couriers}, stage_seconds=3600, seed=0,
    )


async def create_and_confirm(svc):
    order = await svc.create(CreateOrderRequest(user_id="u", restaurant_id="r",
                                                lines=[OrderLine(item_id="i", quantity=1)]))
    await svc.advance(order.id)  # -> confirmed, builds dispatch plan
    return order


async def test_picks_courier_who_arrives_on_time_and_delays_dispatch(predictor):
    near = Courier(id="near", name="Near", lat=5.0, lng=5.0)   # 4 min away
    far = Courier(id="far", name="Far", lat=6.0, lng=6.0)      # 40 min away
    svc = make_service(predictor, [near, far], FixedRoutes({(5.0, 5.0): 4.0, (6.0, 6.0): 40.0}))
    order = await create_and_confirm(svc)
    plan = order.dispatch

    assert plan.courier_id == "near"
    assert plan.pickup_delay_min == 0
    # Kitchen needs ~16 min; courier is 4 min away -> leave ~12 min from now.
    assert plan.dispatch_at == plan.ready_at - timedelta(minutes=4)
    assert plan.expected_pickup_at == plan.ready_at + timedelta(minutes=HANDOFF_MIN)
    # Delivery = pickup + customer leg (default 10 min) + handoff.
    assert plan.expected_delivery_at == plan.expected_pickup_at + timedelta(minutes=10 + HANDOFF_MIN)
    assert plan.route_source == "fixed"


async def test_when_nobody_can_make_it_pick_soonest_and_record_delay(predictor):
    a = Courier(id="a", name="A", lat=5.0, lng=5.0)  # 30 min away
    b = Courier(id="b", name="B", lat=6.0, lng=6.0)  # 25 min away
    svc = make_service(predictor, [a, b], FixedRoutes({(5.0, 5.0): 30.0, (6.0, 6.0): 25.0}))
    order = await create_and_confirm(svc)
    plan = order.dispatch

    assert plan.courier_id == "b"
    # Leave immediately: dispatch_at is clamped to "now" (within clock jitter).
    assert abs((plan.dispatch_at - order.updated_at).total_seconds()) < 1
    assert plan.pickup_delay_min > 0
    assert plan.expected_pickup_at > plan.ready_at


async def test_busy_couriers_are_skipped_and_released_on_delivery(predictor):
    c1 = Courier(id="c1", name="C1", lat=5.0, lng=5.0, active_order_id="other")
    c2 = Courier(id="c2", name="C2", lat=6.0, lng=6.0)
    svc = make_service(predictor, [c1, c2], FixedRoutes({(5.0, 5.0): 1.0, (6.0, 6.0): 20.0}))
    order = await create_and_confirm(svc)
    assert order.dispatch.courier_id == "c2"

    await svc.advance(order.id)  # preparing
    await svc.advance(order.id)  # courier_dispatched
    assert c2.active_order_id == order.id
    await svc.advance(order.id)  # picked_up
    await svc.advance(order.id)  # delivered
    assert c2.active_order_id is None
    assert order.status.value == "delivered"


async def test_order_route_comes_from_provider(predictor):
    svc = make_service(predictor, [Courier(id="c", name="C", lat=5.0, lng=5.0)], FixedRoutes({}, default=7.5))
    order = await svc.create(CreateOrderRequest(user_id="u", restaurant_id="r",
                                                lines=[OrderLine(item_id="i", quantity=2)]))
    assert order.route.duration_min == 7.5 and order.route.source == "fixed"
    assert order.quoted_eta.features["travel_time_min"] == 7.5
