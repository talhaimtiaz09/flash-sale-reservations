"""Small builders shared by the tests."""

import json

NOW = 1_800_000_000


class FakeContext:
    def __init__(self, ms_left=60_000):
        self.ms_left = ms_left

    def get_remaining_time_in_millis(self):
        return self.ms_left


def reserve_event(sale_id, qty, key="key-00000001"):
    return {
        "pathParameters": {"sale_id": sale_id},
        "headers": {"idempotency-key": key, "content-type": "application/json"},
        "body": json.dumps({"qty": qty}),
        "isBase64Encoded": False,
    }
