#!/usr/bin/env python3
"""Create a sale: one META item and `--shards` stock items, in one transaction.

Sales are not created through the public API. Each load test seeds a fresh
sale, so an existing sale id is refused rather than overwritten.

    python scripts/seed_sale.py --table "$(terraform -chdir=terraform/envs/lab output -raw table_name)" \\
        --sale-id oversell-01 --units 1000 --shards 10

Needs AWS credentials that can write the table (an admin profile in the lab).
"""

import argparse
import os
import sys
import time

import boto3
from botocore.exceptions import ClientError

MAX_SHARDS = 99  # META + 99 shards = the 100-item TransactWriteItems limit


def split(units, shards):
    """1000 units over 3 shards -> [334, 333, 333]."""
    base, extra = divmod(units, shards)
    return [base + (1 if i < extra else 0) for i in range(shards)]


def items(table, sale_id, units, shards, now):
    pk = {"S": f"SALE#{sale_id}"}
    meta = {
        "Put": {
            "TableName": table,
            "Item": {
                "pk": pk,
                "sk": {"S": "META"},
                "total": {"N": str(units)},
                "shard_count": {"N": str(shards)},
                "created_at": {"N": str(now)},
            },
            "ConditionExpression": "attribute_not_exists(pk)",
        }
    }
    stock = [
        {
            "Put": {
                "TableName": table,
                "Item": {"pk": pk, "sk": {"S": f"SHARD#{i}"}, "stock": {"N": str(units_i)}},
                "ConditionExpression": "attribute_not_exists(pk)",
            }
        }
        for i, units_i in enumerate(split(units, shards))
    ]
    return [meta, *stock]


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--table", default=os.environ.get("TABLE_NAME"), help="table name (or TABLE_NAME)")
    parser.add_argument("--sale-id", required=True)
    parser.add_argument("--units", type=int, required=True, help="total units on sale")
    parser.add_argument("--shards", type=int, default=10, help=f"stock shards, 1-{MAX_SHARDS}")
    parser.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    args = parser.parse_args()

    if not args.table:
        parser.error("--table or TABLE_NAME is required")
    if not 1 <= args.shards <= MAX_SHARDS:
        parser.error(f"--shards must be 1-{MAX_SHARDS}")
    if args.units < args.shards:
        parser.error("--units must be at least --shards, or some shards start empty")

    client = boto3.client("dynamodb", region_name=args.region)
    try:
        client.transact_write_items(
            TransactItems=items(args.table, args.sale_id, args.units, args.shards, int(time.time()))
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "TransactionCanceledException":
            sys.exit(f"sale {args.sale_id!r} already exists; seed a new sale id")
        raise

    low, high = min(split(args.units, args.shards)), max(split(args.units, args.shards))
    print(f"seeded {args.sale_id}: {args.units} units over {args.shards} shards ({low}-{high} each)")


if __name__ == "__main__":
    main()
