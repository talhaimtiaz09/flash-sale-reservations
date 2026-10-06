"""Scheduled sweeper: delete expired holds and return their stock.

TTL deletes can lag expiry by hours, and until then the units are stuck in a
hold nobody can confirm. The sweeper finds expired holds through the sparse
live-holds index (only HELD holds carry held_bucket) and, in one transaction:

  [0] deletes the hold, only if it is still HELD and expired
  [1] puts the units back on its shard
  [2] writes the RETURN# marker, only if it isn't there yet

A confirm that wins the race makes [0] fail, and nothing changes. Overlapping
runs are safe for the same reason, so the function has no reserved
concurrency to stop them.
"""

import logging

from botocore.exceptions import ClientError

from shared import db

log = logging.getLogger()
log.setLevel(logging.INFO)

STOP_WITH_MS_LEFT = 5000


def handler(event, context):
    now = db.now()
    counts = {}
    for bucket in range(db.HOLD_BUCKETS):
        for hold in expired_holds(bucket, now):
            if context.get_remaining_time_in_millis() < STOP_WITH_MS_LEFT:
                log.info("out of time, next run continues", extra=counts)
                return counts
            outcome = sweep(hold, now)
            counts[outcome] = counts.get(outcome, 0) + 1
    log.info("sweep finished", extra=counts)
    return counts


def expired_holds(bucket, now):
    paginator = db.ddb().get_paginator("query")
    pages = paginator.paginate(
        TableName=db.TABLE,
        IndexName=db.LIVE_HOLDS_INDEX,
        KeyConditionExpression="held_bucket = :b AND expires_at <= :now",
        ExpressionAttributeValues={":b": db.s(f"B#{bucket}"), ":now": db.n(now)},
        PaginationConfig={"PageSize": 100},
    )
    for page in pages:
        for item in page["Items"]:
            yield db.plain(item)


def sweep(hold, now):
    delete = {
        "Delete": {
            "TableName": db.TABLE,
            "Key": db.key(hold["pk"], hold["sk"]),
            "ConditionExpression": "#status = :held AND expires_at <= :now",
            "ExpressionAttributeNames": {"#status": "status"},
            "ExpressionAttributeValues": {":held": db.s(db.HELD), ":now": db.n(now)},
        }
    }
    try:
        db.ddb().transact_write_items(TransactItems=[delete, *db.return_stock_items(hold, now)])
    except ClientError as exc:
        codes = db.cancellation_codes(exc)
        if codes is None:
            raise
        if codes[0] == "ConditionalCheckFailed":
            return "skipped"  # confirmed or already gone; the index lags the table
        if "ConditionalCheckFailed" in codes[1:]:
            # Stock already went back (or the sale is gone). Only the hold is left.
            return delete_only(delete["Delete"])
        return "retry_later"  # conflict or throttle: the next run picks it up

    return "returned"


def delete_only(request):
    try:
        db.ddb().delete_item(**request)
    except ClientError as exc:
        if db.error_code(exc) == "ConditionalCheckFailedException":
            return "skipped"
        raise
    return "cleaned"
