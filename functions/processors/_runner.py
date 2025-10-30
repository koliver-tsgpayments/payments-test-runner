import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Any, Dict, Optional

import requests

# Ensure INFO-level application logs are emitted to Cloud Logging.
logging.getLogger().setLevel(logging.INFO)


def execute(processor: str, url: str, timeout: int = 20) -> Dict[str, Any]:
    """Shared runner that performs the HTTP request and returns the log payload."""
    start = time.time()
    region = os.getenv("REGION", "unknown")
    env = os.getenv("ENV", "dev")

    status_code: Optional[int] = None
    ok = False
    error: Optional[str] = None

    try:
        response = requests.get(url, timeout=timeout)
        status_code = response.status_code
        ok = 200 <= response.status_code < 400
    except Exception as exc:  # pragma: no cover - exercised via tests
        error = str(exc)

    elapsed_ms = int((time.time() - start) * 1000)
    payload: Dict[str, Any] = {
        "processor": processor,
        "env": env,
        "region": region,
        "url": url,
        "status_code": status_code,
        "ok": ok,
        "latency_ms": elapsed_ms,
        "ts": datetime.now(timezone.utc).isoformat(),
    }

    if error:
        payload["error"] = error
        logging.error(json.dumps(payload))
    else:
        logging.info(json.dumps(payload))

    return payload
