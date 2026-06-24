#!/usr/bin/env python3
"""
notify-server.py — HTTP server that sends notification emails.
Runs on fabric-landing environment. SMTP credentials live here.

POST /notify with JSON body:
  {"domain": "...", "provider": "...", "model": "..."}

Always returns 200. Never crashes.
"""

import http.server
import json
import smtplib
import os
import sys
from email.mime.text import MIMEText
from datetime import datetime, timezone

SMTP_HOST = os.environ.get("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASS = os.environ.get("SMTP_PASS", "")
SMTP_SENDER = os.environ.get("SMTP_SENDER", SMTP_USER)
NOTIFY_RECIPIENT = os.environ.get("NOTIFY_RECIPIENT", "")


class NotifyHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/notify":
            self.send_response(404)
            self.end_headers()
            return

        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length)) if length else {}
        except Exception:
            body = {}

        domain = body.get("domain", "unknown")
        provider = body.get("provider", "unknown")
        model = body.get("model", "unknown")
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

        if not NOTIFY_RECIPIENT or not SMTP_USER or not SMTP_PASS:
            print(f"[notify] Missing credentials, skipping. domain={domain}")
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ok":true,"skipped":"no_credentials"}')
            return

        subject = f"[Constructor Fabric] New instance: {domain}"
        body_html = f"""<h2>New Constructor Fabric instance</h2>
<table style="border-collapse:collapse;font-size:15px;">
<tr><td style="padding:4px 12px;font-weight:bold;">Domain</td><td style="padding:4px 12px;"><a href="https://{domain}/">{domain}</a></td></tr>
<tr><td style="padding:4px 12px;font-weight:bold;">Provider</td><td style="padding:4px 12px;">{provider}</td></tr>
<tr><td style="padding:4px 12px;font-weight:bold;">Model</td><td style="padding:4px 12px;">{model}</td></tr>
<tr><td style="padding:4px 12px;font-weight:bold;">Created</td><td style="padding:4px 12px;">{ts}</td></tr>
</table>"""

        msg = MIMEText(body_html, "html")
        msg["Subject"] = subject
        msg["From"] = SMTP_SENDER
        msg["To"] = NOTIFY_RECIPIENT

        try:
            if SMTP_PORT == 465:
                with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, timeout=15) as srv:
                    srv.login(SMTP_USER, SMTP_PASS)
                    srv.sendmail(SMTP_SENDER, [NOTIFY_RECIPIENT], msg.as_string())
            else:
                with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=15) as srv:
                    srv.starttls()
                    srv.login(SMTP_USER, SMTP_PASS)
                    srv.sendmail(SMTP_SENDER, [NOTIFY_RECIPIENT], msg.as_string())
            print(f"[notify] Email sent to {NOTIFY_RECIPIENT} for {domain}")
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
        except Exception as e:
            print(f"[notify] SMTP failed: {e}")
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps({"ok": False, "error": str(e)}).encode())

    def log_message(self, format, *args):
        print(f"[notify-server] {args[0]}")


if __name__ == "__main__":
    port = int(os.environ.get("NOTIFY_PORT", "8099"))
    server = http.server.HTTPServer(("127.0.0.1", port), NotifyHandler)
    print(f"[notify-server] Listening on 127.0.0.1:{port}")
    server.serve_forever()
