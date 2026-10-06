"""GET /sales/{sale_id}: remaining stock (the sum of the shards) and status.

One Query on the sale's partition returns META and every shard. The read is
eventually consistent, so the number can trail the last few reservations.
"""

import re

from botocore.exceptions import ClientError

from shared import db
from shared.responses import busy, error, path_param, respond

ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def handler(event, context):
    sale_id = path_param(event, "sale_id")
    if not ID_PATTERN.match(sale_id):
        return error(404, "sale_not_found", "No such sale.")

    try:
        resp = db.ddb().query(
            TableName=db.TABLE,
            KeyConditionExpression="pk = :pk",
            ExpressionAttributeValues={":pk": db.s(f"SALE#{sale_id}")},
        )
    except ClientError as exc:
        if db.is_throttle(exc):
            return busy()
        raise

    items = [db.plain(i) for i in resp["Items"]]
    meta = next((i for i in items if i["sk"] == "META"), None)
    if meta is None:
        return error(404, "sale_not_found", "No such sale.")

    shards = {int(i["sk"].removeprefix("SHARD#")): i["stock"] for i in items if i["sk"].startswith("SHARD#")}
    remaining = sum(shards.values())
    return respond(
        200,
        {
            "sale_id": sale_id,
            "total": meta["total"],
            "remaining": remaining,
            "status": "on_sale" if remaining > 0 else "sold_out",
            "shard_count": meta["shard_count"],
            "shards": shards,
        },
    )
