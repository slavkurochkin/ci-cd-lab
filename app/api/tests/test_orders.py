import pytest

from api.orders import LineItem, price_order, shipping, subtotal


def item(quantity: int = 1, unit_price: float = 10.0) -> LineItem:
    return LineItem(sku="SKU-1", quantity=quantity, unit_price=unit_price)


def test_subtotal_sums_line_items():
    assert subtotal([item(2, 10.0), item(1, 5.5)]) == 99.9


def test_no_discount_below_bulk_threshold():
    assert price_order([item(9, 1.0)])["discount"] == 0.0


def test_bulk_discount_applies_at_threshold():
    result = price_order([item(10, 1.0)])
    assert result["subtotal"] == 10.0
    assert result["discount"] == 1.0


def test_discount_is_per_line_not_per_order():
    # Two lines of 5 each reach 10 units in total but neither line qualifies.
    result = price_order([item(5, 1.0), item(5, 1.0)])
    assert result["discount"] == 0.0


def test_shipping_charged_under_threshold():
    assert shipping(50.0) == 4.99


def test_shipping_waived_over_threshold():
    assert shipping(50.01) == 0.0


def test_total_combines_discount_and_shipping():
    result = price_order([item(20, 4.0)])
    assert result["subtotal"] == 80.0
    assert result["discount"] == 8.0
    assert result["shipping"] == 0.0
    assert result["total"] == 72.0


def test_empty_order_rejected():
    with pytest.raises(ValueError):
        price_order([])


def test_non_positive_quantity_rejected():
    with pytest.raises(ValueError):
        price_order([item(0, 1.0)])
