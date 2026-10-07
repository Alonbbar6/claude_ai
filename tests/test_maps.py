import json

import httpx
import pytest

from app.maps import GoogleMapsProvider, HaversineProvider, LatLng

MIAMI = LatLng(25.7617, -80.1918)
NEARBY = LatLng(25.7743, -80.1937)


async def test_haversine_fallback_is_sane():
    est = await HaversineProvider().route(MIAMI, NEARBY)
    assert est.source == "haversine"
    assert 1.0 < est.distance_km < 3.0
    assert 3 < est.duration_min < 10


def google_ok(request):
    return httpx.Response(200, json=[{
        "originIndex": 0,
        "destinationIndex": 0,
        "status": {},
        "condition": "ROUTE_EXISTS",
        "distanceMeters": 2400,
        "duration": "600s",
    }])


async def test_google_uses_routes_api_and_caches():
    calls = []

    def handler(request):
        calls.append(request)
        return google_ok(request)

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    provider = GoogleMapsProvider("test-key", client=client)

    est = await provider.route(MIAMI, NEARBY)
    assert est.source == "google"
    assert est.distance_km == 2.4
    assert est.duration_min == 10.0
    req = calls[0]
    body = json.loads(req.content)
    assert req.method == "POST" and "computeRouteMatrix" in str(req.url)
    assert req.headers["X-Goog-Api-Key"] == "test-key" and "key=" not in str(req.url)
    assert body["travelMode"] == "DRIVE" and body["routingPreference"] == "TRAFFIC_AWARE"
    assert body["origins"][0]["waypoint"]["location"]["latLng"] == {"latitude": MIAMI.lat, "longitude": MIAMI.lng}

    await provider.route(MIAMI, NEARBY)
    assert len(calls) == 1  # cached


async def test_google_walking_has_no_traffic_preference():
    bodies = []

    def handler(request):
        bodies.append(json.loads(request.content))
        return google_ok(request)

    provider = GoogleMapsProvider("k", client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    est = await provider.route(MIAMI, NEARBY, mode="walking")
    assert est.source == "google"
    assert bodies[0]["travelMode"] == "WALK" and "routingPreference" not in bodies[0]


async def test_google_falls_back_on_error():
    def handler(request):
        return httpx.Response(403, json={"error": {"code": 403, "status": "PERMISSION_DENIED", "message": "bad key"}})

    provider = GoogleMapsProvider("bad", client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    est = await provider.route(MIAMI, NEARBY)
    assert est.source == "haversine"


async def test_google_falls_back_when_no_route():
    def handler(request):
        return httpx.Response(200, json=[{"originIndex": 0, "destinationIndex": 0, "condition": "ROUTE_NOT_FOUND"}])

    provider = GoogleMapsProvider("k", client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    est = await provider.route(MIAMI, NEARBY, mode="walking")
    assert est.source == "haversine"


async def test_google_falls_back_on_network_failure():
    def handler(request):
        raise httpx.ConnectError("boom")

    provider = GoogleMapsProvider("k", client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    est = await provider.route(MIAMI, NEARBY)
    assert est.source == "haversine"
