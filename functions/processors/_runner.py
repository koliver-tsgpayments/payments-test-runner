import json
import logging
import os
from datetime import datetime, timezone
from typing import Any, Dict

import requests

from .decorators import get_last_event, probe_entrypoint

# Ensure INFO-level application logs are emitted to Cloud Logging.
logging.getLogger().setLevel(logging.INFO)


def execute(processor: str, url: str, timeout: int = 20) -> Dict[str, Any]:
    """Shared runner that performs the HTTP request and returns the payload.

    The structured logging envelope is emitted by the @probe_entrypoint decorator.
    """

    @probe_entrypoint(target_name=processor)
    def _http_call(target_url: str, request_timeout: int):
        return requests.get(target_url, timeout=request_timeout)

    # Perform the call (decorator emits exactly one envelope)
    response = _http_call(url, timeout)

    # Compose return payload using the last emitted event for consistency
    event = get_last_event()
    env = os.getenv("ENV", "dev")
    region = event.get("region") if event else os.getenv("REGION", "unknown")
    latency_ms = event.get("latency_ms") if event else None
    status_code = response.status_code
    ok = 200 <= status_code < 400

    payload: Dict[str, Any] = {
        "processor": processor,
        "env": env,
        "region": region,
        "url": url,
        "status_code": status_code,
        "ok": ok,
        "latency_ms": latency_ms if latency_ms is not None else 0,
        "ts": datetime.now(timezone.utc).isoformat(),
    }

    return payload
