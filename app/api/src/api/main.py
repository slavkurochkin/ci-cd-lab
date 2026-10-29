"""HTTP surface for the sample API service."""

import os
import uuid
from functools import lru_cache
from typing import Annotated, Any, Protocol

from fastapi import Depends, FastAPI, HTTPException
from pydantic import BaseModel, Field

from api import __version__
from api.orders import LineItem, price_order

app = FastAPI(title="lab-api", version=__version__)


class LineItemIn(BaseModel):
    sku: str = Field(min_length=1)
    quantity: int
    unit_price: float = Field(ge=0)


class OrderIn(BaseModel):
    items: list[LineItemIn]


class Store(Protocol):
    def put_order(self, order_id: str, breakdown: dict[str, float]) -> None: ...
    def get_order(self, order_id: str) -> dict[str, Any] | None: ...


@lru_cache
def get_store() -> Store:
    """The real store, created on first use rather than at import.

    Importing the app must not need AWS: the unit tests, the container's
    health checks and `uvicorn --reload` all import it without a table.
    Tests replace this with `app.dependency_overrides`.
    """
    from api.store import OrderStore

    return OrderStore()


StoreDep = Annotated[Store, Depends(get_store)]


def _priced(order: OrderIn) -> dict[str, float]:
    items = [LineItem(sku=i.sku, quantity=i.quantity, unit_price=i.unit_price) for i in order.items]
    try:
        return price_order(items)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """Liveness. Cheap, dependency-free, and always true while the process runs."""
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict[str, str]:
    """Readiness. Distinct from liveness on purpose -- Lab 11 gives this real work to do."""
    return {"status": "ready"}


@app.get("/version")
def version() -> dict[str, str]:
    """Identity of the running build. The pipeline stamps GIT_SHA at build time."""
    return {
        "version": __version__,
        "git_sha": os.getenv("GIT_SHA", "unknown"),
        "environment": os.getenv("ENVIRONMENT", "local"),
    }


@app.post("/orders/price")
def price(order: OrderIn) -> dict[str, float]:
    """Price an order. Business logic lives in api.orders, not here."""
    return _priced(order)


@app.post("/orders", status_code=201)
def create_order(order: OrderIn, store: StoreDep) -> dict[str, Any]:
    """Price an order and keep it. Capstone B: the first endpoint that needs DynamoDB."""
    breakdown = _priced(order)
    order_id = uuid.uuid4().hex
    store.put_order(order_id, breakdown)
    return {"order_id": order_id, **breakdown}


@app.get("/orders/{order_id}")
def get_order(order_id: str, store: StoreDep) -> dict[str, Any]:
    found = store.get_order(order_id)
    if found is None:
        raise HTTPException(status_code=404, detail="order not found")
    return found
