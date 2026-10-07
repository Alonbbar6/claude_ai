"""Notification service.

Listens to order events, renders a message, applies the user's preferences
(channels, quiet hours), dedups repeats, and dispatches to each channel with
retry. Every attempt is recorded so the API can show a delivery log.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone

from app.models import (
    Channel,
    DeliveryRecord,
    Notification,
    Order,
    Restaurant,
    User,
)
from app.notifications import templates
from app.notifications.channels import BaseChannel, ChannelError
from app.notifications.events import (
    ORDER_DELAYED,
    ORDER_ETA_UPDATED,
    ORDER_STATUS_CHANGED,
    Event,
    EventBus,
)

log = logging.getLogger(__name__)

# Only warn about delay risk once it crosses this probability.
HIGH_RISK_THRESHOLD = 0.6


def in_quiet_hours(hour: int, start: int, end: int) -> bool:
    if start == end:
        return False
    if start < end:
        return start <= hour < end
    return hour >= start or hour < end  # wraps midnight, e.g. 22 -> 8


class NotificationService:
    def __init__(
        self,
        bus: EventBus,
        channels: dict[Channel, BaseChannel],
        users: dict[str, User],
        restaurants: dict[str, Restaurant],
        *,
        max_attempts: int = 3,
        retry_delay: float = 0.05,
        clock=datetime.now,
    ) -> None:
        self.channels = channels
        self.users = users
        self.restaurants = restaurants
        self.max_attempts = max_attempts
        self.retry_delay = retry_delay
        self.clock = clock  # local time, for quiet hours
        self.clock_utc = lambda: datetime.now(timezone.utc)

        self.notifications: list[Notification] = []
        self.deliveries: list[DeliveryRecord] = []
        self.deferred: list[Notification] = []  # held for quiet hours
        self._seen: set[tuple[str | None, str]] = set()  # (order_id, kind) dedup

        bus.subscribe(ORDER_STATUS_CHANGED, self.on_status_changed)
        bus.subscribe(ORDER_ETA_UPDATED, self.on_eta_updated)
        bus.subscribe(ORDER_DELAYED, self.on_delayed)

    # ---- event handlers ----------------------------------------------

    async def on_status_changed(self, event: Event) -> None:
        order: Order = event.payload["order"]
        await self.notify_order(order, kind=order.status.value)

    async def on_eta_updated(self, event: Event) -> None:
        order: Order = event.payload["order"]
        eta = order.current_eta
        if eta and eta.delay_risk >= HIGH_RISK_THRESHOLD:
            await self.notify_order(order, kind="high_delay_risk")

    async def on_delayed(self, event: Event) -> None:
        order: Order = event.payload["order"]
        await self.notify_order(
            order, kind="delayed", delay_min=round(event.payload["delay_min"])
        )

    # ---- core --------------------------------------------------------

    async def notify_order(self, order: Order, kind: str, **extra) -> Notification | None:
        user = self.users[order.user_id]
        restaurant = self.restaurants[order.restaurant_id]
        eta = order.current_eta or order.quoted_eta
        plan = order.dispatch
        pickup_min = (
            max(0, round((plan.expected_pickup_at - self.clock_utc()).total_seconds() / 60))
            if plan else "?"
        )
        ctx = {
            "user": user.name,
            "restaurant": restaurant.name,
            "eta_min": round(eta.eta_minutes) if eta else "?",
            "courier": plan.courier_name if plan else "Your courier",
            "pickup_min": pickup_min,
            **extra,
        }
        title, body, urgent = templates.render(kind, **ctx)
        n = Notification(
            user_id=user.id, order_id=order.id, kind=kind, title=title, body=body, urgent=urgent
        )
        return await self.dispatch(n)

    async def dispatch(self, n: Notification) -> Notification | None:
        # Dedup: a "delayed" alert can legitimately repeat, status changes cannot.
        key = (n.order_id, n.kind)
        if n.kind != "delayed" and key in self._seen:
            log.debug("dedup %s", key)
            return None
        self._seen.add(key)
        self.notifications.append(n)

        user = self.users[n.user_id]
        prefs = user.prefs
        quiet = in_quiet_hours(self.clock().hour, prefs.quiet_start, prefs.quiet_end)
        if quiet and not (n.urgent and prefs.allow_urgent_in_quiet_hours):
            self.deferred.append(n)
            for ch in prefs.channels:
                self._record(n, ch, "deferred", 0, "quiet hours")
            return n

        await asyncio.gather(*(self._send_with_retry(user, n, ch) for ch in prefs.channels))
        return n

    async def _send_with_retry(self, user: User, n: Notification, ch: Channel) -> None:
        channel = self.channels.get(ch)
        if channel is None:
            self._record(n, ch, "skipped", 0, "channel not configured")
            return
        for attempt in range(1, self.max_attempts + 1):
            try:
                detail = await channel.send(user, n)
                self._record(n, ch, "sent", attempt, detail)
                return
            except ChannelError as exc:
                last = str(exc)
                if attempt < self.max_attempts:
                    await asyncio.sleep(self.retry_delay * attempt)
        self._record(n, ch, "failed", self.max_attempts, last)

    async def flush_deferred(self) -> int:
        """Send everything held during quiet hours. Call when they end."""
        pending, self.deferred = self.deferred, []
        for n in pending:
            user = self.users[n.user_id]
            await asyncio.gather(
                *(self._send_with_retry(user, n, ch) for ch in user.prefs.channels)
            )
        return len(pending)

    def _record(self, n: Notification, ch: Channel, status: str, attempts: int, detail: str):
        self.deliveries.append(
            DeliveryRecord(
                notification_id=n.id, channel=ch, status=status, attempts=attempts, detail=detail
            )
        )

    # ---- queries -----------------------------------------------------

    def for_user(self, user_id: str) -> list[Notification]:
        return [n for n in self.notifications if n.user_id == user_id]

    def deliveries_for(self, notification_id: str) -> list[DeliveryRecord]:
        return [d for d in self.deliveries if d.notification_id == notification_id]
