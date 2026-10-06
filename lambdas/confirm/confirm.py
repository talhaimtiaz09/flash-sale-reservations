"""POST /holds/{hold_id}/confirm: turn a live hold into an order.

A stand-in for payment. The expiry check is done here, against expires_at,
because DynamoDB TTL can delete an expired item hours late. Until it does, the
item still exists and would otherwise look confirmable.
"""

import logging
import re

from botocore.exceptions import ClientError

from shared import db
from shared.responses import busy, error, path_param, respond

log = logging.getLogger()
log.setLevel(logging.INFO)

HOLD_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")


def handler(event, context):
    hold_id = path_param(event, "hold_id")
    if not HOLD_ID_PATTERN.match(hold_id):
        return error(404, "hold_not_found", "No such hold.")

    now = db.now()
    try:
        resp = db.ddb().update_item(
            TableName=db.TABLE,
            Key=db.hold_key(hold_id),
            # Dropping held_bucket takes the hold out of the sweeper's index;
            # dropping ttl keeps the order once it exists.
            UpdateExpression="SET #status = :confirmed, confirmed_at = :now REMOVE #ttl, held_bucket",
            ConditionExpression="#status = :held AND expires_at > :now",
            ExpressionAttributeNames={"#status": "status", "#ttl": "ttl"},
            ExpressionAttributeValues={
                ":held": db.s(db.HELD),
                ":confirmed": db.s(db.CONFIRMED),
                ":now": db.n(now),
            },
            ReturnValues="ALL_NEW",
            ReturnValuesOnConditionCheckFailure="ALL_OLD",
        )
    except ClientError as exc:
        if db.error_code(exc) == "ConditionalCheckFailedException":
            return rejected(exc.response.get("Item"))
        if db.is_throttle(exc):
            return busy()
        raise

    order = db.plain(resp["Attributes"])
    log.info("hold confirmed", extra={"sale_id": order["sale_id"], "qty": order["qty"]})
    return respond(
        200,
        {
            "hold_id": hold_id,
            "sale_id": order["sale_id"],
            "qty": order["qty"],
            "status": order["status"],
            "confirmed_at": order["confirmed_at"],
        },
    )


def rejected(old_item):
    if not old_item:
        return error(404, "hold_not_found", "No such hold. It may have expired and been released.")
    if db.plain(old_item)["status"] == db.CONFIRMED:
        return error(409, "already_confirmed", "This hold is already an order.")
    return error(409, "hold_expired", "This hold expired. Its units are going back on sale.")
