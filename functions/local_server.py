import json
import os
import logging
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Callable, Dict

from .processors.tsg import run_tsgpayments
from .processors.worldpay import run_worldpay

ProcessorFunc = Callable[[Dict, object], Dict]


class ProcessorRequestHandler(BaseHTTPRequestHandler):
    routes: Dict[str, ProcessorFunc] = {
        "/tsg": run_tsgpayments,
        "/worldpay": run_worldpay,
    }

    def _invoke(self, path: str):
        handler = self.routes.get(path)
        if handler is None:
            self.send_error(404, "Unknown path")
            return

        try:
            # Background functions ignore incoming payload; pass empty dict.
            runner_payload = handler({}, None)
            result = runner_payload
            status = 200
        except Exception as exc:
            # Build a JSON error body using the last emitted event where possible
            try:
                from .logging.envelope import get_last_envelope
                env_payload = get_last_envelope()
                if env_payload is not None:
                    result = env_payload
                else:
                    # Fallback when envelope is unavailable for some reason
                    from .processors.decorators import get_last_event
                    ev = get_last_event()
                    body = {
                        "ok": False,
                        "error": str(exc),
                        "processor": getattr(ev, "target", None) if ev else None,
                        "env": os.getenv("ENV", "local"),
                        "region": getattr(ev, "region", None) if ev else os.getenv("REGION", "local"),
                        "url": None,
                        "status_code": getattr(ev, "http_status", None) if ev else None,
                        "latency_ms": getattr(ev, "latency_ms", 0) if ev else 0,
                    }
                    result = body
            except Exception:
                # Last resort generic error body
                result = {"ok": False, "error": str(exc)}
            status = 500

        # On success, prefer returning the most recent structured envelope
        if status == 200:
            try:
                from .logging.envelope import get_last_envelope

                env_payload = get_last_envelope()
                if env_payload is not None:
                    result = env_payload
            except Exception:
                pass

        response = json.dumps(result, indent=2).encode("utf-8")

        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def do_GET(self):
        self._invoke(self.path)

    def do_POST(self):
        self._invoke(self.path)

    def log_message(self, format, *args):  # pylint: disable=signature-differs
        # Suppress default stdout logging to keep output clean.
        return


def main():
    # Configure simple console logging so structured envelopes are visible locally.
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    host = os.getenv("LOCAL_SERVER_HOST", "0.0.0.0")
    port = int(os.getenv("LOCAL_SERVER_PORT", "8080"))
    os.environ.setdefault("ENV", "local")
    os.environ.setdefault("REGION", "local")

    server = HTTPServer((host, port), ProcessorRequestHandler)
    print(f"Local processor server listening on http://{host}:{port}")
    print("Endpoints: /tsg, /worldpay")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Shutting down...")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
