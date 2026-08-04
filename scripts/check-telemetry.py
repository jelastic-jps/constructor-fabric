#!/usr/bin/env python3
"""Check that this training environment can reach the telemetry collector.

Run inside the training container:

    python3 check-telemetry.py
    python3 check-telemetry.py trainee@example.com my-env.example.cloud

Reads the collector URL and secret from /home/developer/.cf-telemetry and the
environment identity from /home/developer/.cf-install-id — the same files the
manifest plants at deploy and the Trainer emitter reads at runtime. Sends one
environment_provisioned event, exactly as the manifest emitter does.

Exits 0 only if the event was actually stored.
"""

import hashlib
import hmac
import json
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

CONFIG_FILE = "/home/developer/.cf-telemetry"
INSTALL_ID_FILE = "/home/developer/.cf-install-id"
AGENT_FILE = "/home/developer/.cf-coding-agent"

# urllib defaults to "Python-urllib/3.x", which Cloudflare's managed bot rules
# reject with 403 before the request reaches the collector. Any non-default
# User-Agent passes. This is the exact failure a real deploy hit.
USER_AGENT = "cf-telemetry-check/1.0"

DEFAULT_EMAIL = "prodcheck@stand.example"
DEFAULT_DOMAIN = "prodcheck.example.cloud"


def read_file(path, default=None):
    try:
        with open(path) as handle:
            return handle.read().strip()
    except OSError as exc:
        if default is not None:
            return default
        sys.exit("FAIL: cannot read %s (%s)" % (path, exc))


def read_config():
    raw = read_file(CONFIG_FILE)
    config = {}
    for line in raw.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            config[key.strip()] = value.strip()

    url = config.get("TELEMETRY_URL", "").rstrip("/")
    secret = config.get("TELEMETRY_SECRET", "")
    if not url or not secret:
        sys.exit("FAIL: %s is missing TELEMETRY_URL or TELEMETRY_SECRET" % CONFIG_FILE)
    if secret.startswith("REPLACE_"):
        sys.exit(
            "FAIL: the secret is still the placeholder %r.\n"
            "      The manifest was pasted without substituting it, so telemetry\n"
            "      is dormant in this environment by design." % secret
        )
    return url, secret


def post(url, headers, body=None, timeout=10):
    request = urllib.request.Request(url, data=body, headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status, response.read(400).decode()


def main(argv):
    email = argv[1] if len(argv) > 1 else DEFAULT_EMAIL
    domain = argv[2] if len(argv) > 2 else DEFAULT_DOMAIN

    url, secret = read_config()
    install_id = read_file(INSTALL_ID_FILE)
    agent = read_file(AGENT_FILE, "copilot") or "copilot"

    print("collector:  %s" % url)
    print("install_id: %s" % install_id)
    print("agent:      %s" % agent)
    print()

    # 1. Liveness, and a direct demonstration of the User-Agent rule.
    print("[1] GET /health")
    try:
        status, text = post(url + "/health", {"User-Agent": USER_AGENT})
        print("    %s %s" % (status, text))
    except urllib.error.HTTPError as exc:
        if exc.code == 403:
            sys.exit(
                "    403 Forbidden — blocked at the edge, not by the collector.\n"
                "    Something upstream is rejecting this client entirely."
            )
        sys.exit("    HTTP %s — %s" % (exc.code, exc.reason))
    except Exception as exc:
        sys.exit("    unreachable: %s: %s" % (type(exc).__name__, exc))

    # 2. The same request urllib would send by default, to show the contrast.
    print("[2] GET /health with urllib's default User-Agent (expected to fail)")
    try:
        urllib.request.urlopen(url + "/health", timeout=10)
        print("    200 — not blocked; the edge is not filtering on User-Agent here")
    except urllib.error.HTTPError as exc:
        print("    %s %s  <- this is why an emitter without an explicit UA is lost"
              % (exc.code, exc.reason))
    except Exception as exc:
        print("    %s: %s" % (type(exc).__name__, exc))

    # 3. One real environment_provisioned, byte-identical to the manifest's.
    print("[3] POST /v1/events  (environment_provisioned)")
    event = {
        "schema_version": 1,
        "install_id": install_id,
        "session_id": str(uuid.uuid4()),
        "seq": 1,
        "event": "environment_provisioned",
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "emitter": "manifest",
        "emitter_version": "manual-check",
        "props": {
            "domain": domain,
            "user_email": email,
            "agent": agent,
            "script_version": "manual-check",
        },
    }
    body = json.dumps({"events": [event]}, separators=(",", ":")).encode()
    headers = {
        "Content-Type": "application/json",
        "User-Agent": USER_AGENT,
        # HMAC over the raw body, so the secret never crosses the wire.
        "X-CF-Signature": "sha256=" + hmac.new(
            secret.encode(), body, hashlib.sha256).hexdigest(),
    }

    try:
        status, text = post(url + "/v1/events", headers, body)
    except urllib.error.HTTPError as exc:
        detail = exc.read(300).decode(errors="replace")
        if exc.code == 401:
            sys.exit(
                "    401 %s\n"
                "    The signature did not verify: the secret in %s does not\n"
                "    match the collector's TELEMETRY_SECRET." % (detail, CONFIG_FILE)
            )
        sys.exit("    HTTP %s %s" % (exc.code, detail))
    except Exception as exc:
        sys.exit("    failed: %s: %s" % (type(exc).__name__, exc))

    print("    %s %s" % (status, text))
    try:
        accepted = json.loads(text).get("accepted", 0)
    except ValueError:
        accepted = 0
    if accepted < 1:
        sys.exit("FAIL: the collector answered but stored nothing.")

    print()
    print("PASS — the event was stored. It should appear on the dashboard as")
    print("       %s / %s within a few seconds." % (email, domain))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
