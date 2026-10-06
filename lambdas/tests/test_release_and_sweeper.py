import json

from boto3.dynamodb.types import TypeSerializer
from botocore.exceptions import ClientError

import confirm
import release
import reserve
import sweeper
from helpers import NOW, FakeContext, reserve_event
from shared import db

_serializer = TypeSerializer()


def hold_for(sale_id, qty=1, key="key-00000001"):
    hold_id = json.loads(reserve.handler(reserve_event(sale_id, qty, key=key), None)["body"])["hold_id"]
    return hold_id, db.get(db.hold_key(hold_id))


def typed(item):
    return {k: _serializer.serialize(v) for k, v in item.items()}


def ttl_delete(old_item, seq="100"):
    return {
        "eventID": f"evt-{seq}",
        "eventName": "REMOVE",
        "userIdentity": {"type": "Service", "principalId": "dynamodb.amazonaws.com"},
        "dynamodb": {"OldImage": typed(old_item), "SequenceNumber": seq},
    }


# --- release (stream consumer) -------------------------------------------------


def test_ttl_delete_returns_stock_once(seed, stock):
    seed("s1", [5])
    hold_id, hold = hold_for("s1", qty=2)
    assert stock("s1", 0) == 3

    first = release.handler({"Records": [ttl_delete(hold)]}, None)
    # Stream batches are retried: the same record again must change nothing.
    second = release.handler({"Records": [ttl_delete(hold)]}, None)

    assert first == second == {"batchItemFailures": []}
    assert stock("s1", 0) == 5
    assert db.get(db.key(f"RETURN#{hold_id}", "RETURN"))["qty"] == 2


def test_user_delete_is_ignored(seed, stock):
    seed("s1", [5])
    _, hold = hold_for("s1")
    record = ttl_delete(hold)
    del record["userIdentity"]

    assert release.handle(record) == "ignored"
    assert stock("s1", 0) == 4


def test_confirmed_or_non_hold_items_are_ignored(seed, stock):
    seed("s1", [5])
    _, hold = hold_for("s1")

    assert release.handle(ttl_delete(hold | {"status": "CONFIRMED"})) == "ignored"
    assert release.handle(ttl_delete({"pk": "IDEM#k", "sk": "IDEM", "hold_id": "x"})) == "ignored"
    assert stock("s1", 0) == 4


def test_failure_reports_first_failed_record(seed, monkeypatch):
    seed("s1", [5])
    _, hold = hold_for("s1")

    def conflict(**kwargs):
        raise ClientError(
            {
                "Error": {"Code": "TransactionCanceledException", "Message": "cancelled"},
                "CancellationReasons": [{"Code": "TransactionConflict"}, {"Code": "None"}],
            },
            "TransactWriteItems",
        )

    monkeypatch.setattr(db.ddb(), "transact_write_items", conflict)
    result = release.handler({"Records": [ttl_delete(hold, "7"), ttl_delete(hold, "8")]}, None)

    assert result == {"batchItemFailures": [{"itemIdentifier": "7"}]}


# --- sweeper -----------------------------------------------------------------


def test_sweeper_returns_expired_holds(seed, stock, monkeypatch):
    seed("s1", [5])
    expired_id, _ = hold_for("s1", qty=2, key="key-expired")
    monkeypatch.setattr(db, "now", lambda: NOW + 300)
    live_id, _ = hold_for("s1", qty=1, key="key-live-01")
    monkeypatch.setattr(db, "now", lambda: NOW + 650)  # first hold expired, second not

    counts = sweeper.handler({}, FakeContext())

    assert counts == {"returned": 1}
    assert db.get(db.hold_key(expired_id)) is None
    assert db.get(db.hold_key(live_id))["status"] == "HELD"
    assert stock("s1", 0) == 4


def test_sweeper_skips_confirmed_holds(seed, stock, monkeypatch):
    seed("s1", [5])
    hold_id, _ = hold_for("s1")
    confirm.handler({"pathParameters": {"hold_id": hold_id}}, None)
    monkeypatch.setattr(db, "now", lambda: NOW + 3600)

    assert sweeper.handler({}, FakeContext()) == {}
    assert db.get(db.hold_key(hold_id))["status"] == "CONFIRMED"
    assert stock("s1", 0) == 4


def test_sweeper_and_stream_never_double_return(seed, stock, monkeypatch):
    seed("s1", [5])
    hold_id, hold = hold_for("s1")
    monkeypatch.setattr(db, "now", lambda: NOW + 700)

    # The stream got there first (say the marker exists but the hold item lingers).
    release.handle(ttl_delete(hold))
    counts = sweeper.handler({}, FakeContext())

    assert counts == {"cleaned": 1}
    assert db.get(db.hold_key(hold_id)) is None
    assert stock("s1", 0) == 5


def test_sweeper_stops_before_timeout(seed, monkeypatch):
    seed("s1", [5])
    hold_for("s1")
    monkeypatch.setattr(db, "now", lambda: NOW + 700)

    assert sweeper.handler({}, FakeContext(ms_left=1000)) == {}
