import json
import logging
import os
import time
import uuid
from typing import Any, Dict, Optional
import threading

# Optional Google Cloud Logging imports will be resolved lazily at runtime.
_GCLOUD_AVAILABLE = None  # type: Optional[bool]

_ctx = threading.local()


def _set_last_envelope(envelope: Dict[str, Any]) -> None:
    _ctx.last_envelope = envelope  # type: ignore[attr-defined]


def get_last_envelope() -> Optional[Dict[str, Any]]:
    return getattr(_ctx, "last_envelope", None)  # type: ignore[attr-defined]


SCHEMA_VERSION = "v1"
DEFAULT_LOG_NAME = "payment-probe"
DEFAULT_SOURCE = "gcp.payment-probe"
DEFAULT_SOURCETYPE = "payment_probe"


def new_event_id() -> str:
    """Return a new uuid4 string for event IDs."""
    return str(uuid.uuid4())


def _get_region() -> str:
    return os.getenv("FUNCTION_REGION") or os.getenv("REGION", "unknown")


def _get_function_name(fallback_target: str) -> str:
    return (
        os.getenv("FUNCTION_TARGET")
        or os.getenv("FUNCTION_NAME")
        or f"run_{fallback_target}"
    )


def _get_tenant() -> str:
    return os.getenv("TENANT", "default")


def _get_log_name() -> str:
    return os.getenv("LOG_NAME", DEFAULT_LOG_NAME)


def _severity_to_level(severity: str) -> int:
    return {
        "INFO": logging.INFO,
        "WARNING": logging.WARNING,
        "ERROR": logging.ERROR,
    }.get(severity, logging.INFO)


def _in_managed_env() -> bool:
    """Detect Cloud Functions/Run managed environment to avoid console echo.

    We check common envs used in CF2/Run; absent locally.
    """
    return bool(os.getenv("K_SERVICE") or os.getenv("FUNCTION_TARGET"))


def _maybe_init_gcloud_logger(logger: logging.Logger, log_name: str) -> bool:
    """Attach a Google Cloud StructuredLogHandler to the logger if available.

    Returns True if structured handler attached; False otherwise.
    """
    global _GCLOUD_AVAILABLE  # noqa: PLW0603

    if getattr(logger, "_probe_configured", False):  # type: ignore[attr-defined]
        # Already configured; return whether structured is present
        return bool(getattr(logger, "_probe_structured", False))  # type: ignore[attr-defined]

    structured_attached = False
    # Only attach the GCL handler when running in a managed environment (Cloud Functions/Run)
    if not _in_managed_env():
        setattr(logger, "_probe_configured", True)
        setattr(logger, "_probe_structured", False)
        return False

    try:
        if _GCLOUD_AVAILABLE is not False:
            # Try import; cache result
            from google.cloud import logging as gcloud_logging  # type: ignore
            from google.cloud.logging_v2.handlers import (  # type: ignore
                StructuredLogHandler,
            )

            client = gcloud_logging.Client()
            handler = StructuredLogHandler(client=client, name=log_name)
            logger.addHandler(handler)
            logger.setLevel(logging.INFO)
            logger.propagate = False
            structured_attached = True
            _GCLOUD_AVAILABLE = True
        else:
            structured_attached = False
    except Exception:  # pragma: no cover - optional dependency
        _GCLOUD_AVAILABLE = False
        structured_attached = False

    # Mark as configured to avoid duplicate handlers
    setattr(logger, "_probe_configured", True)
    setattr(logger, "_probe_structured", structured_attached)
    return structured_attached


def emit_probe_log(event: Dict[str, Any]) -> Dict[str, Any]:
    """Build and emit the probe envelope via stdlib or GCL logging.

    Expects `event` to contain: event_id, function, region, target, status,
    http_status (optional), latency_ms, tenant, severity, extra (dict).
    Returns the envelope as a plain dict.
    """
    region = event.get("region") or _get_region()
    function_name = event.get("function") or _get_function_name(event.get("target", "unknown"))
    tenant = event.get("tenant") or _get_tenant()
    host = region if region and region != "unknown" else function_name

    envelope_dict: Dict[str, Any] = {
        "time": int(time.time()),
        "host": host,
        "source": DEFAULT_SOURCE,
        "sourcetype": DEFAULT_SOURCETYPE,
        "event": {
            "schema_version": SCHEMA_VERSION,
            "event_id": event.get("event_id", new_event_id()),
            "function": function_name,
            "region": region,
            "target": event.get("target"),
            "status": event.get("status"),
            "http_status": event.get("http_status"),
            "latency_ms": int(event.get("latency_ms", 0)),
            "tenant": tenant,
            "severity": event.get("severity", "INFO"),
            "extra": event.get("extra", {}) or {},
        },
    }

    _set_last_envelope(envelope_dict)

    log_name = _get_log_name()
    logger = logging.getLogger(log_name)
    level = _severity_to_level(str(event.get("severity", "INFO")))

    structured = _maybe_init_gcloud_logger(logger, log_name)
    try:
        if structured:
            # Emit as jsonPayload via StructuredLogHandler
            logger.log(level, "probe", extra={"json_fields": envelope_dict})
            # Echo to console for local dev when not in managed runtime
            if not _in_managed_env():
                logging.getLogger().log(level, json.dumps(envelope_dict, separators=(",", ":")))
        else:
            # Stdlib fallback emits as JSON string (textPayload)
            logger.log(level, json.dumps(envelope_dict, separators=(",", ":")))
    except Exception:  # pragma: no cover - logging failure should never crash invocation
        # Fallback to root logger just in case
        logging.getLogger().log(level, json.dumps(envelope_dict, separators=(",", ":")))

    return envelope_dict
