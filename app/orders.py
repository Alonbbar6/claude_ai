"""Order service: routes orders, quotes ETAs, plans courier dispatch, and
simulates the lifecycle.

Routing (distance + traffic-aware travel time) comes from the maps provider
(Google Distance Matrix when a key is configured). The ETA model uses that
travel time as a feature. When the kitchen confirms, we build a dispatch
plan so the courier reaches the restaurant as the food comes out instead
of idling there or leaving it to sit.
"""

from __future__ import annotations

import asyncio
import logging
import random
from datetime import datetime, timedelta, timezone

from app.maps import LatLng, RouteProvider
from app.models import (
    CLOSED,
    LIFECYCLE,
    Courier,
    CreateOrderRequest,
    DispatchPlan,
    Order,
    OrderStatus,
    Restaurant,
    Route,
    User,
)
from app.notifications.events import (
    ORDER_DELAYED,
    ORDER_ETA_UPDATED,
    ORDER_STATUS_CHANGED,
    Event,
    EventBus,
)
from app.prediction.eta import EtaPredictor

log = logging.getLogger(__name__)

DELAY_ALERT_MIN = 5.0
HANDOFF_MIN = 1.5  # bagging/handoff at the restaurant and at the door


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class OrderService:
    def __init__(
        self,
        bus: EventBus,
        predictor: EtaPredictor,
        routes: RouteProvider,
        users: dict[str, User],
        restaurants: dict[str, Restaurant],
        couriers: dict[str, Courier],
        *,
        stage_seconds: float = 4.0,
        seed: int | None = None,
    ) -> None:
        self.bus = bus
        self.predictor = predictor
        self.routes = routes
        self.users = users
        self.restaurants = restaurants
        self.couriers = couriers
        self.stage_seconds = stage_seconds
        self.orders: dict[str, Order] = {}
        self._rng = random.Random(seed)
        self._tasks: set[asyncio.Task] = set()

    # ---- live context ------------------------------------------------

    def courier_load(self) -> float:
        """Active orders per courier."""
        active = sum(1 for o in self.orders.values() if o.status not in CLOSED)
        return active / max(len(self.couriers), 1)

    def restaurant_busy(self, restaurant_id: str) -> float:
        return float(sum(
            1 for o in self.orders.values()
            if o.restaurant_id == restaurant_id
            and o.status in (OrderStatus.PLACED, OrderStatus.CONFIRMED, OrderStatus.PREPARING)
        ))

    def kitchen_minutes(self, order: Order) -> float:
        """How long until the food is ready, from the kitchen's point of view."""
        r = self.restaurants[order.restaurant_id]
        return r.avg_prep_min + 1.2 * order.item_count() + 1.8 * self.restaurant_busy(r.id)

    def _predict(self, order: Order, jitter: float = 0.0):
        now = utcnow()
        elapsed = (now - order.created_at).total_seconds() / 60
        # Simulated world is fast; scale elapsed so the model sees "minutes".
        elapsed_sim = elapsed * (60 / max(self.stage_seconds, 0.01))
        return self.predictor.predict(
            distance_km=order.route.distance_km,
            travel_time_min=order.route.duration_min,
            prep_time_min=self.restaurants[order.restaurant_id].avg_prep_min,
            item_count=order.item_count(),
            when=now,
            raining=order.raining,
            courier_load=self.courier_load() + jitter,
            restaurant_busy=self.restaurant_busy(order.restaurant_id) + jitter * 2,
            status=order.status,
            elapsed_min=elapsed_sim,
        )

    # ---- commands ----------------------------------------------------

    async def create(self, req: CreateOrderRequest) -> Order:
        user = self.users[req.user_id]
        restaurant = self.restaurants[req.restaurant_id]
        known = {m.id for m in restaurant.menu}
        for line in req.lines:
            if line.item_id not in known:
                raise ValueError(f"unknown item {line.item_id} for {restaurant.id}")

        est = await self.routes.route(
            LatLng(restaurant.lat, restaurant.lng), LatLng(user.lat, user.lng)
        )
        order = Order(
            user_id=user.id,
            restaurant_id=restaurant.id,
            lines=req.lines,
            raining=req.raining,
            route=Route(distance_km=est.distance_km, duration_min=est.duration_min, source=est.source),
        )
        self.orders[order.id] = order
        order.quoted_eta = order.current_eta = self._predict(order)
        order.history.append(self._entry(order))
        await self.bus.publish(Event(ORDER_STATUS_CHANGED, {"order": order}))

        task = asyncio.create_task(self._run_lifecycle(order.id))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return order

    async def advance(self, order_id: str) -> Order:
        order = self.orders[order_id]
        if order.status in CLOSED:
            return order
        order.status = LIFECYCLE[LIFECYCLE.index(order.status) + 1]
        order.updated_at = utcnow()

        if order.status == OrderStatus.CONFIRMED:
            await self.plan_dispatch(order)
        elif order.status == OrderStatus.COURIER_DISPATCHED and order.dispatch:
            self.couriers[order.dispatch.courier_id].active_order_id = order.id
        elif order.status == OrderStatus.DELIVERED:
            self._release_courier(order)
            order.current_eta = None

        if order.status != OrderStatus.DELIVERED:
            await self.refresh_eta(order)

        order.history.append(self._entry(order))
        await self.bus.publish(Event(ORDER_STATUS_CHANGED, {"order": order}))
        return order

    async def cancel(self, order_id: str) -> Order:
        order = self.orders[order_id]
        if order.status in CLOSED:
            return order
        order.status = OrderStatus.CANCELLED
        order.updated_at = utcnow()
        order.current_eta = None
        self._release_courier(order)
        order.history.append(self._entry(order))
        await self.bus.publish(Event(ORDER_STATUS_CHANGED, {"order": order}))
        return order

    async def plan_dispatch(self, order: Order) -> DispatchPlan | None:
        """Pick a courier and time their dispatch to the food being ready.

        For each free courier we ask the maps provider for the courier ->
        restaurant leg. The best courier is the one whose arrival lands
        closest to ``ready_at`` without the food waiting; if nobody can make
        it in time, we take whoever gets there soonest and record the delay.
        """
        restaurant = self.restaurants[order.restaurant_id]
        now = utcnow()
        ready_at = now + timedelta(minutes=self.kitchen_minutes(order))
        until_ready = (ready_at - now).total_seconds() / 60

        free = [c for c in self.couriers.values() if c.active_order_id is None]
        if not free:
            log.warning("no free couriers for %s", order.id)
            order.dispatch = None
            return None

        legs = await asyncio.gather(*(
            self.routes.route(LatLng(c.lat, c.lng), LatLng(restaurant.lat, restaurant.lng))
            for c in free
        ))

        def score(pair):
            _, leg = pair
            lateness = max(0.0, leg.duration_min - until_ready)
            # Prefer on-time arrivals; among those, the shortest leg frees the
            # courier sooner for other orders.
            return (lateness, leg.duration_min)

        courier, leg = min(zip(free, legs), key=score)
        dispatch_at = max(now, ready_at - timedelta(minutes=leg.duration_min))
        arrive_at = dispatch_at + timedelta(minutes=leg.duration_min)
        pickup_at = max(arrive_at, ready_at) + timedelta(minutes=HANDOFF_MIN)
        delivery_at = pickup_at + timedelta(minutes=order.route.duration_min + HANDOFF_MIN)

        order.dispatch = DispatchPlan(
            courier_id=courier.id,
            courier_name=courier.name,
            courier_to_restaurant_km=leg.distance_km,
            courier_to_restaurant_min=leg.duration_min,
            ready_at=ready_at,
            dispatch_at=dispatch_at,
            expected_pickup_at=pickup_at,
            expected_delivery_at=delivery_at,
            pickup_delay_min=round(max(0.0, (arrive_at - ready_at).total_seconds() / 60), 1),
            route_source=leg.source,
        )
        return order.dispatch

    async def refresh_eta(self, order: Order, *, jitter: float | None = None) -> Order:
        """Re-predict and raise ``order.delayed`` if we slipped past the quote."""
        if jitter is None:
            # Random demand shock so the demo shows late alerts sometimes.
            jitter = max(0.0, self._rng.gauss(0.3, 0.6))
        previous = order.current_eta
        order.current_eta = self._predict(order, jitter=jitter)
        await self.bus.publish(Event(ORDER_ETA_UPDATED, {"order": order}))

        if previous is not None:
            # Compare arrival timestamps, not remaining minutes, since
            # "remaining" shrinks as time passes.
            slip = (order.current_eta.eta_at - previous.eta_at).total_seconds() / 60
            if slip >= DELAY_ALERT_MIN:
                await self.bus.publish(
                    Event(ORDER_DELAYED, {"order": order, "delay_min": slip})
                )
        return order

    # ---- simulation --------------------------------------------------

    async def _run_lifecycle(self, order_id: str) -> None:
        try:
            while self.orders[order_id].status not in CLOSED:
                await asyncio.sleep(self.stage_seconds)
                await self.advance(order_id)
        except asyncio.CancelledError:
            pass
        except Exception:
            log.exception("lifecycle failed for %s", order_id)

    async def shutdown(self) -> None:
        for t in list(self._tasks):
            t.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)

    def _release_courier(self, order: Order) -> None:
        if order.dispatch:
            c = self.couriers.get(order.dispatch.courier_id)
            if c and c.active_order_id == order.id:
                c.active_order_id = None

    @staticmethod
    def _entry(order: Order) -> dict:
        eta = order.current_eta
        return {
            "status": order.status.value,
            "at": order.updated_at.isoformat(),
            "eta_minutes": eta.eta_minutes if eta else None,
            "delay_risk": eta.delay_risk if eta else None,
        }
