"""Integration tests for OrderStore.

These need a real DynamoDB. Lab 03 supplies one as a GitHub Actions service
container; locally:

    docker run -d --rm -p 8000:8000 --name dynamodb-local amazon/dynamodb-local
    DYNAMODB_ENDPOINT=http://localhost:8000 uv run pytest -m integration

They are excluded from the default suite by the `integration` marker, so the
fast feedback loop stays fast.
"""

import os
import uuid

import pytest

from api.orders import LineItem, price_order
from api.store import OrderStore

pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def store():
    if not os.getenv("DYNAMODB_ENDPOINT"):
        pytest.skip("DYNAMODB_ENDPOINT is not set -- no DynamoDB to talk to")
    store = OrderStore(table_name=f"lab-orders-test-{uuid.uuid4().hex[:8]}")
    store.create_table()
    return store


def test_round_trip_preserves_the_breakdown(store):
    order_id = f"order-{uuid.uuid4().hex[:8]}"
    breakdown = price_order([LineItem(sku="A", quantity=20, unit_price=4.0)])

    store.put_order(order_id, breakdown)

    assert store.get_order(order_id) == {"order_id": order_id, **breakdown}


def test_floats_survive_the_decimal_boundary(store):
    """DynamoDB rejects float and returns Decimal. A mocked store hides both."""
    order_id = f"order-{uuid.uuid4().hex[:8]}"
    breakdown = price_order([LineItem(sku="A", quantity=1, unit_price=10.0)])
    assert breakdown["shipping"] == 4.99

    store.put_order(order_id, breakdown)
    stored = store.get_order(order_id)

    assert stored is not None
    assert stored["shipping"] == 4.99
    assert isinstance(stored["shipping"], float)


def test_missing_order_returns_none(store):
    assert store.get_order("does-not-exist") is None
