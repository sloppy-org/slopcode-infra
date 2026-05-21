#!/usr/bin/env python3
"""Pure-stdlib mock OpenAI-compatible server for CI testing.

Provides minimal endpoints:
- GET /v1/models
- POST /v1/chat/completions
- GET /health

No external dependencies - uses only Python standard library.
"""
import argparse
import json
import sys
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Any

class MockOpenAIHandler(BaseHTTPRequestHandler):
    """Handler for mock OpenAI API requests."""

    def log_message(self, format: str, *args: Any) -> None:
        """Override to use stderr for logging."""
        sys.stderr.write(f"{self.address_string()} - {format % args}\n")

    def _send_json(self, data: dict, status: int = 200) -> None:
        """Send JSON response."""
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        """Handle GET requests."""
        if self.path == "/v1/models":
            self._send_json({
                "object": "list",
                "data": [
                    {
                        "id": "mock-model",
                        "object": "model",
                        "created": int(time.time()),
                        "owned_by": "mock"
                    }
                ]
            })
        elif self.path == "/health":
            self._send_json({"status": "ok"})
        else:
            self._send_json({"error": "not found"}, 404)

    def do_POST(self) -> None:
        """Handle POST requests."""
        if self.path == "/v1/chat/completions":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)

            try:
                request = json.loads(body.decode("utf-8"))
            except json.JSONDecodeError:
                self._send_json({"error": "invalid json"}, 400)
                return

            messages = request.get("messages", [])
            user_message = ""
            for msg in reversed(messages):
                if msg.get("role") == "user":
                    user_message = msg.get("content", "")
                    break

            response_text = f"Mock response to: {user_message[:50]}..."

            self._send_json({
                "id": "mock-completion-id",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": request.get("model", "mock-model"),
                "choices": [
                    {
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": response_text
                        },
                        "finish_reason": "stop"
                    }
                ],
                "usage": {
                    "prompt_tokens": len(user_message.split()),
                    "completion_tokens": len(response_text.split()),
                    "total_tokens": len(user_message.split()) + len(response_text.split())
                },
                "timings": {
                    "prompt_n": max(1, len(user_message.split())),
                    "prompt_ms": 10.0,
                    "prompt_per_second": 100.0,
                    "predicted_n": max(1, len(response_text.split())),
                    "predicted_ms": 50.0,
                    "predicted_per_second": 50.0,
                },
            })
        else:
            self._send_json({"error": "not found"}, 404)

class MockHTTPServer(HTTPServer):
    """HTTPServer that skips the reverse-DNS lookup in server_bind.

    Stdlib HTTPServer.server_bind() calls socket.getfqdn(), which blocks
    for the resolver timeout when the box has no DNS or is under heavy
    load (observed ~2 minutes on mailuefterl during the MTP GGUF
    download). The CI mock does not need its FQDN populated.
    """

    def server_bind(self) -> None:  # type: ignore[override]
        import socketserver
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.socket.getsockname()[1]


def main() -> None:
    parser = argparse.ArgumentParser(description="Mock OpenAI server for testing")
    parser.add_argument("--host", default="127.0.0.1", help="Host to bind to")
    parser.add_argument("--port", type=int, default=8080, help="Port to bind to")
    args = parser.parse_args()

    server = MockHTTPServer((args.host, args.port), MockOpenAIHandler)
    print(f"Mock server listening on http://{args.host}:{args.port}", file=sys.stderr)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...", file=sys.stderr)
        server.shutdown()

if __name__ == "__main__":
    main()
