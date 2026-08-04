// Journey telemetry emitter.
//
// Records progress through the training so the curriculum can be improved:
// which step loses people, which gate frustrates them, whether the choice of
// coding agent matters. It never records prompts, files, or code.
//
// THE RULE THIS FILE EXISTS TO KEEP: no telemetry failure may fail an install,
// block the UI, or surface an error to the trainee. Every entry point is
// wrapped and every failure is swallowed. A container with no egress simply
// accumulates a bounded spool that is never sent, and nobody notices.
//
// Config arrives on disk, planted by manifest.jps at deploy time — su/sudo
// transitions during bootstrap drop container env vars, so files are the only
// reliable transport.

const fs = require('fs');
const path = require('path');
const os = require('os');
const http = require('http');
const https = require('https');
const crypto = require('crypto');

const CONFIG_FILE = path.join(os.homedir(), '.cf-telemetry');
const INSTALL_ID_FILE = path.join(os.homedir(), '.cf-install-id');

const SCHEMA_VERSION = 1;
const EMITTER = 'trainer';

const SPOOL_FILENAME = 'spool.jsonl';
// Bounds, not hygiene: an unbounded spool on a container with no egress fills
// the trainee's disk and breaks their environment — which would violate the
// very rule at the top of this file.
const SPOOL_MAX_BYTES = 2 * 1024 * 1024;
const SPOOL_MAX_LINES = 5000;

const BATCH_MAX_EVENTS = 100;
const FLUSH_INTERVAL_MS = 30 * 1000;
const BACKOFF_START_MS = 30 * 1000;
const BACKOFF_MAX_MS = 30 * 60 * 1000; // capped, but retried indefinitely:
                                       // a container can regain egress at any time
const REQUEST_TIMEOUT_MS = 10 * 1000;

let config = null;        // { url, secret, installId } once loaded
let sessionId = null;     // fresh per extension host start — see nextSeq()
let seq = 0;
let spoolFile = null;
let flushTimer = null;
let flushing = false;
let backoffMs = 0;
let nextAttemptAt = 0;

// --- configuration ---------------------------------------------------------

function readConfig() {
  const raw = fs.readFileSync(CONFIG_FILE, 'utf8');
  const out = {};
  for (const line of raw.split('\n')) {
    const eq = line.indexOf('=');
    if (eq > 0) out[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
  const url = (out.TELEMETRY_URL || '').replace(/\/+$/, '');
  const secret = out.TELEMETRY_SECRET || '';
  // The manifest ships a placeholder that is substituted by hand at paste time.
  // An un-substituted manifest must degrade to silence, not to 401s forever.
  if (!url || !secret || secret.indexOf('REPLACE_') === 0) return null;
  const installId = fs.readFileSync(INSTALL_ID_FILE, 'utf8').trim();
  if (!installId) return null;
  return { url, secret, installId };
}

// --- spool -----------------------------------------------------------------

function readSpoolLines() {
  try {
    const raw = fs.readFileSync(spoolFile, 'utf8');
    return raw.split('\n').filter((l) => l.trim() !== '');
  } catch (e) {
    return [];
  }
}

function writeSpoolLines(lines) {
  fs.writeFileSync(spoolFile, lines.length ? lines.join('\n') + '\n' : '');
}

function appendToSpool(line) {
  fs.appendFileSync(spoolFile, line + '\n');

  let stat;
  try {
    stat = fs.statSync(spoolFile);
  } catch (e) {
    return;
  }
  if (stat.size <= SPOOL_MAX_BYTES) return;

  // Over the cap: drop OLDEST, keep newest. Containers are destroyed precisely
  // when a trainee gives up, so the most recent events are the ones worth
  // keeping — and furthest-step is a maximum, so newest-wins preserves it.
  // The loss is not silent: dropped events leave seq gaps that the collector
  // surfaces as MAX(seq) - COUNT(*) within the session.
  const lines = readSpoolLines();
  writeSpoolLines(lines.slice(Math.max(0, lines.length - SPOOL_MAX_LINES)));
}

// --- transport -------------------------------------------------------------

function postBatch(events, done) {
  let body;
  try {
    body = Buffer.from(JSON.stringify({ events }), 'utf8');
  } catch (e) {
    return done(false);
  }

  let target;
  try {
    target = new URL(config.url + '/v1/events');
  } catch (e) {
    return done(false);
  }

  const transport = target.protocol === 'https:' ? https : http;
  const req = transport.request(
    {
      protocol: target.protocol,
      hostname: target.hostname,
      port: target.port || (target.protocol === 'https:' ? 443 : 80),
      path: target.pathname,
      method: 'POST',
      timeout: REQUEST_TIMEOUT_MS,
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': body.length,
        // HMAC over the raw body, so the secret itself never crosses the wire.
        'X-CF-Signature':
          'sha256=' + crypto.createHmac('sha256', config.secret).update(body).digest('hex')
      }
    },
    (res) => {
      res.resume(); // drain, so the socket can be reused
      // 2xx means stored. A 4xx means this batch will never become valid, so
      // discarding it is correct — retrying forever on data the collector has
      // already refused is how a spool grows without bound.
      done(res.statusCode >= 200 && res.statusCode < 500);
    }
  );

  req.on('timeout', () => req.destroy());
  req.on('error', () => done(false));
  req.end(body);
}

function flush() {
  if (flushing || !config) return;
  if (Date.now() < nextAttemptAt) return;

  let lines;
  try {
    lines = readSpoolLines();
  } catch (e) {
    return;
  }
  if (lines.length === 0) return;

  const batchLines = lines.slice(0, BATCH_MAX_EVENTS);
  const events = [];
  for (const line of batchLines) {
    try {
      events.push(JSON.parse(line));
    } catch (e) {
      // Unparseable line: drop it rather than block the whole spool forever.
    }
  }

  flushing = true;
  const finish = (ok) => {
    flushing = false;
    try {
      if (ok) {
        // Re-read: the trainee may have generated more events mid-flight.
        writeSpoolLines(readSpoolLines().slice(batchLines.length));
        backoffMs = 0;
        nextAttemptAt = 0;
      } else {
        backoffMs = backoffMs ? Math.min(backoffMs * 2, BACKOFF_MAX_MS) : BACKOFF_START_MS;
        nextAttemptAt = Date.now() + backoffMs;
      }
    } catch (e) {
      // ignore
    }
  };

  if (events.length === 0) return finish(true);

  try {
    postBatch(events, finish);
  } catch (e) {
    finish(false);
  }
}

// --- public API ------------------------------------------------------------

/**
 * Wire up the emitter. Safe to call when nothing is configured — it simply
 * stays dormant and every later emit() is a no-op.
 */
function init(stateDir) {
  try {
    config = readConfig();
    if (!config) return;
    spoolFile = path.join(stateDir, SPOOL_FILENAME);
    fs.mkdirSync(stateDir, { recursive: true });

    // A UUID per extension host start, NOT persisted. Uniqueness at the
    // collector is (install_id, session_id, seq), so a restarted Trainer that
    // begins again at seq 1 cannot collide with its previous run. Persisting a
    // counter instead would mean a lost or truncated counter file silently
    // discarding a whole restarted journey behind HTTP 200s.
    sessionId = crypto.randomUUID();
    seq = 0;

    flushTimer = setInterval(() => { try { flush(); } catch (e) {} }, FLUSH_INTERVAL_MS);
    if (flushTimer.unref) flushTimer.unref();
    flush();
  } catch (e) {
    config = null;
  }
}

/**
 * Record one event. Never throws, never blocks: the event is appended to the
 * spool and a background flusher ships it.
 */
function emit(event, props) {
  try {
    if (!config) return;
    // seq starts at 1 and steps by exactly 1 within a session; the collector's
    // gap count (MAX(seq) - COUNT(*)) is exact only because of that.
    seq += 1;
    appendToSpool(JSON.stringify({
      schema_version: SCHEMA_VERSION,
      install_id: config.installId,
      session_id: sessionId,
      seq,
      event,
      ts: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
      emitter: EMITTER,
      emitter_version: EMITTER_VERSION,
      props: props || {}
    }));
    flush();
  } catch (e) {
    // Deliberately swallowed. See the rule at the top of this file.
  }
}

function dispose() {
  try {
    if (flushTimer) clearInterval(flushTimer);
    flushTimer = null;
    flush();
  } catch (e) {
    // ignore
  }
}

let EMITTER_VERSION = '0.0.0';
function setVersion(v) { if (v) EMITTER_VERSION = String(v); }

module.exports = { init, emit, dispose, setVersion };
