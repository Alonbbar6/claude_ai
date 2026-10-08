"""Client for the team's BarMade API (Express + Firestore on Render).

BarMade owns batch-tracked stock, the menu, orders and expiry alerts. It has
no sales channels, thresholds, counts or day-close, so those stay in the
local engine. Ingredient and menu IDs are shared (ING-001…, MENU-001…).
"""

from __future__ import annotations

import os

import httpx

DEFAULT_URL = "https://barmade-riw5.onrender.com"   # moved from barmade-api.onrender.com on 2026-10-07


class BarMadeError(Exception):
    def __init__(self, status: int, code: str, message: str, details: dict | None = None):
        super().__init__(message)
        self.status, self.code, self.message, self.details = status, code, message, details or {}


class BarMadeClient:
    def __init__(self, base_url: str = DEFAULT_URL, timeout: float = 60.0, allow_writes: bool = False):
        # Render's free tier sleeps when idle; the first request can take ~50 s.
        # Writes are off unless explicitly enabled: the API is shared, has no
        # auth and no way to undo an order.
        self.base_url = base_url.rstrip("/")
        self.allow_writes = allow_writes
        self.http = httpx.Client(base_url=self.base_url, timeout=timeout)

    def _unwrap(self, r: httpx.Response):
        try:
            body = r.json()
        except ValueError:
            body = {}
        if r.status_code >= 400:
            err = body.get("error") or {}
            raise BarMadeError(r.status_code, err.get("code", "HTTP_ERROR"),
                               err.get("message", f"BarMade returned {r.status_code}"), err.get("details"))
        return body

    def _list(self, path: str) -> list[dict]:
        return self._unwrap(self.http.get(path)).get("data", [])

    def inventory(self) -> list[dict]:
        return self._list("/api/inventory")

    def menu(self) -> list[dict]:
        return self._list("/api/menu")

    def orders(self) -> list[dict]:
        return self._list("/api/orders")

    def alerts(self) -> list[dict]:
        return self._list("/api/alerts")

    def create_order(self, lines: list[tuple[str, int]]) -> dict:
        """POST /api/orders. Raises BarMadeError (409 INSUFFICIENT_INVENTORY etc.)."""
        if not self.allow_writes:
            raise BarMadeError(403, "WRITES_DISABLED", "Writes to BarMade are disabled (BARMADE_WRITES=off).")
        body = {"items": [{"menuItemId": m, "quantity": q} for m, q in lines]}
        return self._unwrap(self.http.post("/api/orders", json=body)).get("data", {})


def client_from_env() -> BarMadeClient | None:
    """None when BARMADE_SYNC=off; otherwise a read-only client for BARMADE_URL.
    BARMADE_WRITES=on additionally forwards orders (only against a demo tenant)."""
    if os.environ.get("BARMADE_SYNC", "on").lower() in ("off", "0", "false"):
        return None
    writes = os.environ.get("BARMADE_WRITES", "off").lower() in ("on", "1", "true")
    return BarMadeClient(os.environ.get("BARMADE_URL", DEFAULT_URL), allow_writes=writes)
