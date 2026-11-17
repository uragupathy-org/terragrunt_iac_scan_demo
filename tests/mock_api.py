# Minimal stand-in for the Vision One Template Scanner endpoints (offline tests only).
# Usage: python3 -I mock_api.py PORT FIXTURE_JSON EXPECTED_KEY
import http.server, sys
PORT, FIXTURE, KEY = int(sys.argv[1]), sys.argv[2], sys.argv[3]
BODY = open(FIXTURE, 'rb').read()
PATHS = {'/beta/cloudPosture/scanTemplate', '/beta/cloudPosture/scanTemplateArchive'}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0)); self.rfile.read(n)
        if self.path not in PATHS:
            self.send_response(404); self.end_headers(); return
        if self.headers.get('Authorization') != 'Bearer ' + KEY:
            self.send_response(401); self.send_header('Content-Type','application/json'); self.end_headers()
            self.wfile.write(b'{"error":{"code":"InvalidCredentials"}}'); return
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(BODY)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', PORT), H).serve_forever()
