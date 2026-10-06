import importlib.util
from pathlib import Path

import pytest

from shared import db

_path = Path(__file__).resolve().parents[2] / "scripts" / "seed_sale.py"
_spec = importlib.util.spec_from_file_location("seed_sale", _path)
seed_sale = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(seed_sale)


def test_split_spreads_remainder():
    assert seed_sale.split(1000, 3) == [334, 333, 333]
    assert sum(seed_sale.split(1000, 7)) == 1000


def test_seeds_once(table):
    table.transact_write_items(TransactItems=seed_sale.items(db.TABLE, "s9", 10, 3, 0))
    assert db.get(db.sale_key("s9"))["shard_count"] == 3
    assert [db.get(db.shard_key("s9", i))["stock"] for i in range(3)] == [4, 3, 3]

    with pytest.raises(Exception, match="TransactionCanceled"):
        table.transact_write_items(TransactItems=seed_sale.items(db.TABLE, "s9", 10, 3, 0))
