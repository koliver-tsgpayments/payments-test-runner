# Prompt — Logging Envelope (Python Only)

This focused prompt covers only the structured logging envelope for the Python code under `functions/`. It omits Terraform, BigQuery, Pub/Sub, and Splunk wiring. Keep the existing repo shape and working behaviors intact.

## Scope
- Only touch files under `functions/`.
- Preserve current processor entry points and the `execute()` runner API.
- Maintain one structured JSON log per probe invocation.

## Goals
- Enforce a small, versioned log envelope across all processors.
- Keep writing structured logs via the standard `logging` module (compatible with Cloud Logging). Optionally integrate `google-cloud-logging` if trivial.
- Ensure exactly one envelope is emitted per invocation, on both success and error paths.

## Envelope Specification
Emit exactly one JSON entry per probe matching:
```json
{
  "time": <unix epoch seconds>,
  "host": "<region or function name>",
  "source": "gcp.payment-probe",
  "sourcetype": "payment_probe",
  "event": {
    "schema_version": "v1",
    "event_id": "<uuid4>",
    "function": "<function entry point>",
    "region": "<gcp region>",
    "target": "<processor target alias>",
    "status": "OK" | "ERROR",
    "http_status": <int|null>,
    "latency_ms": <int>,
    "tenant": "<string>",
    "severity": "INFO" | "WARNING" | "ERROR",
    "extra": { }
  }
}
```

Notes:
- You may omit `time` if Cloud Logging timestamps suffice; include it if easy.
- Keep `extra` minimal; do not log sensitive data.

## Python Changes (functions/)
1. Add `functions/logging/envelope.py` with:
   - Pydantic models `ProbeLogEvent` and `ProbeLogEnvelope` implementing the envelope above.
   - `new_event_id()` helper returning a uuid4 string.
   - `emit_probe_log(event: ProbeLogEvent) -> dict` that:
     - Builds the envelope and returns the dict for tests/local use.
     - Reads environment variables with fallbacks: `FUNCTION_REGION` → `REGION` → `"unknown"`; `FUNCTION_NAME` → fallback to processor name; `TENANT` → `"default"`.
     - Writes via `logging` using a custom log name `payment-probe` (configurable by `LOG_NAME`, default `payment-probe`). If integrating `google-cloud-logging` is trivial, initialize a client and handler to map `severity` correctly; otherwise keep stdlib logging emitting JSON.
   - A module-level JSON Schema string constant that reflects the envelope for validation (optional if adding tests later).

2. Add `functions/processors/decorators.py` providing `@probe_entrypoint(target_name: str)` that:
   - Wraps a callable, measures latency, and captures `http_status` if available.
   - On success, emits one envelope with `status="OK"` and `severity="INFO"`.
   - On exception, emits one envelope with `status="ERROR"`, `severity="ERROR"`, includes a terse error summary in `extra`, then re-raises so Cloud Functions records a failure.
   - Guarantees exactly one call to `emit_probe_log` per invocation.

3. Refactor `functions/processors/_runner.py` to keep the public API:
   - Preserve `execute(processor: str, url: str, timeout: int = 20) -> dict`.
   - Move the HTTP call into an inner function decorated with `@probe_entrypoint(target_name=processor)`; the decorator is responsible for envelope emission.
   - Preserve the current return payload shape as much as possible, sourcing values from the envelope so existing callers and the local server remain functional.

4. Update `functions/processors/tsg.py` and `functions/processors/worldpay.py` only if their return expectations need minimal alignment with the new runner behavior. Do not change function names or signatures.

5. Update `functions/requirements.txt` if needed:
   - Keep `requests` as-is.
   - Optionally add `google-cloud-logging` if you wire the handler; otherwise not required.

## Environment Variables (read by envelope)
- `FUNCTION_REGION` or `REGION`: region string; fallback `unknown`.
- `FUNCTION_NAME`: function entry-point; fallback to processor name passed to runner.
- `TENANT`: tenant identifier; fallback `default`.
- `LOG_NAME`: custom log name; fallback `payment-probe`.
- Existing `ENV` may continue to be read for compatibility but is not part of the envelope unless included in `extra`.

## Acceptance Criteria (runtime behavior)
- Each processor invocation emits exactly one JSON envelope to logs.
- Success path sets `status="OK"`, `severity="INFO"`, includes `http_status` when available and `latency_ms` always.
- Error path sets `status="ERROR"`, `severity="ERROR"`, includes a short error summary in `extra`, then re-raises.
- Local server (`functions/local_server.py`) continues to run and returns a JSON body; log emission remains structured.

## Non-Goals
- No Terraform, BigQuery, Pub/Sub, or Splunk sink configuration in this prompt.
- No test scaffolding required here (can be added separately under `tests/`).

