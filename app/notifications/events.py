"""Tiny async event bus. Producers publish events; the notification service
(and anything else) subscribes. Decouples order logic from messaging."""

from __future__ import annotations

import asyncio
import logging
from collections import defaultdict
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger(__name__)

Handler = Callable[["Event"], Awaitable[None]]


@dataclass
class Event:
    type: str
    payload: dict[str, Any] = field(default_factory=dict)


class EventBus:
    def __init__(self) -> None:
        self._handlers: dict[str, list[Handler]] = defaultdict(list)

    def subscribe(self, event_type: str, handler: Handler) -> None:
        self._handlers[event_type].append(handler)

    async def publish(self, event: Event) -> None:
        handlers = self._handlers.get(event.type, []) + self._handlers.get("*", [])
        if not handlers:
            return
        results = await asyncio.gather(
            *(h(event) for h in handlers), return_exceptions=True
        )
        for r in results:
            if isinstance(r, Exception):
                log.exception("handler failed for %s", event.type, exc_info=r)


# Event types published by the order service.
ORDER_STATUS_CHANGED = "order.status_changed"
ORDER_ETA_UPDATED = "order.eta_updated"
ORDER_DELAYED = "order.delayed"
ORDER_PICKUP_LEAVE = "order.pickup_leave"  # customer should leave for pickup now
