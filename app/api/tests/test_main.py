import pytest
from fastapi.testclient import TestClient

from api.main import app

client = TestClient(app)


def test_healthz():
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz():
    assert client.get("/readyz").status_code == 200


def test_version_reports_unknown_sha_when_unstamped(monkeypatch):
    monkeypatch.delenv("GIT_SHA", raising=False)
    body = client.get("/version").json()
    assert body["git_sha"] == "unknown"
    assert "version" in body


def test_version_reports_stamped_sha(monkeypatch):
    monkeypatch.setenv("GIT_SHA", "abc123")
    assert client.get("/version").json()["git_sha"] == "abc123"


def test_price_endpoint_returns_breakdown():
    response = client.post(
        "/orders/price",
        json={"items": [{"sku": "A", "quantity": 20, "unit_price": 4.0}]},
    )
    assert response.status_code == 200
    assert response.json()["total"] == 72.0


def test_price_endpoint_rejects_empty_order():
    response = client.post("/orders/price", json={"items": []})
    assert response.status_code == 422


class FakeStore:
    """In-memory stand-in for OrderStore, at the endpoint boundary.

    The DynamoDB boundary itself is tested against a real DynamoDB in
    tests/integration. This only checks what the endpoints do with a store.
    """

    def __init__(self):
        self.orders = {}

    def put_order(self, order_id, breakdown):
        self.orders[order_id] = {"order_id": order_id, **breakdown}

    def get_order(self, order_id):
        return self.orders.get(order_id)


@pytest.fixture
def store():
    from api.main import get_store

    fake = FakeStore()
    app.dependency_overrides[get_store] = lambda: fake
    yield fake
    app.dependency_overrides.clear()


def test_create_order_prices_and_stores_it(store):
    response = client.post(
        "/orders", json={"items": [{"sku": "A", "quantity": 20, "unit_price": 4.0}]}
    )
    assert response.status_code == 201
    body = response.json()
    assert body["total"] == 72.0
    assert store.orders[body["order_id"]]["total"] == 72.0


def test_create_order_rejects_an_empty_order_without_storing_it(store):
    assert client.post("/orders", json={"items": []}).status_code == 422
    assert store.orders == {}


def test_get_order_returns_what_was_stored(store):
    order_id = client.post(
        "/orders", json={"items": [{"sku": "B", "quantity": 1, "unit_price": 10.0}]}
    ).json()["order_id"]
    response = client.get(f"/orders/{order_id}")
    assert response.status_code == 200
    assert response.json()["order_id"] == order_id


def test_get_order_404s_for_an_unknown_id(store):
    assert client.get("/orders/does-not-exist").status_code == 404


def test_get_store_builds_the_real_store_lazily(monkeypatch):
    from api import main

    main.get_store.cache_clear()
    monkeypatch.setenv("ORDERS_TABLE", "some-table")
    store = main.get_store()
    assert store.table_name == "some-table"
    main.get_store.cache_clear()


ORDER = {"items": [{"sku": "A", "quantity": 1, "unit_price": 10.0}]}


class StaticFlags:
    def __init__(self, **values):
        self.values = values

    def enabled(self, name):
        return self.values.get(name, False)


def test_quote_is_404_while_the_flag_is_off():
    from api.main import get_flags

    app.dependency_overrides[get_flags] = lambda: StaticFlags(quotes=False)
    try:
        assert client.post("/orders/quote", json=ORDER).status_code == 404
    finally:
        app.dependency_overrides.clear()


def test_quote_answers_when_the_flag_is_on():
    from api.main import get_flags

    app.dependency_overrides[get_flags] = lambda: StaticFlags(quotes=True)
    try:
        response = client.post("/orders/quote", json=ORDER)
        assert response.status_code == 200
        assert response.json()["valid_for_seconds"] == 900
        assert response.json()["total"] > 0
    finally:
        app.dependency_overrides.clear()


def test_get_flags_is_a_shared_instance():
    from api.main import get_flags

    assert get_flags() is get_flags()


def test_every_response_names_its_build(monkeypatch):
    monkeypatch.setenv("GIT_SHA", "abc123")
    assert client.get("/healthz").headers["x-build"] == "abc123"


def test_metrics_count_requests_by_route_and_status():
    client.get("/healthz")
    client.get("/no/such/path")
    body = client.get("/metrics").text
    assert 'api_requests_total{method="GET",route="/healthz",status="200"}' in body
    assert 'route="unmatched",status="404"' in body
