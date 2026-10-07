"""Delivery channels.

Push, SMS and email are simulated: they log the message and randomly fail a
small fraction of the time so the retry path is exercised. The WebSocket
channel is real and streams to connected browsers.
"""

from __future__ import annotations

import asyncio
import logging
import random
from abc import ABC, abstractmethod

from app.models import Channel, Notification, User

log = logging.getLogger(__name__)


class ChannelError(Exception):
    pass


class BaseChannel(ABC):
    name: Channel

    @abstractmethod
    async def send(self, user: User, n: Notification) -> str:
        """Deliver ``n`` and return a short detail string. Raise ChannelError
        on a transient failure so the service can retry."""


class SimulatedChannel(BaseChannel):
    """Logs instead of calling a provider. ``failure_rate`` is per attempt."""

    def __init__(self, name: Channel, failure_rate: float = 0.15, seed: int | None = None):
        self.name = name
        self.failure_rate = failure_rate
        self._rng = random.Random(seed)
        self.sent: list[tuple[str, str]] = []  # (user_id, notification_id)

    def _address(self, user: User) -> str:
        return {
            Channel.PUSH: f"device:{user.id}",
            Channel.SMS: user.phone,
            Channel.EMAIL: user.email,
        }[self.name]

    async def send(self, user: User, n: Notification) -> str:
        await asyncio.sleep(0)  # yield like a real network call would
        if self._rng.random() < self.failure_rate:
            raise ChannelError(f"{self.name.value} provider timeout")
        addr = self._address(user)
        self.sent.append((user.id, n.id))
        log.info("[%s -> %s] %s: %s", self.name.value, addr, n.title, n.body)
        return f"delivered to {addr}"


class WebSocketChannel(BaseChannel):
    """Fan out to every open socket for the user."""

    name = Channel.WEBSOCKET

    def __init__(self) -> None:
        self._sockets: dict[str, set] = {}

    def connect(self, user_id: str, ws) -> None:
        self._sockets.setdefault(user_id, set()).add(ws)

    def disconnect(self, user_id: str, ws) -> None:
        self._sockets.get(user_id, set()).discard(ws)

    def connections(self, user_id: str) -> int:
        return len(self._sockets.get(user_id, ()))

    async def send(self, user: User, n: Notification) -> str:
        sockets = list(self._sockets.get(user.id, ()))
        if not sockets:
            raise ChannelError("no open websocket")
        payload = n.model_dump(mode="json")
        delivered = 0
        for ws in sockets:
            try:
                await ws.send_json({"type": "notification", "data": payload})
                delivered += 1
            except Exception:  # socket went away mid-send
                self.disconnect(user.id, ws)
        if not delivered:
            raise ChannelError("all websockets closed")
        return f"pushed to {delivered} socket(s)"
