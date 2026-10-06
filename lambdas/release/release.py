"""DynamoDB Streams consumer: return stock when TTL deletes an unconfirmed hold.

Only TTL deletes count. DynamoDB marks them with userIdentity
{type: Service, principalId: dynamodb.amazonaws.com}; a delete by the sweeper
(or anyone else) has no userIdentity and is ignored here, because whoever
deleted it already returned the stock. The event source mapping filters to
the same records, so this check is a second line, not the only one.

Stream batches are retried on failure, so the same record can arrive more
than once. db.return_stock_items makes that safe.
"""

import logging

from botocore.exceptions import ClientError

from shared import db

log = logging.getLogger()
log.setLevel(logging.INFO)


def handler(event, context):
    for record in event.get("Records", []):
        try:
            handle(record)
        except Exception:
            # Report the first failure only. Lambda retries from that sequence
            # number, and everything after it in the batch comes again anyway.
            log.exception("release failed", extra={"event_id": record.get("eventID")})
            return {"batchItemFailures": [{"itemIdentifier": record["dynamodb"]["SequenceNumber"]}]}
    return {"batchItemFailures": []}


def is_ttl_delete(record):
    identity = record.get("userIdentity") or {}
    return (
        record.get("eventName") == "REMOVE"
        and identity.get("type") == "Service"
        and identity.get("principalId") == "dynamodb.amazonaws.com"
    )


def handle(record):
    if not is_ttl_delete(record):
        return "ignored"
    hold = db.plain(record["dynamodb"].get("OldImage", {}))
    if not hold.get("pk", "").startswith("HOLD#") or hold.get("status") != db.HELD:
        return "ignored"  # IDEM / RETURN markers expiring, or a confirmed order

    try:
        db.ddb().transact_write_items(TransactItems=db.return_stock_items(hold, db.now()))
    except ClientError as exc:
        codes = db.cancellation_codes(exc)
        if codes and codes[1] == "ConditionalCheckFailed":
            log.info("stock already returned", extra={"hold": hold["pk"]})
            return "duplicate"
        if codes and codes[0] == "ConditionalCheckFailed":
            log.warning("sale no longer exists", extra={"hold": hold["pk"], "sale_id": hold["sale_id"]})
            return "orphaned"
        raise  # conflict or throttle: fail the record so the batch is retried

    log.info("stock returned", extra={"sale_id": hold["sale_id"], "shard": hold["shard"], "qty": hold["qty"]})
    return "returned"
