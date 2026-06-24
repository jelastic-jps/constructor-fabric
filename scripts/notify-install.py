#!/usr/bin/env python3
"""Send notification email via SMTP. Never raises — always exits 0."""

import smtplib
import os
import sys
from email.mime.text import MIMEText
from datetime import datetime, timezone


def main():
    domain = os.environ.get("NOTIFY_DOMAIN", "unknown")
    provider = os.environ.get("NOTIFY_PROVIDER", "unknown")
    model = os.environ.get("NOTIFY_MODEL", "unknown")
    recipient = os.environ.get("NOTIFY_RECIPIENT", "")

    if not recipient:
        print("[notify] NOTIFY_RECIPIENT not set, skipping")
        return

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    subject = f"[Constructor Fabric] New instance: {domain}"
    body = f"""<h2>New Constructor Fabric instance provisioned</h2>
<table style="border-collapse:collapse;font-size:15px;">
<tr><td style="padding:4px 12px;font-weight:bold;">Domain</td><td style="padding:4px 12px;"><a href="https://{domain}/">{domain}</a></td></tr>
<tr><td style="padding:4px 12px;font-weight:bold;">Provider</td><td style="padding:4px 12px;">{provider}</td></tr>
<tr><td style="padding:4px 12px;font-weight:bold;">Model</td><td style="padding:4px 12px;">{model}</td></tr>
<tr><td style="padding:4px 12px;font-weight:bold;">Created</td><td style="padding:4px 12px;">{ts}</td></tr>
</table>"""

    msg = MIMEText(body, "html")
    msg["Subject"] = subject
    msg["To"] = recipient

    smtp_host = os.environ.get("SMTP_HOST", "smtp.gmail.com")
    smtp_port = int(os.environ.get("SMTP_PORT", "587"))
    smtp_user = os.environ.get("SMTP_USER", "")
    smtp_pass = os.environ.get("SMTP_PASS", "")
    sender = os.environ.get("SMTP_SENDER", smtp_user)

    if not smtp_user or not smtp_pass:
        print("[notify] SMTP credentials not set, skipping")
        return

    msg["From"] = sender

    try:
        if smtp_port == 465:
            with smtplib.SMTP_SSL(smtp_host, smtp_port, timeout=15) as srv:
                srv.login(smtp_user, smtp_pass)
                srv.sendmail(sender, [recipient], msg.as_string())
        else:
            with smtplib.SMTP(smtp_host, smtp_port, timeout=15) as srv:
                srv.starttls()
                srv.login(smtp_user, smtp_pass)
                srv.sendmail(sender, [recipient], msg.as_string())
        print(f"[notify] Email sent to {recipient}")
    except Exception as e:
        print(f"[notify] SMTP failed: {e}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"[notify] Error: {e}")
    sys.exit(0)
