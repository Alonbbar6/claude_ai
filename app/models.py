"""Domain models for the mini food delivery app."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from enum import Enum

from pydantic import BaseModel, Field


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


class OrderStatus(str, Enum):
    PLACED = "placed"
    CONFIRMED = "confirmed"
    PREPARING = "preparing"
    READY = "ready"  # pickup only: waiting on the counter
    COURIER_DISPATCHED = "courier_dispatched"
    PICKED_UP = "picked_up"
    DELIVERED = "delivered"
    COLLECTED = "collected"  # pickup only: customer has the food
    CANCELLED = "cancelled"


class Fulfillment(str, Enum):
    DELIVERY = "delivery"
    PICKUP = "pickup"


class TravelMode(str, Enum):
    DRIVING = "driving"
    WALKING = "walking"


# Order of the happy-path lifecycle. The simulator walks orders through it.
LIFECYCLE = [
    OrderStatus.PLACED,
    OrderStatus.CONFIRMED,
    OrderStatus.PREPARING,
    OrderStatus.COURIER_DISPATCHED,
    OrderStatus.PICKED_UP,
    OrderStatus.DELIVERED,
]

PICKUP_LIFECYCLE = [
    OrderStatus.PLACED,
    OrderStatus.CONFIRMED,
    OrderStatus.PREPARING,
    OrderStatus.READY,
    OrderStatus.COLLECTED,
]

CLOSED = {OrderStatus.DELIVERED, OrderStatus.COLLECTED, OrderStatus.CANCELLED}


class MenuItem(BaseModel):
    id: str
    name: str
    price: float


class Restaurant(BaseModel):
    id: str
    name: str
    cuisine: str
    lat: float
    lng: float
    avg_prep_min: float
    menu: list[MenuItem]


class Courier(BaseModel):
    id: str
    name: str
    lat: float
    lng: float
    active_order_id: str | None = None


class Channel(str, Enum):
    PUSH = "push"
    SMS = "sms"
    EMAIL = "email"
    WEBSOCKET = "websocket"


class NotificationPreferences(BaseModel):
    channels: list[Channel] = Field(
        default_factory=lambda: [Channel.PUSH, Channel.WEBSOCKET]
    )
    # Quiet hours are [start, end) in local hours, 24h. Equal values = disabled.
    quiet_start: int = 22
    quiet_end: int = 8
    # Urgent notifications (e.g. driver arriving) bypass quiet hours.
    allow_urgent_in_quiet_hours: bool = True


class User(BaseModel):
    id: str
    name: str
    phone: str
    email: str
    lat: float
    lng: float
    prefs: NotificationPreferences = Field(default_factory=NotificationPreferences)


class OrderLine(BaseModel):
    item_id: str
    quantity: int = 1


class CreateOrderRequest(BaseModel):
    user_id: str
    restaurant_id: str
    lines: list[OrderLine]
    # Simulated context; a real app would pull these from live services.
    raining: bool = False
    fulfillment: Fulfillment = Fulfillment.DELIVERY
    # Pickup only: where the customer is now (phone GPS) and how they'll travel.
    # Falls back to the profile address when omitted.
    pickup_lat: float | None = None
    pickup_lng: float | None = None
    pickup_mode: TravelMode = TravelMode.DRIVING


class EtaPrediction(BaseModel):
    eta_minutes: float
    eta_at: datetime
    delay_risk: float  # probability the order is > 10 min later than quoted
    features: dict[str, float]


class Route(BaseModel):
    """Restaurant -> customer leg, from Google Distance Matrix or fallback."""

    distance_km: float
    duration_min: float
    source: str


class DispatchPlan(BaseModel):
    """When to send the courier so they arrive as the food comes out.

    dispatch_at = ready_at - courier_to_restaurant_min, clamped to "now".
    """

    courier_id: str
    courier_name: str
    courier_to_restaurant_km: float
    courier_to_restaurant_min: float
    ready_at: datetime
    dispatch_at: datetime
    expected_pickup_at: datetime
    expected_delivery_at: datetime
    # > 0 when no courier can reach the restaurant before the food is ready,
    # i.e. the food will sit for this many minutes.
    pickup_delay_min: float
    route_source: str


class PickupPlan(BaseModel):
    """When the customer should leave so they arrive as the food comes out.

    leave_at = target_arrival_at - trip_min, where target_arrival_at is the
    kitchen model's p75 ready time.
    """

    decision: str  # wait | leave_now | ready | too_far
    message: str
    mode: TravelMode
    distance_km: float
    travel_min: float  # route only
    trip_min: float  # route + parking / walking in
    route_source: str
    ready_at: datetime  # most likely (p50), or actual once ready
    ready_by: datetime  # almost surely ready (p90)
    target_arrival_at: datetime
    leave_at: datetime
    arrive_at: datetime
    food_wait_min: float  # food sits on the counter this long
    your_wait_min: float  # customer waits at the counter this long
    computed_at: datetime


class Order(BaseModel):
    id: str = Field(default_factory=lambda: new_id("ord"))
    user_id: str
    restaurant_id: str
    lines: list[OrderLine]
    status: OrderStatus = OrderStatus.PLACED
    created_at: datetime = Field(default_factory=utcnow)
    updated_at: datetime = Field(default_factory=utcnow)
    route: Route
    raining: bool = False
    quoted_eta: EtaPrediction | None = None
    current_eta: EtaPrediction | None = None
    dispatch: DispatchPlan | None = None
    history: list[dict] = Field(default_factory=list)
    # Pickup orders
    fulfillment: Fulfillment = Fulfillment.DELIVERY
    pickup_lat: float | None = None
    pickup_lng: float | None = None
    pickup_mode: TravelMode = TravelMode.DRIVING
    pickup: PickupPlan | None = None
    ready_at: datetime | None = None  # actual time the kitchen finished

    @property
    def is_pickup(self) -> bool:
        return self.fulfillment == Fulfillment.PICKUP

    def lifecycle(self) -> list[OrderStatus]:
        return PICKUP_LIFECYCLE if self.is_pickup else LIFECYCLE

    def item_count(self) -> int:
        return sum(line.quantity for line in self.lines)


class Notification(BaseModel):
    id: str = Field(default_factory=lambda: new_id("ntf"))
    user_id: str
    order_id: str | None
    kind: str
    title: str
    body: str
    urgent: bool = False
    created_at: datetime = Field(default_factory=utcnow)


class DeliveryRecord(BaseModel):
    notification_id: str
    channel: Channel
    status: str  # sent | failed | deferred | skipped
    attempts: int
    detail: str = ""
    at: datetime = Field(default_factory=utcnow)
