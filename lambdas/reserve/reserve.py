"""POST /sales/{sale_id}/reserve: hold `qty` units for HOLD_SECONDS.

One transaction does three things or nothing:
  [0] take qty from one stock shard, only if that shard has qty left
  [1] write the hold
  [2] write the Idempotency-Key record, only if the key is new

There is no read-then-write anywhere, so two buyers can't both take the last
unit. A cancelled transaction says which item failed (CancellationReasons),
which is how a replayed key is told apart from an empty shard.
"""

import logging
import os
import random
import re
import time
import uuid
from collections import Counter, deque

from botocore.exceptions import ClientError

from shared import db
from shared.responses import busy, error, header, json_body, path_param, respond

log = logging.getLogger()
log.setLevel(logging.INFO)

MAX_QTY = int(os.environ.get("MAX_QTY", "4"))
# A transaction that touches an item another transaction is writing is
# cancelled with TransactionConflict. Each shard gets this many extra tries
# before the request gives up with a 429.
CONFLICT_RETRIES = 2

ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
KEY_PATTERN = re.compile(r"^[A-Za-z0-9_-]{8,64}$")

# A sale's META item never changes after seeding, so each warm container reads
# it once. Without this, every reserve would also hit that one item.
_sales = {}


def handler(event, context):
    sale_id = path_param(event, "sale_id")
    if not ID_PATTERN.match(sale_id):
        return error(404, "sale_not_found", "No such sale.")

    idem = header(event, "Idempotency-Key")
    if not KEY_PATTERN.match(idem):
        return error(400, "bad_idempotency_key", "Send an Idempotency-Key header: 8-64 of A-Z a-z 0-9 _ -")

    body = json_body(event)
    qty = body.get("qty") if isinstance(body, dict) else None
    if type(qty) is not int or not 1 <= qty <= MAX_QTY:
        return error(400, "bad_qty", f"qty must be a whole number from 1 to {MAX_QTY}.")

    try:
        sale = load_sale(sale_id)
        if sale is None:
            return error(404, "sale_not_found", "No such sale.")
        return reserve(sale_id, sale["shard_count"], qty, idem)
    except ClientError as exc:
        if db.is_throttle(exc):
            log.warning("dynamodb throttled", extra={"sale_id": sale_id})
            return busy()
        raise


def load_sale(sale_id):
    if sale_id not in _sales:
        sale = db.get(db.sale_key(sale_id))
        if sale is None:
            return None
        _sales[sale_id] = sale
    return _sales[sale_id]


def reserve(sale_id, shard_count, qty, idem):
    now = db.now()
    hold_id = uuid.uuid4().hex
    # Random order spreads buyers over the shards; walking the rest means a
    # buyer only sees "sold out" once every shard has said no.
    queue = deque(random.sample(range(shard_count), shard_count))
    conflicts = Counter()
    unsure = set()  # shards we gave up on without learning they were empty

    while queue:
        shard = queue.popleft()
        try:
            db.ddb().transact_write_items(TransactItems=hold_items(sale_id, shard, qty, idem, hold_id, now))
        except ClientError as exc:
            codes = db.cancellation_codes(exc)
            if codes is None:
                raise
            if codes[2] == "ConditionalCheckFailed":
                return replay(idem, sale_id, qty)
            if codes[0] == "ConditionalCheckFailed":
                continue  # this shard can't cover qty; try the next one
            if "TransactionConflict" in codes:
                conflicts[shard] += 1
                if conflicts[shard] <= CONFLICT_RETRIES:
                    queue.append(shard)
                    time.sleep(random.uniform(0, 0.02))
                else:
                    unsure.add(shard)
                continue
            raise
        log.info("hold created", extra={"sale_id": sale_id, "shard": shard, "qty": qty})
        return respond(201, hold_view(hold_id, sale_id, qty, db.HELD, now + db.HOLD_SECONDS, now))

    if unsure:
        return busy()
    return error(409, "sold_out", f"No stock shard has {qty} unit(s) left.")


def hold_items(sale_id, shard, qty, idem, hold_id, now):
    expires_at = now + db.HOLD_SECONDS
    return [
        {
            "Update": {
                "TableName": db.TABLE,
                "Key": db.shard_key(sale_id, shard),
                "UpdateExpression": "SET stock = stock - :qty",
                "ConditionExpression": "stock >= :qty",
                "ExpressionAttributeValues": {":qty": db.n(qty)},
            }
        },
        {
            "Put": {
                "TableName": db.TABLE,
                "Item": {
                    **db.hold_key(hold_id),
                    "sale_id": db.s(sale_id),
                    "shard": db.n(shard),
                    "qty": db.n(qty),
                    "status": db.s(db.HELD),
                    "created_at": db.n(now),
                    "expires_at": db.n(expires_at),
                    # TTL can lag by hours; it is cleanup, never the expiry check.
                    "ttl": db.n(expires_at),
                    # Present only while HELD: this is what puts the hold in
                    # the sparse live-holds index the sweeper reads. Spread
                    # over buckets so the index has no single hot partition.
                    "held_bucket": db.s(f"B#{random.randrange(db.HOLD_BUCKETS)}"),
                },
            }
        },
        {
            "Put": {
                "TableName": db.TABLE,
                "Item": {
                    **db.idem_key(idem),
                    "hold_id": db.s(hold_id),
                    "sale_id": db.s(sale_id),
                    "qty": db.n(qty),
                    "ttl": db.n(now + db.IDEM_SECONDS),
                },
                "ConditionExpression": "attribute_not_exists(pk)",
            }
        },
    ]


def replay(idem, sale_id, qty):
    """The key was used before: answer with that hold, never a new one."""
    record = db.get(db.idem_key(idem), consistent=True)
    if record is None:
        # Only if the record expired between the failed write and this read.
        return busy()
    if record["sale_id"] != sale_id or record["qty"] != qty:
        return error(422, "idempotency_key_reused", "This Idempotency-Key was used for a different request.")
    hold = db.get(db.hold_key(record["hold_id"]), consistent=True)
    if hold is None:
        # Swept or deleted by TTL after it expired.
        return respond(200, hold_view(record["hold_id"], sale_id, qty, "EXPIRED", None, db.now()))
    return respond(
        200, hold_view(record["hold_id"], sale_id, qty, hold["status"], hold.get("expires_at"), db.now())
    )


def hold_view(hold_id, sale_id, qty, status, expires_at, now):
    if status == db.HELD and expires_at is not None and expires_at <= now:
        status = "EXPIRED"
    return {"hold_id": hold_id, "sale_id": sale_id, "qty": qty, "status": status, "expires_at": expires_at}
