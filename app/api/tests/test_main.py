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
