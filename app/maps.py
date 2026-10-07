"""Distance & travel-time providers.

``GoogleMapsProvider`` calls the Distance Matrix API (with live traffic) and
is used whenever ``GOOGLE_MAPS_API_KEY`` is set. ``HaversineProvider`` is the
offline fallback so the app, tests and demo work without a key.

Both return a ``RouteEstimate`` so the rest of the app never cares which
one is active.
"""

from __future__ import annotations

import logging
import os
import time
from dataclasses import dataclass

import httpx

from app.prediction.features import haversine_km

log = logging.getLogger(__name__)

DISTANCE_MATRIX_URL = "https://maps.googleapis.com/maps/api/distancematrix/json"

# Fallback assumptions when Google is unavailable.
CITY_SPEED_KMH = 19.0
ROAD_FACTOR = 1.3  # straight-line -> road distance


@dataclass(frozen=True)
class LatLng:
    lat: float
    lng: float

    def __str__(self) -> str:
        return f"{self.lat:.6f},{self.lng:.6f}"


@dataclass
class RouteEstimate:
    distance_km: float
    duration_min: float  # with traffic when available
    source: str  # "google" | "haversine"


class RouteProvider:
    async def route(self, origin: LatLng, dest: LatLng) -> RouteEstimate:
        raise NotImplementedError


class HaversineProvider(RouteProvider):
    async def route(self, origin: LatLng, dest: LatLng) -> RouteEstimate:
        km = haversine_km(origin.lat, origin.lng, dest.lat, dest.lng) * ROAD_FACTOR
        return RouteEstimate(
            distance_km=round(km, 2),
            duration_min=round(km / CITY_SPEED_KMH * 60, 1),
            source="haversine",
        )


class GoogleMapsProvider(RouteProvider):
    """Distance Matrix with ``departure_time=now`` so we get traffic-aware
    durations. Results are cached briefly; traffic doesn't change by the
    second and the API is billed per element."""

    def __init__(
        self,
        api_key: str,
        *,
        client: httpx.AsyncClient | None = None,
        cache_ttl: float = 60.0,
        fallback: RouteProvider | None = None,
    ) -> None:
        self.api_key = api_key
        self.client = client or httpx.AsyncClient(timeout=5.0)
        self.cache_ttl = cache_ttl
        self.fallback = fallback or HaversineProvider()
        self._cache: dict[tuple[str, str], tuple[float, RouteEstimate]] = {}

    async def route(self, origin: LatLng, dest: LatLng) -> RouteEstimate:
        key = (str(origin), str(dest))
        hit = self._cache.get(key)
        if hit and time.monotonic() - hit[0] < self.cache_ttl:
            return hit[1]
        try:
            est = await self._fetch(origin, dest)
        except Exception as exc:  # network, quota, bad key, malformed body...
            log.warning("Google Distance Matrix failed (%s); using fallback", exc)
            return await self.fallback.route(origin, dest)
        self._cache[key] = (time.monotonic(), est)
        return est

    async def _fetch(self, origin: LatLng, dest: LatLng) -> RouteEstimate:
        resp = await self.client.get(
            DISTANCE_MATRIX_URL,
            params={
                "origins": str(origin),
                "destinations": str(dest),
                "mode": "driving",
                "departure_time": "now",
                "key": self.api_key,
            },
        )
        resp.raise_for_status()
        body = resp.json()
        if body.get("status") != "OK":
            raise RuntimeError(f"status={body.get('status')} {body.get('error_message', '')}")
        el = body["rows"][0]["elements"][0]
        if el.get("status") != "OK":
            raise RuntimeError(f"element status={el.get('status')}")
        seconds = el.get("duration_in_traffic", el["duration"])["value"]
        return RouteEstimate(
            distance_km=round(el["distance"]["value"] / 1000, 2),
            duration_min=round(seconds / 60, 1),
            source="google",
        )

    async def aclose(self) -> None:
        await self.client.aclose()


def get_provider() -> RouteProvider:
    key = os.environ.get("GOOGLE_MAPS_API_KEY", "").strip()
    if key:
        log.info("Using Google Distance Matrix for routing")
        return GoogleMapsProvider(key)
    log.info("GOOGLE_MAPS_API_KEY not set; using haversine routing fallback")
    return HaversineProvider()
