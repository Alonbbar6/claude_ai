"""Distance & travel-time providers.

``GoogleMapsProvider`` calls the Routes API route matrix (with live traffic) and
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

ROUTE_MATRIX_URL = "https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix"
ROUTES_TRAVEL_MODE = {"driving": "DRIVE", "walking": "WALK"}

# Fallback assumptions when Google is unavailable.
SPEED_KMH = {"driving": 19.0, "walking": 4.8}
ROAD_FACTOR = {"driving": 1.3, "walking": 1.2}  # straight-line -> route distance


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
    async def route(self, origin: LatLng, dest: LatLng, mode: str = "driving") -> RouteEstimate:
        """``mode`` is "driving" or "walking"."""
        raise NotImplementedError


class HaversineProvider(RouteProvider):
    async def route(self, origin: LatLng, dest: LatLng, mode: str = "driving") -> RouteEstimate:
        km = haversine_km(origin.lat, origin.lng, dest.lat, dest.lng) * ROAD_FACTOR[mode]
        return RouteEstimate(
            distance_km=round(km, 2),
            duration_min=round(km / SPEED_KMH[mode] * 60, 1),
            source="haversine",
        )


class GoogleMapsProvider(RouteProvider):
    """Routes API ``computeRouteMatrix``; driving uses ``TRAFFIC_AWARE`` so we
    get traffic-aware durations. Results are cached briefly; traffic doesn't change by the
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

    async def route(self, origin: LatLng, dest: LatLng, mode: str = "driving") -> RouteEstimate:
        key = (str(origin), str(dest), mode)
        hit = self._cache.get(key)
        if hit and time.monotonic() - hit[0] < self.cache_ttl:
            return hit[1]
        try:
            est = await self._fetch(origin, dest, mode)
        except Exception as exc:  # network, quota, bad key, malformed body...
            log.warning("Google Routes API failed (%s); using fallback", exc)
            return await self.fallback.route(origin, dest, mode)
        self._cache[key] = (time.monotonic(), est)
        return est

    async def _fetch(self, origin: LatLng, dest: LatLng, mode: str) -> RouteEstimate:
        body = {
            "origins": [_waypoint(origin)],
            "destinations": [_waypoint(dest)],
            "travelMode": ROUTES_TRAVEL_MODE[mode],
        }
        if mode == "driving":
            body["routingPreference"] = "TRAFFIC_AWARE"  # not allowed for WALK
        resp = await self.client.post(
            ROUTE_MATRIX_URL,
            json=body,
            headers={
                "X-Goog-Api-Key": self.api_key,
                "X-Goog-FieldMask": "originIndex,destinationIndex,status,condition,distanceMeters,duration",
            },
        )
        data = resp.json()
        if resp.status_code != 200:
            err = data.get("error", {}) if isinstance(data, dict) else {}
            raise RuntimeError(f"HTTP {resp.status_code} {err.get('status', '')} {err.get('message', '')}")
        el = data[0]
        if el.get("condition") != "ROUTE_EXISTS":
            raise RuntimeError(f"condition={el.get('condition')} status={el.get('status')}")
        seconds = float(el["duration"].rstrip("s"))
        return RouteEstimate(
            distance_km=round(el.get("distanceMeters", 0) / 1000, 2),
            duration_min=round(seconds / 60, 1),
            source="google",
        )

    async def aclose(self) -> None:
        await self.client.aclose()


def _waypoint(p: LatLng) -> dict:
    return {"waypoint": {"location": {"latLng": {"latitude": p.lat, "longitude": p.lng}}}}


def get_provider() -> RouteProvider:
    key = os.environ.get("GOOGLE_MAPS_API_KEY", "").strip()
    if key:
        log.info("Using Google Routes API for routing")
        return GoogleMapsProvider(key)
    log.info("GOOGLE_MAPS_API_KEY not set; using haversine routing fallback")
    return HaversineProvider()
