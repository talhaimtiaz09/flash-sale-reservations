"""HTTP API (payload format 2.0) request and response helpers."""

import base64
import json


def respond(status, body, headers=None):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json", **(headers or {})},
        "body": json.dumps(body),
    }


def error(status, code, message, headers=None):
    return respond(status, {"error": code, "message": message}, headers)


def busy(message="Too many buyers on this sale right now. Retry shortly."):
    return error(429, "busy", message, {"retry-after": "1"})


def path_param(event, name):
    return (event.get("pathParameters") or {}).get(name, "")


def header(event, name):
    # HTTP APIs lowercase header names in payload format 2.0.
    return (event.get("headers") or {}).get(name.lower(), "")


def json_body(event):
    """Parsed JSON body, or None if it is missing or not JSON."""
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8", errors="replace")
    try:
        return json.loads(raw)
    except ValueError:
        return None
