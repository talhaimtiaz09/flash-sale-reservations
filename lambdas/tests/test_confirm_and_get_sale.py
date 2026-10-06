import json

import confirm
import get_sale
import reserve
from helpers import NOW, reserve_event
from shared import db


def hold_for(sale_id, qty=1, key="key-00000001"):
    return json.loads(reserve.handler(reserve_event(sale_id, qty, key=key), None)["body"])["hold_id"]


def confirm_event(hold_id):
    return {"pathParameters": {"hold_id": hold_id}}


def test_confirm_turns_hold_into_order(seed):
    seed("s1", [5])
    hold_id = hold_for("s1")

    resp = confirm.handler(confirm_event(hold_id), None)

    assert resp["statusCode"] == 200
    assert json.loads(resp["body"])["status"] == "CONFIRMED"
    item = db.get(db.hold_key(hold_id))
    assert item["status"] == "CONFIRMED"
    assert "ttl" not in item
    assert "held_bucket" not in item


def test_confirm_twice_is_409(seed):
    seed("s1", [5])
    hold_id = hold_for("s1")
    confirm.handler(confirm_event(hold_id), None)

    resp = confirm.handler(confirm_event(hold_id), None)

    assert resp["statusCode"] == 409
    assert json.loads(resp["body"])["error"] == "already_confirmed"


def test_confirm_after_expiry_is_409_even_before_ttl_deletes(seed, monkeypatch):
    seed("s1", [5])
    hold_id = hold_for("s1")
    monkeypatch.setattr(db, "now", lambda: NOW + 600)

    resp = confirm.handler(confirm_event(hold_id), None)

    assert resp["statusCode"] == 409
    assert json.loads(resp["body"])["error"] == "hold_expired"
    assert db.get(db.hold_key(hold_id))["status"] == "HELD"


def test_confirm_unknown_hold(table):
    assert confirm.handler(confirm_event("0" * 32), None)["statusCode"] == 404
    assert confirm.handler(confirm_event("../etc"), None)["statusCode"] == 404


def test_get_sale_sums_shards(seed):
    seed("s1", [3, 0, 4])
    hold_for("s1", qty=2)

    resp = get_sale.handler({"pathParameters": {"sale_id": "s1"}}, None)
    sale = json.loads(resp["body"])

    assert resp["statusCode"] == 200
    assert sale["total"] == 7
    assert sale["remaining"] == 5
    assert sale["status"] == "on_sale"
    assert sale["shard_count"] == 3


def test_get_sale_sold_out(seed):
    seed("s1", [0, 0])
    sale = json.loads(get_sale.handler({"pathParameters": {"sale_id": "s1"}}, None)["body"])
    assert sale["status"] == "sold_out"


def test_get_sale_unknown(table):
    assert get_sale.handler({"pathParameters": {"sale_id": "nope"}}, None)["statusCode"] == 404
