"""Order pricing rules.

Deliberately small, but with enough branching that a coverage gate and a
mutation to the logic both produce a visible test failure.
"""

from dataclasses import dataclass

BULK_THRESHOLD = 10
BULK_DISCOUNT = 0.10
FREE_SHIPPING_OVER = 50.0
SHIPPING_FLAT = 4.99


@dataclass(frozen=True)
class LineItem:
    sku: str
    quantity: int
    unit_price: float


def subtotal(items: list[LineItem]) -> float:
    """Sum of quantity * unit price, before discounts or shipping."""
    return round(sum(item.quantity * item.unit_price for item in items), 2)


def discount(items: list[LineItem]) -> float:
    """Bulk discount applies per line item, not to the order as a whole."""
    eligible = sum(
        item.quantity * item.unit_price for item in items if item.quantity >= BULK_THRESHOLD
    )
    return round(eligible * BULK_DISCOUNT, 2)


def shipping(discounted_total: float) -> float:
    """Flat rate shipping, waived over the free-shipping threshold."""
    if discounted_total > FREE_SHIPPING_OVER:
        return 0.0
    return SHIPPING_FLAT


def price_order(items: list[LineItem]) -> dict[str, float]:
    """Full price breakdown for an order."""
    if not items:
        raise ValueError("an order must contain at least one line item")
    if any(item.quantity <= 0 for item in items):
        raise ValueError("line item quantity must be positive")

    sub = subtotal(items)
    disc = discount(items)
    after_discount = round(sub - disc, 2)
    ship = shipping(after_discount)

    return {
        "subtotal": sub,
        "discount": disc,
        "shipping": ship,
        "total": round(after_discount + ship, 2),
    }
