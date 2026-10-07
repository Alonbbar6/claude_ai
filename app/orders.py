"""Order service: routes orders, quotes ETAs, plans courier dispatch or
customer pickup, and simulates the lifecycle.

Routing (distance + traffic-aware travel time) comes from the maps provider
(Google Routes API when a key is configured).

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
    LatLngPoint,
    Order,
    OrderLine,
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
from app.inventory import InventoryService
from app.pickup import plan_pickup
from app.prediction.eta import EtaPredictor
from app.prediction.ready import ReadyEstimate, ReadyTimePredictor

log = logging.getLogger(__name__)

DELAY_ALERT_MIN = 5.0
HANDOFF_MIN = 1.5  # bagging/handoff at the restaurant and at the door
# Items at or under this prep time are grab-and-go: no cooking, so the
# kitchen model (built for cooked orders) doesn't apply; it's a handover.
GRAB_AND_GO_MAX_MIN = 3.0
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
        inventory: InventoryService | None = None,
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
        self.inventory = inventory
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

    def prep_minutes(self, restaurant: Restaurant, lines: list[OrderLine] | None) -> float:
        """Kitchen time for an order: the slowest item, with per-item times
        falling back to the restaurant average. No lines -> the average."""
        if not lines:
            return restaurant.avg_prep_min
        by_id = {m.id: m for m in restaurant.menu}
        times = [
            by_id[l.item_id].prep_min if by_id[l.item_id].prep_min is not None else restaurant.avg_prep_min
            for l in lines if l.item_id in by_id
        ]
        return max(times) if times else restaurant.avg_prep_min

    def ready_estimate(self, restaurant: Restaurant, lines: list[OrderLine] | None, *, item_count: int, elapsed_min: float = 0.0) -> ReadyEstimate:
        """Minutes until the food is ready. Grab-and-go orders are a counter
        handover: prep time plus a little per extra item, tight range. Cooked
        orders go through the kitchen model."""
        prep = self.prep_minutes(restaurant, lines)
        if lines and prep <= GRAB_AND_GO_MAX_MIN:
            p50 = max(0.5, prep + 0.5 * (item_count - 1) - elapsed_min)
            return ReadyEstimate(round(p50, 1), round(p50 + 1.0, 1), round(p50 + 2.0, 1))
        return self.ready.predict(
            prep_time_min=prep,
            item_count=item_count,
            restaurant_busy=self.restaurant_busy(restaurant.id),
            when=utcnow(),
            elapsed_min=elapsed_min,
        )

    def predict_ready(self, order: Order):
        return self.ready_estimate(
            self.restaurants[order.restaurant_id], order.lines,
            item_count=order.item_count(), elapsed_min=minutes_since(order.created_at))

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
            prep_time_min=self.prep_minutes(self.restaurants[order.restaurant_id], order.lines),
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
        if self.inventory:
            self.inventory.check(restaurant.id, req.lines)  # raises OutOfStock

        pickup = req.fulfillment == Fulfillment.PICKUP
        if pickup:
            origin = self._pickup_origin(user, req.pickup_lat, req.pickup_lng)
            est = await self.routes.route(
                origin, LatLng(restaurant.lat, restaurant.lng), mode=req.pickup_mode.value)
        else:
            dest = self.delivery_destination(user, req.delivery_lat, req.delivery_lng)
            est = await self.routes.route(LatLng(restaurant.lat, restaurant.lng), dest)

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
            delivery_lat=None if pickup else dest.lat,
            delivery_lng=None if pickup else dest.lng,
        )
        self.orders[order.id] = order
        if self.inventory:
            self.inventory.consume(order)

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
        if self.inventory:
            self.inventory.release(order)
        order.history.append(self._entry(order))
        await self.bus.publish(Event(ORDER_STATUS_CHANGED, {"order": order}))
        return order

    # ---- pickup --------------------------------------------------------

    def delivery_destination(self, user: User, lat: float | None, lng: float | None) -> LatLng:
        """Where a delivery goes: the phone's current location when the app
        sent one, else the profile address."""
        if lat is not None and lng is not None:
            return LatLng(lat, lng)
        return LatLng(user.lat, user.lng)

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
        lines: list[OrderLine] | None = None,
    ) -> PickupPlan:
        """Pickup plan before ordering, as shown in the cart."""
        est = await self.routes.route(
            self._pickup_origin(user, lat, lng), LatLng(restaurant.lat, restaurant.lng), mode=mode.value)
        ready = self.ready_estimate(restaurant, lines, item_count=item_count)
        return plan_pickup(now=utcnow(), route=est, mode=mode, ready=ready)

    async def _maybe_signal_leave(self, order: Order) -> None:
        # The notification service dedups per order, so this is safe to call
        # on every re-plan; the customer hears it once.
        if order.pickup and order.pickup.decision == "leave_now" and order.status in KITCHEN_STATUSES:
            await self.bus.publish(Event(ORDER_PICKUP_LEAVE, {"order": order}))

    # ---- delivery breakdown ----------------------------------------------

    async def delivery_breakdown(self, restaurant: Restaurant, dest: LatLng, lines: list[OrderLine] | None, item_count: int) -> dict:
        """Where a delivery's minutes go: kitchen, nearest free courier's leg
        to the restaurant, handoff, drive to the customer, handoff. For
        grab-and-go orders this *is* the quote; for cooked orders it explains
        the model's number."""
        ready = self.ready_estimate(restaurant, lines, item_count=item_count)
        free = [c for c in self.couriers.values() if c.active_order_id is None]
        courier_min = None
        if free:
            legs = await asyncio.gather(*(
                self.routes.route(LatLng(c.lat, c.lng), LatLng(restaurant.lat, restaurant.lng)) for c in free))
            courier_min = min(l.duration_min for l in legs)
        to_customer = await self.routes.route(LatLng(restaurant.lat, restaurant.lng), dest)
        wait_for = max(ready.p50, courier_min if courier_min is not None else ready.p50)
        total = wait_for + HANDOFF_MIN + to_customer.duration_min + HANDOFF_MIN
        return {
            "kitchen_min": ready.p50,
            "courier_to_restaurant_min": courier_min,
            "pickup_handoff_min": HANDOFF_MIN,
            "drive_to_you_min": to_customer.duration_min,
            "dropoff_handoff_min": HANDOFF_MIN,
            "total_min": round(total, 1),
            "grab_and_go": bool(lines) and self.prep_minutes(restaurant, lines) <= GRAB_AND_GO_MAX_MIN,
        }

    # ---- live tracking ---------------------------------------------------

    def courier_position(self, order: Order) -> LatLngPoint | None:
        """Where the courier is now, interpolated along the current leg by
        how far through the stage we are. Real couriers would report GPS."""
        if order.is_pickup or not order.dispatch:
            return None
        courier = self.couriers.get(order.dispatch.courier_id)
        restaurant = self.restaurants[order.restaurant_id]
        user = self.users[order.user_id]
        if courier is None:
            return None
        start = (courier.lat, courier.lng)
        rest = (restaurant.lat, restaurant.lng)
        home = (order.delivery_lat if order.delivery_lat is not None else user.lat,
                order.delivery_lng if order.delivery_lng is not None else user.lng)
        frac = min(1.0, max(0.0, minutes_since(order.updated_at) * 60 / max(self.stage_seconds, 0.01)))
        if order.status in (OrderStatus.PLACED, OrderStatus.CONFIRMED, OrderStatus.PREPARING):
            a, b, f = start, start, 0.0
        elif order.status == OrderStatus.COURIER_DISPATCHED:
            a, b, f = start, rest, frac
        elif order.status == OrderStatus.PICKED_UP:
            a, b, f = rest, home, frac
        elif order.status == OrderStatus.DELIVERED:
            a, b, f = home, home, 1.0
        else:
            return None
        return LatLngPoint(lat=a[0] + (b[0] - a[0]) * f, lng=a[1] + (b[1] - a[1]) * f)

    def with_live(self, order: Order) -> Order:
        """Fill in read-time fields (courier position) before returning an order."""
        order.courier_location = self.courier_position(order)
        return order

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
        # order.route is restaurant -> delivery destination (current location or home).
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
