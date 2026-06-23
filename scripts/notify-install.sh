#!/bin/sh
# notify-install.sh — Send notification when a new Constructor Fabric instance is created.
# Tries EmailJS first, falls back to Brevo. Never exits non-zero.
#
# Environment variables (set by JPS manifest):
#   NOTIFY_DOMAIN    — environment domain (e.g. env-abc.demo.jelastic.com)
#   NOTIFY_EMAIL     — customer email from install form
#   NOTIFY_PROVIDER  — LLM provider (openai/claude)
#   NOTIFY_MODEL     — LLM model selected
#
# Secrets (set by JPS manifest env or baked into image):
#   EMAILJS_SERVICE_ID   — EmailJS service ID
#   EMAILJS_TEMPLATE_ID  — EmailJS template ID
#   EMAILJS_USER_ID      — EmailJS user (public key)
#   BREVO_API_KEY        — Brevo API key
#   BREVO_SENDER_EMAIL   — Brevo sender email
#   BREVO_RECIPIENT_EMAIL — notification recipient email

set -eu

DOMAIN="${NOTIFY_DOMAIN:-unknown}"
EMAIL="${NOTIFY_EMAIL:-unknown}"
PROVIDER="${NOTIFY_PROVIDER:-unknown}"
MODEL="${NOTIFY_MODEL:-unknown}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() {
  echo "[notify] $(date -u +%H:%M:%S) $*"
}

# ── EmailJS ──────────────────────────────────────────────────────────
try_emailjs() {
  if [ -z "${EMAILJS_SERVICE_ID:-}" ] || [ -z "${EMAILJS_TEMPLATE_ID:-}" ] || [ -z "${EMAILJS_USER_ID:-}" ]; then
    log "EmailJS: missing credentials, skipping"
    return 1
  fi

  log "EmailJS: sending notification..."
  HTTP_CODE=$(curl -s -o /tmp/emailjs_resp.json -w "%{http_code}" \
    -X POST "https://api.emailjs.com/api/v1.0/email/send" \
    -H "Content-Type: application/json" \
    -d "{
      \"service_id\": \"${EMAILJS_SERVICE_ID}\",
      \"template_id\": \"${EMAILJS_TEMPLATE_ID}\",
      \"user_id\": \"${EMAILJS_USER_ID}\",
      \"template_params\": {
        \"domain\": \"${DOMAIN}\",
        \"customer_email\": \"${EMAIL}\",
        \"provider\": \"${PROVIDER}\",
        \"model\": \"${MODEL}\",
        \"timestamp\": \"${TIMESTAMP}\"
      }
    }" 2>/dev/null) || HTTP_CODE="000"

  if [ "$HTTP_CODE" = "200" ]; then
    log "EmailJS: success (HTTP $HTTP_CODE)"
    return 0
  else
    log "EmailJS: failed (HTTP $HTTP_CODE)"
    cat /tmp/emailjs_resp.json 2>/dev/null && echo ""
    return 1
  fi
}

# ── Brevo ────────────────────────────────────────────────────────────
try_brevo() {
  if [ -z "${BREVO_API_KEY:-}" ] || [ -z "${BREVO_SENDER_EMAIL:-}" ] || [ -z "${BREVO_RECIPIENT_EMAIL:-}" ]; then
    log "Brevo: missing credentials, skipping"
    return 1
  fi

  log "Brevo: sending notification..."
  HTTP_CODE=$(curl -s -o /tmp/brevo_resp.json -w "%{http_code}" \
    -X POST "https://api.brevo.com/v3/smtp/email" \
    -H "accept: application/json" \
    -H "api-key: ${BREVO_API_KEY}" \
    -H "content-type: application/json" \
    -d "{
      \"sender\": {\"email\": \"${BREVO_SENDER_EMAIL}\", \"name\": \"Constructor Fabric\"},
      \"to\": [{\"email\": \"${BREVO_RECIPIENT_EMAIL}\"}],
      \"subject\": \"New Constructor Fabric instance: ${DOMAIN}\",
      \"htmlContent\": \"<h2>New instance provisioned</h2><p><b>Domain:</b> ${DOMAIN}<br><b>Customer:</b> ${EMAIL}<br><b>Provider:</b> ${PROVIDER}<br><b>Model:</b> ${MODEL}<br><b>Time:</b> ${TIMESTAMP}</p>\"
    }" 2>/dev/null) || HTTP_CODE="000"

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    log "Brevo: success (HTTP $HTTP_CODE)"
    return 0
  else
    log "Brevo: failed (HTTP $HTTP_CODE)"
    cat /tmp/brevo_resp.json 2>/dev/null && echo ""
    return 1
  fi
}

# ── Main ─────────────────────────────────────────────────────────────
log "New instance: domain=${DOMAIN} email=${EMAIL} provider=${PROVIDER} model=${MODEL}"

SEND_OK=0

try_emailjs && SEND_OK=1 || true

if [ "$SEND_OK" = "0" ]; then
  try_brevo && SEND_OK=1 || true
fi

if [ "$SEND_OK" = "0" ]; then
  log "WARNING: All notification methods failed. Instance still created successfully."
fi

# Always exit 0 — notification failure must never break the install
exit 0
