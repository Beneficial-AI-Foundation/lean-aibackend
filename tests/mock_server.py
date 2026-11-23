"""Mock of the Anthropic Messages API for the ClaudeFFI tests.

Usage: python3 -I mock_server.py <expected-api-key>
The server binds 127.0.0.1 on a free port and prints the port on stdout.
The request's "model" field selects the behaviour:
  echo-utf8 / echo-ascii  return the first message's content as one text block
  status-NNN              return HTTP status NNN with a JSON error body
  blocks                  return the request's "blocks" field as the content array
  big-N                   return a text block of N copies of "x"
Every 200 response carries "conn", a per-connection serial number.
"""
import http.server
import itertools
import json
import sys

EXPECTED_KEY = sys.argv[1]
_conn_ids = itertools.count(1)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep-alive, so the client can reuse the connection

    def setup(self):
        super().setup()
        self.conn_id = next(_conn_ids)

    def log_message(self, *args):
        pass

    def send_json(self, status, obj, ascii_only=True):
        data = json.dumps(obj, ensure_ascii=ascii_only).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", "0")))
        if self.headers.get("anthropic-version") != "2023-06-01" or \
                self.headers.get("content-type") != "application/json":
            return self.send_json(400, {"type": "error", "error": {"type": "bad_headers"}})
        if self.headers.get("x-api-key") != EXPECTED_KEY:
            return self.send_json(401, {"type": "error", "error": {"type": "authentication_error"}})
        try:
            req = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return self.send_json(400, {"type": "error", "error": {"type": "invalid_json"}})
        model = req.get("model", "")
        if model in ("echo-utf8", "echo-ascii"):
            text = req["messages"][0]["content"]
            return self.send_json(200, {"content": [{"type": "text", "text": text}],
                                        "conn": self.conn_id}, model == "echo-ascii")
        if model.startswith("status-"):
            status = int(model[len("status-"):])
            return self.send_json(status, {"type": "error", "status": status})
        if model == "blocks":
            return self.send_json(200, {"content": req["blocks"], "conn": self.conn_id}, False)
        if model.startswith("big-"):
            n = int(model[len("big-"):])
            return self.send_json(200, {"content": [{"type": "text", "text": "x" * n}],
                                        "conn": self.conn_id})
        return self.send_json(400, {"type": "error", "error": {"type": "unknown_model"}})


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
