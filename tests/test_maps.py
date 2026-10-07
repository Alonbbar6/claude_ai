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
    return httpx.Response(200, json={
        "status": "OK",
        "rows": [{"elements": [{
            "status": "OK",
            "distance": {"value": 2400},
            "duration": {"value": 420},
            "duration_in_traffic": {"value": 600},
        }]}],
    })


async def test_google_uses_traffic_duration_and_caches():
    calls = []

    def handler(request):
        calls.append(request.url)
        return google_ok(request)

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    provider = GoogleMapsProvider("test-key", client=client)

    est = await provider.route(MIAMI, NEARBY)
    assert est.source == "google"
    assert est.distance_km == 2.4
    assert est.duration_min == 10.0  # duration_in_traffic, not duration
    assert "departure_time=now" in str(calls[0]) and "key=test-key" in str(calls[0])

    await provider.route(MIAMI, NEARBY)
    assert len(calls) == 1  # cached


async def test_google_falls_back_on_error():
    def handler(request):
        return httpx.Response(200, json={"status": "REQUEST_DENIED", "error_message": "bad key"})

    provider = GoogleMapsProvider("bad", client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    est = await provider.route(MIAMI, NEARBY)
    assert est.source == "haversine"


async def test_google_falls_back_on_network_failure():
    def handler(request):
        raise httpx.ConnectError("boom")

    provider = GoogleMapsProvider("k", client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    est = await provider.route(MIAMI, NEARBY)
    assert est.source == "haversine"
