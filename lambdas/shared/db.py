"""DynamoDB access shared by every function.

All five functions use one table. Key layout:

    SALE#{id}       META        total, shard_count, created_at
    SALE#{id}       SHARD#{n}   stock
    HOLD#{id}       HOLD        sale_id, shard, qty, status, expires_at, ttl, held_bucket
    IDEM#{key}      IDEM        hold_id, sale_id, qty, ttl
    RETURN#{hold}   RETURN      marker: this hold's units went back once
"""

import functools
import os
import time
from decimal import Decimal

import boto3
from boto3.dynamodb.types import TypeDeserializer
from botocore.config import Config

TABLE = os.environ.get("TABLE_NAME", "flash-sale-reservations")
LIVE_HOLDS_INDEX = os.environ.get("LIVE_HOLDS_INDEX", "live-holds")
HOLD_SECONDS = int(os.environ.get("HOLD_SECONDS", "600"))
HOLD_BUCKETS = int(os.environ.get("HOLD_BUCKETS", "10"))
IDEM_SECONDS = 24 * 3600
# Long enough to outlive the 24h stream retention, so a record replayed from
# the stream still finds its marker.
RETURN_MARKER_SECONDS = 7 * 24 * 3600

HELD = "HELD"
CONFIRMED = "CONFIRMED"

THROTTLE_ERRORS = {
    "ThrottlingException",
    "ProvisionedThroughputExceededException",
    "RequestLimitExceeded",
}
THROTTLE_REASONS = {"ThrottlingError", "ProvisionedThroughputExceeded"}

_deserializer = TypeDeserializer()


@functools.cache
def ddb():
    # One retry instead of botocore's default of several. In a burst, a
    # throttled table needs fewer requests, not three copies of each one. The
    # caller gets a 429 and backs off instead.
    config = Config(
        retries={"mode": "standard", "max_attempts": 2},
        connect_timeout=1,
        read_timeout=2,
    )
    return boto3.client("dynamodb", config=config)


def now():
    return int(time.time())


# --- keys and typed values ---------------------------------------------------


def s(value):
    return {"S": str(value)}


def n(value):
    return {"N": str(value)}


def key(pk, sk):
    return {"pk": s(pk), "sk": s(sk)}


def sale_key(sale_id):
    return key(f"SALE#{sale_id}", "META")


def shard_key(sale_id, shard):
    return key(f"SALE#{sale_id}", f"SHARD#{shard}")


def hold_key(hold_id):
    return key(f"HOLD#{hold_id}", "HOLD")


def idem_key(idempotency_key):
    return key(f"IDEM#{idempotency_key}", "IDEM")


def plain(item):
    """DynamoDB-typed item -> plain dict. Every number in this table is an int."""
    out = {}
    for name, value in item.items():
        v = _deserializer.deserialize(value)
        out[name] = int(v) if isinstance(v, Decimal) else v
    return out


def get(item_key, consistent=False):
    resp = ddb().get_item(TableName=TABLE, Key=item_key, ConsistentRead=consistent)
    return plain(resp["Item"]) if "Item" in resp else None


# --- errors --------------------------------------------------------------------


def error_code(exc):
    return exc.response.get("Error", {}).get("Code", "")


def cancellation_codes(exc):
    """Per-item reason codes of a cancelled transaction, in TransactItems order.

    None if the error isn't a cancelled transaction at all.
    """
    if error_code(exc) != "TransactionCanceledException":
        return None
    return [r.get("Code", "None") for r in exc.response.get("CancellationReasons", [])]


def is_throttle(exc):
    codes = cancellation_codes(exc) or []
    return error_code(exc) in THROTTLE_ERRORS or any(c in THROTTLE_REASONS for c in codes)


# --- returning stock ---------------------------------------------------------


def return_stock_items(hold, at):
    """Transaction items that put a hold's units back on its shard, once.

    The RETURN# marker is written in the same transaction as the increment,
    with attribute_not_exists. A retried stream batch, or the sweeper and the
    stream racing for the same hold, can't return the units twice: the second
    attempt fails on the marker and changes nothing.

    Order matters to callers reading CancellationReasons: [shard, marker].
    """
    hold_id = hold["pk"].removeprefix("HOLD#")
    return [
        {
            "Update": {
                "TableName": TABLE,
                "Key": shard_key(hold["sale_id"], hold["shard"]),
                "UpdateExpression": "SET stock = stock + :qty",
                "ConditionExpression": "attribute_exists(pk)",
                "ExpressionAttributeValues": {":qty": n(hold["qty"])},
            }
        },
        {
            "Put": {
                "TableName": TABLE,
                "Item": {
                    **key(f"RETURN#{hold_id}", "RETURN"),
                    "sale_id": s(hold["sale_id"]),
                    "qty": n(hold["qty"]),
                    "returned_at": n(at),
                    "ttl": n(at + RETURN_MARKER_SECONDS),
                },
                "ConditionExpression": "attribute_not_exists(pk)",
            }
        },
    ]
