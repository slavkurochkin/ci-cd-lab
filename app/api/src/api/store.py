"""Order persistence, backed by DynamoDB.

This is the only part of the service that needs something outside its own
process, which makes it the only part that needs an integration test. Lab 03
runs that test against DynamoDB Local as a service container; Capstone B points
the same code at a real table.

DynamoDB stores numbers as ``Decimal`` and rejects ``float`` outright, so
conversion happens at the boundary in both directions. Getting that wrong is
the classic first DynamoDB bug, and it is invisible to a mocked test.
"""

import os
from decimal import Decimal
from typing import Any

import boto3

DEFAULT_TABLE = "lab-orders"


def _to_dynamo(value: Any) -> Any:
    """floats are not a DynamoDB type. Convert via str to avoid binary float error."""
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, dict):
        return {k: _to_dynamo(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_to_dynamo(v) for v in value]
    return value


def _from_dynamo(value: Any) -> Any:
    """Decimal is not JSON-serializable. Convert back on the way out."""
    if isinstance(value, Decimal):
        as_float = float(value)
        return int(as_float) if as_float.is_integer() else as_float
    if isinstance(value, dict):
        return {k: _from_dynamo(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_from_dynamo(v) for v in value]
    return value


def dynamodb_resource():
    """A DynamoDB resource, pointed at DynamoDB Local when DYNAMODB_ENDPOINT is set.

    That single environment variable is what lets identical code run against a
    service container in CI and a real table in AWS.
    """
    kwargs: dict[str, Any] = {"region_name": os.getenv("AWS_REGION", "us-east-1")}
    endpoint = os.getenv("DYNAMODB_ENDPOINT")
    if endpoint:
        kwargs["endpoint_url"] = endpoint
        # DynamoDB Local validates that credentials exist, not that they are real.
        kwargs.setdefault("aws_access_key_id", "local")
        kwargs.setdefault("aws_secret_access_key", "local")
    return boto3.resource("dynamodb", **kwargs)


class OrderStore:
    """Reads and writes priced orders."""

    def __init__(self, table_name: str | None = None, resource: Any = None) -> None:
        self.table_name = table_name or os.getenv("ORDERS_TABLE", DEFAULT_TABLE)
        self._resource = resource or dynamodb_resource()

    @property
    def table(self) -> Any:
        return self._resource.Table(self.table_name)

    def create_table(self) -> None:
        """Create the table if it is absent. For local and CI use only.

        In AWS the table is Terraform's job -- an application that creates its
        own infrastructure is an application whose infrastructure is not in Git.
        """
        existing = [t.name for t in self._resource.tables.all()]
        if self.table_name in existing:
            return
        self._resource.create_table(
            TableName=self.table_name,
            KeySchema=[{"AttributeName": "order_id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "order_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        ).wait_until_exists()

    def put_order(self, order_id: str, breakdown: dict[str, float]) -> None:
        self.table.put_item(Item=_to_dynamo({"order_id": order_id, **breakdown}))

    def get_order(self, order_id: str) -> dict[str, Any] | None:
        item = self.table.get_item(Key={"order_id": order_id}).get("Item")
        return _from_dynamo(item) if item else None
