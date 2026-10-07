"""Order service: routes orders, quotes ETAs, plans courier dispatch or
customer pickup, and simulates the lifecycle.

Routing (distance + traffic-aware travel time) comes from the maps provider
(Google Distance Matrix when a key is configured).

Delivery: the ETA model uses the restaurant -> customer travel time as a
feature. When the kitchen confirms, we build a dispatch plan so the courier
reaches the restaurant as the food comes out.

Pickup: the kitchen ready-time model predicts when the food comes out; the
pickup planner tells the customer when to leave from where they are now, and
fires a "time to head out" notification at that moment.
"""

from __future__ import annotations

import asyncio
import logging
import random
from datetime import datetime, timedelta, timezone

from app.maps import LatLng, RouteEstimate, RouteProvider
from app.models import (
    CLOSED,
    Courier,
    CreateOrderRequest,
    DispatchPlan,
    Fulfillment,
    Order,
    OrderStatus,
    PickupPlan,
    Restaurant,
    Route,
    TravelMode,
    User,
)
from app.notifications.events import (
    ORDER_DELAYED,
    ORDER_ETA_UPDATED,
    ORDER_PICKUP_LEAVE,
    ORDER_STATUS_CHANGED,
    Event,
    EventBus,
)
from app.pickup import plan_pickup
from app.prediction.eta import EtaPredictor
from app.prediction.ready import ReadyTimePredictor

log = logging.getLogger(__name__)

DELAY_ALERT_MIN = 5.0
HANDOFF_MIN = 1.5  # bagging/handoff at the restaurant and at the door
KITCHEN_STATUSES = (OrderStatus.PLACED, OrderStatus.CONFIRMED, OrderStatus.PREPARING)


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def minutes_since(t: datetime) -> float:
    return (utcnow() - t).total_seconds() / 60


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
        ready_predictor: ReadyTimePredictor | None = None,
        stage_seconds: float = 4.0,
        plan_refresh_seconds: float = 30.0,
        seed: int | None = None,
    ) -> None:
        self.bus = bus
        self.predictor = predictor
        self.routes = routes
        self.users = users
        self.restaurants = restaurants
        self.couriers = couriers
        if ready_predictor is None:
            ready_predictor = ReadyTimePredictor()
            ready_predictor.load_or_train()
        self.ready = ready_predictor
        self.stage_seconds = stage_seconds
        self.plan_refresh_seconds = plan_refresh_seconds
        self.orders: dict[str, Order] = {}
        self._rng = random.Random(seed)
        self._tasks: set[asyncio.Task] = set()
        # Simulated "true" kitchen finish times for pickup orders (hidden
        # from the models, like reality).
        self._actual_ready: dict[str, datetime] = {}

    # ---- live context ------------------------------------------------

    def courier_load(self) -> float:
        """Active delivery orders per courier."""
        active = sum(
            1 for o in self.orders.values()
            if o.status not in CLOSED and o.fulfillment == Fulfillment.DELIVERY
        )
        return active / max(len(self.couriers), 1)

    def restaurant_busy(self, restaurant_id: str) -> float:
        return float(sum(
            1 for o in self.orders.values()
            if o.restaurant_id == restaurant_id and o.status in KITCHEN_STATUSES
        ))

    def predict_ready(self, order: Order):
        r = self.restaurants[order.restaurant_id]
        return self.ready.predict(
            prep_time_min=r.avg_prep_min,
            item_count=order.item_count(),
            restaurant_busy=self.restaurant_busy(r.id),
            when=utcnow(),
            elapsed_min=minutes_since(order.created_at),
        )

    def kitchen_minutes(self, order: Order) -> float:
        """Most likely minutes until the food is ready (model p50)."""
        return self.predict_ready(order).p50

    def _predict(self, order: Order, jitter: float = 0.0):
        now = utcnow()
        # Simulated world is fast; scale elapsed so the model sees "minutes".
        elapsed_sim = minutes_since(order.created_at) * (60 / max(self.stage_seconds, 0.01))
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

        pickup = req.fulfillment == Fulfillment.PICKUP
        if pickup:
            origin = self._pickup_origin(user, req.pickup_lat, req.pickup_lng)
            est = await self.routes.route(
                origin, LatLng(restaurant.lat, restaurant.lng), mode=req.pickup_mode.value)
        else:
            est = await self.routes.route(
                LatLng(restaurant.lat, restaurant.lng), LatLng(user.lat, user.lng))

        order = Order(
            user_id=user.id,
            restaurant_id=restaurant.id,
            lines=req.lines,
            raining=req.raining,
            route=_route(est),
            fulfillment=req.fulfillment,
            pickup_lat=req.pickup_lat if pickup else None,
            pickup_lng=req.pickup_lng if pickup else None,
            pickup_mode=req.pickup_mode,
        )
        self.orders[order.id] = order

        if pickup:
            est_ready = self.predict_ready(order)
            # The kitchen's real finish time: near the median, with noise.
            actual = max(3.0, est_ready.p50 * self._rng.lognormvariate(0, 0.12))
            self._actual_ready[order.id] = order.created_at + timedelta(minutes=actual)
            order.pickup = self._compute_pickup_plan(order, est)
        else:
            order.quoted_eta = order.current_eta = self._predict(order)

        order.history.append(self._entry(order))
        await self.bus.publish(Event(ORDER_STATUS_CHANGED, {"order": order}))
        if pickup:
            await self._maybe_signal_leave(order)

        task = asyncio.create_task(self._run_lifecycle(order.id))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return order

    async def advance(self, order_id: str) -> Order:
        order = self.orders[order_id]
        if order.status in CLOSED:
            return order
        lifecycle = order.lifecycle()
        order.status = lifecycle[lifecycle.index(order.status) + 1]
        order.updated_at = utcnow()

        if order.is_pickup:
            if order.status == OrderStatus.READY:
                order.ready_at = order.updated_at
            if order.status != OrderStatus.COLLECTED:
                await self.refresh_pickup_plan(order, signal=False)
        else:
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
        if order.is_pickup:
            await self._maybe_signal_leave(order)
        return order

    async def collect(self, order_id: str) -> Order:
        """Customer confirms they have the food."""
        order = self.orders[order_id]
        if not order.is_pickup or order.status != OrderStatus.READY:
            raise ValueError("only pickup orders that are ready can be collected")
        return await self.advance(order_id)

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

    # ---- pickup --------------------------------------------------------

    def _pickup_origin(self, user: User, lat: float | None, lng: float | None) -> LatLng:
        """Customer's live location when the app sent one, else their profile address."""
        if lat is not None and lng is not None:
            return LatLng(lat, lng)
        return LatLng(user.lat, user.lng)

    def _compute_pickup_plan(self, order: Order, route: RouteEstimate) -> PickupPlan:
        return plan_pickup(
            now=utcnow(),
            route=route,
            mode=order.pickup_mode,
            ready=None if order.ready_at else self.predict_ready(order),
            actual_ready_at=order.ready_at,
        )

    async def refresh_pickup_plan(
        self,
        order: Order,
        *,
        lat: float | None = None,
        lng: float | None = None,
        mode: TravelMode | None = None,
        signal: bool = True,
    ) -> Order:
        """Re-plan from the customer's latest location / travel mode."""
        if not order.is_pickup:
            raise ValueError("not a pickup order")
        if lat is not None and lng is not None:
            order.pickup_lat, order.pickup_lng = lat, lng
        if mode is not None:
            order.pickup_mode = mode
        if order.status in CLOSED:
            return order
        restaurant = self.restaurants[order.restaurant_id]
        origin = self._pickup_origin(self.users[order.user_id], order.pickup_lat, order.pickup_lng)
        est = await self.routes.route(
            origin, LatLng(restaurant.lat, restaurant.lng), mode=order.pickup_mode.value)
        order.route = _route(est)
        order.pickup = self._compute_pickup_plan(order, est)
        if signal:
            await self._maybe_signal_leave(order)
        return order

    async def quote_pickup(
        self, user: User, restaurant: Restaurant, *, item_count: int,
        lat: float | None, lng: float | None, mode: TravelMode,
    ) -> PickupPlan:
        """Pickup plan before ordering, as shown in the cart."""
        est = await self.routes.route(
            self._pickup_origin(user, lat, lng), LatLng(restaurant.lat, restaurant.lng), mode=mode.value)
        ready = self.ready.predict(
            prep_time_min=restaurant.avg_prep_min,
            item_count=item_count,
            restaurant_busy=self.restaurant_busy(restaurant.id),
            when=utcnow(),
        )
        return plan_pickup(now=utcnow(), route=est, mode=mode, ready=ready)

    async def _maybe_signal_leave(self, order: Order) -> None:
        # The notification service dedups per order, so this is safe to call
        # on every re-plan; the customer hears it once.
        if order.pickup and order.pickup.decision == "leave_now" and order.status in KITCHEN_STATUSES:
            await self.bus.publish(Event(ORDER_PICKUP_LEAVE, {"order": order}))

    # ---- delivery ------------------------------------------------------

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
        if order.is_pickup:
            raise ValueError("pickup orders have no delivery ETA")
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
            if self.orders[order_id].is_pickup:
                await self._run_pickup(order_id)
                return
            while self.orders[order_id].status not in CLOSED:
                await asyncio.sleep(self.stage_seconds)
                await self.advance(order_id)
        except asyncio.CancelledError:
            pass
        except Exception:
            log.exception("lifecycle failed for %s", order_id)

    async def _run_pickup(self, order_id: str) -> None:
        """Kitchen accepts and cooks in real time; the customer collects.

        While cooking we re-plan periodically from the customer's last known
        location so "time to head out" fires on time even if the app is
        closed. "Advance" in the API skips ahead for demos.
        """
        order = self.orders[order_id]
        while order.status in (OrderStatus.PLACED, OrderStatus.CONFIRMED):
            await asyncio.sleep(self.stage_seconds)
            if order.status in (OrderStatus.PLACED, OrderStatus.CONFIRMED):
                await self.advance(order_id)
        while order.status == OrderStatus.PREPARING:
            remaining = (self._actual_ready[order_id] - utcnow()).total_seconds()
            if remaining <= 0:
                await self.advance(order_id)  # -> ready
                break
            await asyncio.sleep(min(remaining, self.plan_refresh_seconds))
            if order.status == OrderStatus.PREPARING:
                await self.refresh_pickup_plan(order)

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


def _route(est: RouteEstimate) -> Route:
    return Route(distance_km=est.distance_km, duration_min=est.duration_min, source=est.source)
