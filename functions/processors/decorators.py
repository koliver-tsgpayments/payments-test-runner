import functools
import os
import time
import threading
from typing import Any, Callable, Dict, Optional, TypeVar, cast

# Import envelope module in a way that works both locally (package `functions`)
# and in deployed artifacts (top-level `probe_logging`).
try:  # Cloud Functions/Run artifact
    from probe_logging.envelope import ProbeLogEvent, emit_probe_log, new_event_id  # type: ignore
except Exception:  # Local tests/dev where code resides under `functions/`
    from ..probe_logging.envelope import ProbeLogEvent, emit_probe_log, new_event_id  # type: ignore


F = TypeVar("F", bound=Callable[..., Any])


_ctx = threading.local()


def _set_last_event(event: ProbeLogEvent) -> None:
    _ctx.last_event = event  # type: ignore[attr-defined]


def get_last_event() -> Optional[ProbeLogEvent]:
    return getattr(_ctx, "last_event", None)  # type: ignore[attr-defined]


def _extract_http_status(value: Any) -> Optional[int]:
    try:
        if isinstance(value, dict) and "status_code" in value:
            code = value.get("status_code")
            return int(code) if code is not None else None
        code = getattr(value, "status_code", None)
        return int(code) if code is not None else None
    except Exception:  # pragma: no cover - defensive
        return None


def _env_region() -> str:
    return os.getenv("FUNCTION_REGION") or os.getenv("REGION", "unknown")


def _env_function_name(fallback: str) -> str:
    return os.getenv("FUNCTION_NAME") or fallback


def _env_tenant() -> str:
    return os.getenv("TENANT", "default")


def probe_entrypoint(*, target_name: str) -> Callable[[F], F]:
    """Decorator for processor entrypoints to emit one structured envelope.

    - Measures latency and captures http_status when available.
    - On success: status=OK, severity=INFO.
    - On error: status=ERROR, severity=ERROR, adds terse error summary then re-raises.
    - Guarantees exactly one emit per invocation.
    """

    def decorator(func: F) -> F:
        @functools.wraps(func)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            start = time.time()
            http_status: Optional[int] = None
            try:
                result = func(*args, **kwargs)
                http_status = _extract_http_status(result)
                elapsed_ms = int((time.time() - start) * 1000)

                event = ProbeLogEvent(
                    event_id=new_event_id(),
                    function=_env_function_name(target_name),
                    region=_env_region(),
                    target=target_name,
                    status="OK",
                    http_status=http_status,
                    latency_ms=elapsed_ms,
                    tenant=_env_tenant(),
                    severity="INFO",
                    extra={},
                )
                _set_last_event(event)
                emit_probe_log(event)
                return result
            except Exception as exc:
                elapsed_ms = int((time.time() - start) * 1000)
                summary = {
                    "error": f"{exc.__class__.__name__}: {str(exc)}",
                }
                event = ProbeLogEvent(
                    event_id=new_event_id(),
                    function=_env_function_name(target_name),
                    region=_env_region(),
                    target=target_name,
                    status="ERROR",
                    http_status=http_status,
                    latency_ms=elapsed_ms,
                    tenant=_env_tenant(),
                    severity="ERROR",
                    extra=summary,
                )
                _set_last_event(event)
                emit_probe_log(event)
                raise

        return cast(F, wrapper)

    return decorator
