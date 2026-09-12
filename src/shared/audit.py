"""Structured audit logging shared by every service in the demo.

One line of JSON per event, always keyed by the same identity fields so a
single query (kubectl logs | jq, or a real log pipeline) can answer:
"which agent did what, on whose behalf, and why was it allowed?"
"""
import json
import sys
import time


def audit(event: str, **fields) -> None:
    record = {"ts": round(time.time(), 3), "event": event, **fields}
    json.dump(record, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()
