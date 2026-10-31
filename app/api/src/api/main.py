"""HTTP surface for the sample API service."""

import os
import uuid
from functools import lru_cache
from typing import Annotated, Any, Protocol

from fastapi import Depends, FastAPI, HTTPException, Path, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Info, generate_latest
from pydantic import BaseModel, Field

from api import __version__
from api.flags import Flags
from api.orders import LineItem, price_order

app = FastAPI(title="lab-api", version=__version__)

# Project 15. One counter, labelled by route template and status, so a query
# can ask "what share of this version's requests failed". The route template
# (/orders/{order_id}), not the path: a label per order ID would grow without
# bound.
REQUESTS = Counter("api_requests_total", "HTTP requests served", ["method", "route", "status"])

# Project 16. One series per running build, value 1: a dashboard marks a
# deploy where a new git_sha appears, with nothing posted by the pipeline.
BUILD = Info("api_build", "The build serving requests")
BUILD.info({"git_sha": os.getenv("GIT_SHA", "unknown"), "version": __version__})


@app.middleware("http")
async def record(request: Request, call_next):  # type: ignore[no-untyped-def]
    response: Response = await call_next(request)
    route = request.scope.get("route")
    REQUESTS.labels(
        request.method, getattr(route, "path", "unmatched"), str(response.status_code)
    ).inc()
    # Which build answered. A load test counts these to measure how much
    # traffic a canary received.
    response.headers["x-build"] = os.getenv("GIT_SHA", "unknown")
    return response


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


@lru_cache
def get_flags() -> Flags:
    return Flags()


FlagsDep = Annotated[Flags, Depends(get_flags)]


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


@app.get("/metrics")
def metrics() -> Response:
    """Prometheus metrics. Argo Rollouts' analysis reads the error rate here."""
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/orders/quote")
def quote(order: OrderIn, flags: FlagsDep) -> dict[str, Any]:
    """A price that is valid for 15 minutes. Behind the `quotes` flag (Project 15).

    Deployed everywhere, released nowhere until the flag is on: with it off
    the endpoint answers 404, as if it did not exist.
    """
    if not flags.enabled("quotes"):
        raise HTTPException(status_code=404, detail="Not Found")
    return {**_priced(order), "valid_for_seconds": 900}


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


# Order IDs are 32 hex characters (uuid4().hex). Anything over 64 is not an
# ID this service issued. Before Project 16 an ID over 2,048 bytes went to
# DynamoDB, which rejects keys that long, and the client's mistake came back
# as a 500: counted against the service's own error rate.
OrderId = Annotated[str, Path(min_length=1, max_length=64)]


@app.get("/orders/{order_id}")
def get_order(order_id: OrderId, store: StoreDep) -> dict[str, Any]:
    found = store.get_order(order_id)
    if found is None:
        raise HTTPException(status_code=404, detail="order not found")
    return found
