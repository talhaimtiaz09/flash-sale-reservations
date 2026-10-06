"""Test setup: a moto DynamoDB table shaped like the Terraform one.

Each function lives in its own folder (lambdas/<name>/<name>.py) and imports
`shared`, the same layout as inside its zip, so those folders go on sys.path.
"""

import os
import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

LAMBDAS = Path(__file__).resolve().parent.parent
for folder in (LAMBDAS, *(LAMBDAS / f for f in ("reserve", "confirm", "get_sale", "release", "sweeper"))):
    sys.path.insert(0, str(folder))

os.environ.update(
    {
        "AWS_DEFAULT_REGION": "us-east-1",
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "TABLE_NAME": "test-table",
        "LIVE_HOLDS_INDEX": "live-holds",
        "HOLD_SECONDS": "600",
        "HOLD_BUCKETS": "3",
        "MAX_QTY": "4",
    }
)

import reserve  # noqa: E402
from helpers import NOW  # noqa: E402
from shared import db  # noqa: E402


@pytest.fixture
def table(monkeypatch):
    with mock_aws():
        db.ddb.cache_clear()
        reserve._sales.clear()
        monkeypatch.setattr(db, "now", lambda: NOW)
        boto3.client("dynamodb").create_table(
            TableName=db.TABLE,
            BillingMode="PAY_PER_REQUEST",
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
                {"AttributeName": "held_bucket", "AttributeType": "S"},
                {"AttributeName": "expires_at", "AttributeType": "N"},
            ],
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            GlobalSecondaryIndexes=[
                {
                    "IndexName": db.LIVE_HOLDS_INDEX,
                    "KeySchema": [
                        {"AttributeName": "held_bucket", "KeyType": "HASH"},
                        {"AttributeName": "expires_at", "KeyType": "RANGE"},
                    ],
                    "Projection": {
                        "ProjectionType": "INCLUDE",
                        "NonKeyAttributes": ["sale_id", "shard", "qty"],
                    },
                }
            ],
        )
        yield db.ddb()
        db.ddb.cache_clear()


@pytest.fixture
def seed(table):
    """seed("s1", [5, 0, 3]) -> a sale with three shards holding 5, 0 and 3 units."""

    def _seed(sale_id, stocks):
        table.put_item(
            TableName=db.TABLE,
            Item={
                **db.sale_key(sale_id),
                "total": db.n(sum(stocks)),
                "shard_count": db.n(len(stocks)),
                "created_at": db.n(NOW),
            },
        )
        for shard, stock in enumerate(stocks):
            table.put_item(TableName=db.TABLE, Item={**db.shard_key(sale_id, shard), "stock": db.n(stock)})

    return _seed


@pytest.fixture
def stock(table):
    def _stock(sale_id, shard):
        return db.get(db.shard_key(sale_id, shard))["stock"]

    return _stock
