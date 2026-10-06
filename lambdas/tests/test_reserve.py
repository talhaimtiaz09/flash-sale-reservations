import json

import pytest
from botocore.exceptions import ClientError

import reserve
from helpers import NOW, reserve_event
from shared import db


def body(resp):
    return json.loads(resp["body"])


def first_shard(monkeypatch, order):
    """Make random.sample return a fixed shard order."""
    monkeypatch.setattr(reserve.random, "sample", lambda population, k: list(order))


def cancelled(*codes):
    return ClientError(
        {
            "Error": {"Code": "TransactionCanceledException", "Message": "cancelled"},
            "CancellationReasons": [{"Code": c} for c in codes],
        },
        "TransactWriteItems",
    )


def test_creates_hold_and_takes_stock(seed, stock):
    seed("s1", [5])
    resp = reserve.handler(reserve_event("s1", 2), None)

    assert resp["statusCode"] == 201
    hold = body(resp)
    assert hold["status"] == "HELD"
    assert hold["expires_at"] == NOW + 600
    assert stock("s1", 0) == 3

    item = db.get(db.hold_key(hold["hold_id"]))
    assert item["status"] == "HELD"
    assert item["ttl"] == item["expires_at"] == NOW + 600
    assert item["held_bucket"].startswith("B#")
    assert db.get(db.idem_key("key-00000001"))["hold_id"] == hold["hold_id"]


def test_never_sells_more_than_the_stock(seed, stock):
    seed("s1", [3, 2])
    codes = [
        reserve.handler(reserve_event("s1", 1, key=f"key-{i:08d}"), None)["statusCode"] for i in range(12)
    ]

    assert codes.count(201) == 5
    assert codes.count(409) == 7
    assert stock("s1", 0) == stock("s1", 1) == 0


def test_falls_back_to_another_shard(seed, stock, monkeypatch):
    seed("s1", [0, 0, 4])
    first_shard(monkeypatch, [0, 1, 2])

    resp = reserve.handler(reserve_event("s1", 1), None)

    assert resp["statusCode"] == 201
    assert stock("s1", 2) == 3


def test_sold_out_when_no_shard_covers_qty(seed, stock):
    # 3 units left in total, but scattered: no single shard has 2.
    seed("s1", [1, 1, 1])
    resp = reserve.handler(reserve_event("s1", 2), None)

    assert resp["statusCode"] == 409
    assert body(resp)["error"] == "sold_out"
    assert [stock("s1", i) for i in range(3)] == [1, 1, 1]


def test_same_key_returns_same_hold(seed, stock):
    seed("s1", [10])
    first = reserve.handler(reserve_event("s1", 1, key="double-click-1"), None)
    replays = [reserve.handler(reserve_event("s1", 1, key="double-click-1"), None) for _ in range(5)]

    assert first["statusCode"] == 201
    assert {r["statusCode"] for r in replays} == {200}
    assert {body(r)["hold_id"] for r in replays} == {body(first)["hold_id"]}
    assert stock("s1", 0) == 9


def test_replay_wins_over_sold_out(seed, stock):
    seed("s1", [1])
    first = reserve.handler(reserve_event("s1", 1, key="last-unit-1"), None)
    again = reserve.handler(reserve_event("s1", 1, key="last-unit-1"), None)

    assert first["statusCode"] == 201
    assert again["statusCode"] == 200
    assert body(again)["hold_id"] == body(first)["hold_id"]


def test_replay_of_expired_hold(seed, monkeypatch):
    seed("s1", [5])
    first = body(reserve.handler(reserve_event("s1", 1), None))
    monkeypatch.setattr(db, "now", lambda: NOW + 601)

    again = reserve.handler(reserve_event("s1", 1), None)

    assert again["statusCode"] == 200
    assert body(again)["hold_id"] == first["hold_id"]
    assert body(again)["status"] == "EXPIRED"


def test_key_reused_for_different_request(seed):
    seed("s1", [5])
    reserve.handler(reserve_event("s1", 1, key="reused-key-1"), None)
    resp = reserve.handler(reserve_event("s1", 2, key="reused-key-1"), None)

    assert resp["statusCode"] == 422


@pytest.mark.parametrize(
    "event_change",
    [
        {"headers": {}},
        {"headers": {"idempotency-key": "short"}},
        {"body": json.dumps({"qty": 0})},
        {"body": json.dumps({"qty": 5})},
        {"body": json.dumps({"qty": "2"})},
        {"body": json.dumps({"qty": True})},
        {"body": "not json"},
    ],
)
def test_bad_requests(seed, event_change):
    seed("s1", [5])
    resp = reserve.handler(reserve_event("s1", 1) | event_change, None)
    assert resp["statusCode"] == 400


def test_unknown_sale(table):
    assert reserve.handler(reserve_event("nope", 1), None)["statusCode"] == 404


def test_conflict_is_retried(seed, monkeypatch):
    seed("s1", [5])
    client = db.ddb()
    real = client.transact_write_items
    calls = []

    def flaky(**kwargs):
        calls.append(1)
        if len(calls) <= 2:
            raise cancelled("TransactionConflict", "None", "None")
        return real(**kwargs)

    monkeypatch.setattr(client, "transact_write_items", flaky)
    monkeypatch.setattr(reserve.time, "sleep", lambda s: None)

    assert reserve.handler(reserve_event("s1", 1), None)["statusCode"] == 201
    assert len(calls) == 3


def test_constant_conflict_is_429_not_sold_out(seed, monkeypatch):
    seed("s1", [5, 5])

    def always_conflict(**kwargs):
        raise cancelled("TransactionConflict", "None", "None")

    monkeypatch.setattr(db.ddb(), "transact_write_items", always_conflict)
    monkeypatch.setattr(reserve.time, "sleep", lambda s: None)

    resp = reserve.handler(reserve_event("s1", 1), None)

    assert resp["statusCode"] == 429
    assert resp["headers"]["retry-after"] == "1"


def test_throttled_table_is_429(seed, monkeypatch):
    seed("s1", [5])

    def throttled(**kwargs):
        raise ClientError(
            {"Error": {"Code": "ThrottlingException", "Message": "slow down"}}, "TransactWriteItems"
        )

    monkeypatch.setattr(db.ddb(), "transact_write_items", throttled)
    assert reserve.handler(reserve_event("s1", 1), None)["statusCode"] == 429
