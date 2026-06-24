#!/usr/bin/env python3
"""
notify-install.py — Send notification email via direct SMTP.
Falls back through multiple SMTP configs. Never raises.

Usage:
  export SMTP_HOST=smtp.gmail.com
  export SMTP_PORT=587
  export SMTP_USER=you@gmail.com
  export SMTP_PASS=app-password
  export NOTIFY_RECIPIENT=admin@example.com
  export NOTIFY_DOMAIN=env-abc.demo.jelastic.com
  export NOTIFY_PROVIDER=claude
  export NOTIFY_MODEL=claude-sonnet-4-6
  python3 notify-install.py
"""

import smtplib
import os
import sys
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from datetime import datetime, timezone


def send_smtp(host, port, user, password, sender, recipient, subject, body_html):
    """Send email via SMTP. Returns True on success."""
    msg = MIMEMultipart("alternative")
    msg["From"] = sender
    msg["To"] = recipient
    msg["Subject"] = subject
    msg.attach(MIMEText(body_html, "html"))

    if port == 465:
        with smtplib.SMTP_SSL(host, port, timeout=15) as srv:
            srv.login(user, password)
            srv.sendmail(sender, [recipient], msg.as_string())
    else:
        with smtplib.SMTP(host, port, timeout=15) as srv:
            srv.starttls()
            srv.login(user, password)
            srv.sendmail(sender, [recipient], msg.as_string())
    return True


def main():
    domain = os.environ.get("NOTIFY_DOMAIN", "unknown")
    provider = os.environ.get("NOTIFY_PROVIDER", "unknown")
    model = os.environ.get("NOTIFY_MODEL", "unknown")
    customer_email = os.environ.get("NOTIFY_EMAIL", "not provided")
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    recipient = os.environ.get("NOTIFY_RECIPIENT", "")
    if not recipient:
        print("[notify] NOTIFY_RECIPIENT not set, skipping")
        return

    subject = f"[Constructor Fabric] New instance: {domain}"
    body = f"""<h2>New Constructor Fabric instance provisioned</h2>
<table style="border-collapse:collapse;font-size:15px;">
<tr><td style="padding:4px 12px;font-weight:bold;">Domain</td><td style="padding:4px 12px;"><a href="https://{domain}/">{domain}</a></td></tr>
<tr><td style="padding:4px 12px;font-weight:bold;">Customer</td><td style="padding:4px 12px;">{customer_email}</td></tr>
<tr><td style="padding:4px 12px;font-weight:bold;">Provider</td><td style="padding:4px 12px;">{provider}</td></tr>
<tr><td style="padding:4px 12px;font-weight:bold;">Model</td><td style="padding:4px 12px;">{model}</td></tr>
<tr><td style="padding:4px 12px;font-weight:bold;">Created</td><td style="padding:4px 12px;">{ts}</td></tr>
</table>"""

    # SMTP configs to try (first success wins)
    configs = []

    # Config 1: env vars
    if os.environ.get("SMTP_HOST"):
        configs.append({
            "host": os.environ["SMTP_HOST"],
            "port": int(os.environ.get("SMTP_PORT", "587")),
            "user": os.environ.get("SMTP_USER", ""),
            "password": os.environ.get("SMTP_PASS", ""),
            "sender": os.environ.get("SMTP_SENDER", os.environ.get("SMTP_USER", "")),
        })

    # Config 2: Gmail app password
    if os.environ.get("GMAIL_USER") and os.environ.get("GMAIL_APP_PASSWORD"):
        configs.append({
            "host": "smtp.gmail.com",
            "port": 587,
            "user": os.environ["GMAIL_USER"],
            "password": os.environ["GMAIL_APP_PASSWORD"],
            "sender": os.environ["GMAIL_USER"],
        })

    # Config 3: Outlook
    if os.environ.get("OUTLOOK_USER") and os.environ.get("OUTLOOK_PASSWORD"):
        configs.append({
            "host": "smtp-mail.outlook.com",
            "port": 587,
            "user": os.environ["OUTLOOK_USER"],
            "password": os.environ["OUTLOOK_PASSWORD"],
            "sender": os.environ["OUTLOOK_USER"],
        })

    if not configs:
        print("[notify] No SMTP credentials configured, skipping")
        return

    for i, cfg in enumerate(configs):
        try:
            print(f"[notify] Trying SMTP config {i+1}: {cfg['host']}:{cfg['port']} as {cfg['user']}")
            send_smtp(
                cfg["host"], cfg["port"], cfg["user"], cfg["password"],
                cfg["sender"], recipient, subject, body
            )
            print(f"[notify] Email sent successfully via {cfg['host']}")
            return
        except Exception as e:
            print(f"[notify] SMTP config {i+1} failed: {e}")

    print("[notify] All SMTP configs failed. Instance still created.")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"[notify] Unexpected error: {e}")
    sys.exit(0)
