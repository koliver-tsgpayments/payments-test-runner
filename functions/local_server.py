import json
import os
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

        # Background functions ignore incoming payload; pass empty dict.
        result = handler({}, None)
        response = json.dumps(result, indent=2).encode("utf-8")

        self.send_response(200)
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
