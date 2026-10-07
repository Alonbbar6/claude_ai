from datetime import datetime

import pytest

from app.models import Channel, Notification, NotificationPreferences, Order, Restaurant, Route, User
from app.notifications.channels import BaseChannel, ChannelError, SimulatedChannel
from app.notifications.events import ORDER_STATUS_CHANGED, Event, EventBus
from app.notifications.service import NotificationService, in_quiet_hours


class FlakyChannel(BaseChannel):
    """Fails the first ``fail_first`` attempts, then succeeds."""

    name = Channel.PUSH

    def __init__(self, fail_first: int):
        self.fail_first = fail_first
        self.calls = 0

    async def send(self, user, n):
        self.calls += 1
        if self.calls <= self.fail_first:
            raise ChannelError("boom")
        return "ok"


RESTAURANT = Restaurant(id="r1", name="Taco Spot", cuisine="Mexican", lat=0, lng=0, avg_prep_min=10, menu=[])


def make_user(channels, quiet=(0, 0)):
    return User(
        id="u1", name="Pat", phone="+1", email="p@x.com", lat=0, lng=0,
        prefs=NotificationPreferences(channels=channels, quiet_start=quiet[0], quiet_end=quiet[1]),
    )


def make_order():
    return Order(user_id="u1", restaurant_id="r1", lines=[], route=Route(distance_km=2.0, duration_min=6.0, source="test"))


def make_service(channels, user, clock=lambda: datetime(2026, 1, 1, 12, 0)):
    bus = EventBus()
    svc = NotificationService(
        bus, channels, {"u1": user}, {"r1": RESTAURANT}, retry_delay=0, clock=clock
    )
    return bus, svc


@pytest.mark.parametrize("hour,start,end,expected", [
    (12, 0, 0, False),     # disabled
    (23, 22, 8, True),     # wraps midnight, late evening
    (3, 22, 8, True),      # wraps midnight, early morning
    (12, 22, 8, False),
    (14, 13, 15, True),    # same-day window
])
def test_quiet_hours(hour, start, end, expected):
    assert in_quiet_hours(hour, start, end) is expected


async def test_status_event_sends_to_each_preferred_channel():
    push = SimulatedChannel(Channel.PUSH, failure_rate=0)
    sms = SimulatedChannel(Channel.SMS, failure_rate=0)
    user = make_user([Channel.PUSH, Channel.SMS])
    bus, svc = make_service({Channel.PUSH: push, Channel.SMS: sms}, user)

    await bus.publish(Event(ORDER_STATUS_CHANGED, {"order": make_order()}))

    assert len(svc.notifications) == 1
    n = svc.notifications[0]
    assert n.kind == "placed" and "Taco Spot" in n.body
    assert {d.channel for d in svc.deliveries_for(n.id)} == {Channel.PUSH, Channel.SMS}
    assert all(d.status == "sent" for d in svc.deliveries)


async def test_retry_then_success():
    ch = FlakyChannel(fail_first=2)
    bus, svc = make_service({Channel.PUSH: ch}, make_user([Channel.PUSH]))
    await bus.publish(Event(ORDER_STATUS_CHANGED, {"order": make_order()}))
    rec = svc.deliveries[0]
    assert rec.status == "sent" and rec.attempts == 3 and ch.calls == 3


async def test_gives_up_after_max_attempts():
    ch = FlakyChannel(fail_first=99)
    bus, svc = make_service({Channel.PUSH: ch}, make_user([Channel.PUSH]))
    await bus.publish(Event(ORDER_STATUS_CHANGED, {"order": make_order()}))
    rec = svc.deliveries[0]
    assert rec.status == "failed" and rec.attempts == 3 and ch.calls == 3


async def test_dedup_same_status_for_same_order():
    ch = SimulatedChannel(Channel.PUSH, failure_rate=0)
    bus, svc = make_service({Channel.PUSH: ch}, make_user([Channel.PUSH]))
    order = make_order()
    await bus.publish(Event(ORDER_STATUS_CHANGED, {"order": order}))
    await bus.publish(Event(ORDER_STATUS_CHANGED, {"order": order}))
    assert len(svc.notifications) == 1


async def test_delayed_alerts_may_repeat():
    ch = SimulatedChannel(Channel.PUSH, failure_rate=0)
    bus, svc = make_service({Channel.PUSH: ch}, make_user([Channel.PUSH]))
    order = make_order()
    await svc.notify_order(order, "delayed", delay_min=6)
    await svc.notify_order(order, "delayed", delay_min=12)
    assert len(svc.notifications) == 2


async def test_quiet_hours_defer_non_urgent_and_flush():
    ch = SimulatedChannel(Channel.PUSH, failure_rate=0)
    user = make_user([Channel.PUSH], quiet=(22, 8))
    bus, svc = make_service({Channel.PUSH: ch}, user, clock=lambda: datetime(2026, 1, 1, 23, 30))
    order = make_order()

    await svc.notify_order(order, "confirmed")  # not urgent -> deferred
    assert svc.deliveries[-1].status == "deferred" and len(svc.deferred) == 1

    await svc.notify_order(order, "picked_up")  # urgent -> goes through
    assert svc.deliveries[-1].status == "sent"

    assert await svc.flush_deferred() == 1
    assert svc.deliveries[-1].status == "sent" and not svc.deferred


async def test_unconfigured_channel_is_skipped():
    bus, svc = make_service({}, make_user([Channel.EMAIL]))
    await svc.dispatch(Notification(user_id="u1", order_id=None, kind="x", title="t", body="b"))
    assert svc.deliveries[0].status == "skipped"
