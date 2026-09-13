"""HTTP surface for the sample API service."""

import os

from fastapi import FastAPI, HTTPException
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
    items = [LineItem(sku=i.sku, quantity=i.quantity, unit_price=i.unit_price) for i in order.items]
    try:
        return price_order(items)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
