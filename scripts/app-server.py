#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.getenv("CF_PORT", "8081"))
PROVIDER = os.getenv("LLM_PROVIDER", "openai").strip() or "openai"
TOKEN = (os.getenv("API_TOKEN") or os.getenv("OPENAI_API_KEY") or os.getenv("ANTHROPIC_API_KEY") or "").strip()
MODEL = (os.getenv("CLAUDE_MODEL") if PROVIDER == "claude" else os.getenv("OPENAI_MODEL")) or "gpt-5.5"
IDE_PROFILE = os.getenv("CF_IDE_PROFILE", "cli").strip() or "cli"


def mask_secret(value: str) -> str:
    if not value:
        return ""
    if len(value) <= 8:
        return "***"
    return value[:4] + "..." + value[-4:]


def public_config() -> dict:
    return {
        "service": "Constructor Fabric",
        "provider": PROVIDER,
        "model": MODEL,
        "ide_profile": IDE_PROFILE,
        "api_token_set": bool(TOKEN),
        "api_token_masked": mask_secret(TOKEN),
    }


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status: int, payload: dict):
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/health", "/api/config"):
            self.send_json(200, {"ok": True, "config": public_config()})
        else:
            self.send_json(404, {"ok": False, "error": "not found"})

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    print(f"Constructor Fabric service listening on 0.0.0.0:{PORT}", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
