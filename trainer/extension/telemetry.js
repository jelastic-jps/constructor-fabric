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

// Its own version, not SCHEMA_VERSION. The event envelope and the feedback
// envelope move independently (feedback design §4.1); reusing the event
// constant would silently couple them the first time either changes.
const FEEDBACK_SCHEMA_VERSION = 1;
const FEEDBACK_FILENAME = 'feedback.jsonl';
// Its own budget. One feedback is up to 80 KB, so sharing the 2 MB event spool
// would let a few submissions evict a trainee's whole step history — and a
// stuck feedback would hold step events behind it (feedback design §4.4).
const FEEDBACK_SPOOL_MAX_BYTES = 1 * 1024 * 1024;

const BATCH_MAX_EVENTS = 100;
const FLUSH_INTERVAL_MS = 30 * 1000;
const BACKOFF_START_MS = 30 * 1000;
const BACKOFF_MAX_MS = 30 * 60 * 1000; // capped, but retried indefinitely:
                                       // a container can regain egress at any time
const REQUEST_TIMEOUT_MS = 10 * 1000;

let EMITTER_VERSION = '0.0.0';  // set by setVersion() from package.json
let lastNote = '';        // suppresses repeats of an unchanged complaint

// Diagnostics go to the extension host log, which the trainee never sees —
// so this does not weaken the rule at the top of the file. It exists because
// the manifest emitter's sibling failure (a Cloudflare 403 on a default
// User-Agent) was only diagnosable because that emitter logged; this one was
// silent by design and would have shown nothing at all.
//
// Repeats of an identical message are dropped: the flusher retries on a
// backoff, and an unreachable collector should produce one line, not one
// every 30 seconds.
function note(message) {
  try {
    if (message === lastNote) return;
    lastNote = message;
    console.error('[telemetry] ' + message);
  } catch (e) {
    // Logging must never be the thing that breaks.
  }
}

function describe(e) {
  if (!e) return 'unknown error';
  return (e.code ? e.code + ': ' : '') + (e.message || String(e));
}
let config = null;        // { url, secret, installId } once loaded
let sessionId = null;     // fresh per extension host start — see nextSeq()
let seq = 0;
let spoolFile = null;
let flushTimer = null;
let flushing = false;
let backoffMs = 0;
let nextAttemptAt = 0;
let feedbackFile = null;
let feedbackFlushing = false;
let feedbackBackoffMs = 0;
let feedbackNextAttemptAt = 0;

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
  if (!url || !secret) {
    note('dormant: ' + CONFIG_FILE + ' has no TELEMETRY_URL/TELEMETRY_SECRET');
    return null;
  }
  if (secret.indexOf('REPLACE_') === 0) {
    note('dormant: the secret is still the manifest placeholder, so the JPS was ' +
         'pasted without substituting it');
    return null;
  }
  const installId = fs.readFileSync(INSTALL_ID_FILE, 'utf8').trim();
  if (!installId) {
    note('dormant: ' + INSTALL_ID_FILE + ' is empty');
    return null;
  }
  return { url, secret, installId };
}

// --- spool -----------------------------------------------------------------

function readLines(file) {
  try {
    return fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim() !== '');
  } catch (e) {
    // ENOENT is the normal case before the first write. Anything else means a
    // spool we cannot read, which must not look identical to an empty one.
    if (!e || e.code !== 'ENOENT') {
      note('could not read ' + path.basename(file) + ': ' + describe(e));
    }
    return [];
  }
}

function writeLines(file, lines) {
  fs.writeFileSync(file, lines.length ? lines.join('\n') + '\n' : '');
}

function readSpoolLines() { return readLines(spoolFile); }
function writeSpoolLines(lines) { return writeLines(spoolFile, lines); }

function appendToSpool(line) {
  fs.appendFileSync(spoolFile, line + '\n');

  let stat;
  try {
    stat = fs.statSync(spoolFile);
  } catch (e) {
    note('cannot stat the spool, so its size is unbounded: ' + describe(e));
    return;
  }
  if (stat.size <= SPOOL_MAX_BYTES) return;

  // Over the cap: drop OLDEST, keep newest. Containers are destroyed precisely
  // when a trainee gives up, so the most recent events are the ones worth
  // keeping — and furthest-step is a maximum, so newest-wins preserves it.
  // The loss is not silent: dropped events leave seq gaps that the collector
  // surfaces as MAX(seq) - COUNT(*) within the session.
  const lines = readSpoolLines();
  const kept = lines.slice(Math.max(0, lines.length - SPOOL_MAX_LINES));
  note('spool over ' + SPOOL_MAX_BYTES + ' bytes: dropped ' +
       (lines.length - kept.length) + ' oldest event(s). They will show as seq ' +
       'gaps at the collector.');
  writeSpoolLines(kept);
}

// --- transport -------------------------------------------------------------

function postBatch(events, done) {
  let body;
  try {
    body = Buffer.from(JSON.stringify({ events }), 'utf8');
  } catch (e) {
    note('could not serialise a batch of ' + events.length + ': ' + describe(e));
    return done(false);
  }

  let target;
  try {
    target = new URL(config.url + '/v1/events');
  } catch (e) {
    note('TELEMETRY_URL is not a usable URL: ' + JSON.stringify(config.url));
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
        // Identify the client explicitly. Node sends no User-Agent by default,
        // which happens to pass today — but relying on the ABSENCE of a header
        // is fragile, and the manifest emitter was blocked in production by a
        // Cloudflare bot rule matching urllib's default UA. Name ourselves
        // rather than depend on not being noticed.
        'User-Agent': 'cf-telemetry-trainer/' + EMITTER_VERSION,
        // HMAC over the raw body, so the secret itself never crosses the wire.
        'X-CF-Signature':
          'sha256=' + crypto.createHmac('sha256', config.secret).update(body).digest('hex')
      }
    },
    (res) => {
      res.resume(); // drain, so the socket can be reused
      const code = res.statusCode;
      // 2xx means stored. A 4xx means this batch will never become valid, so
      // discarding it is correct — retrying forever on data the collector has
      // already refused is how a spool grows without bound.
      if (code >= 400) {
        // Name the likely cause: these three are the ones that actually happen,
        // and they are indistinguishable from "no data" without this line.
        const hint =
          code === 401 ? ' — signature rejected; the secret here does not match the collector'
          : code === 403 ? ' — refused before reaching the collector; something upstream is blocking this client'
          : code >= 500 ? ' — collector error; will retry'
          : '';
        note('POST /v1/events returned ' + code + hint +
             (code < 500 ? ' (batch of ' + events.length + ' discarded)' : ''));
      } else {
        note('delivering again: ' + code + ', ' + events.length + ' event(s)');
      }
      done(code >= 200 && code < 500);
    }
  );

  req.on('timeout', () => {
    note('POST /v1/events timed out after ' + REQUEST_TIMEOUT_MS + 'ms');
    req.destroy();
  });
  req.on('error', (e) => {
    note('POST /v1/events failed: ' + describe(e));
    done(false);
  });
  req.end(body);
}

function flush() {
  if (flushing || !config) return;
  if (Date.now() < nextAttemptAt) return;

  let lines;
  try {
    lines = readSpoolLines();
  } catch (e) {
    note('cannot read the spool at ' + spoolFile + ': ' + describe(e));
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
      note('dropped an unreadable spool line');
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
        note('retrying in ' + Math.round(backoffMs / 1000) + 's; ' +
             lines.length + ' event(s) waiting in the spool');
      }
    } catch (e) {
      note('could not update the spool after a flush: ' + describe(e));
    }
  };

  if (events.length === 0) return finish(true);

  try {
    postBatch(events, finish);
  } catch (e) {
    note('flush crashed: ' + describe(e));
    finish(false);
  }
}

function postFeedback(item, done) {
  let body;
  try {
    body = Buffer.from(JSON.stringify(item), 'utf8');
  } catch (e) {
    note('could not serialise feedback: ' + describe(e));
    return done(true); // unserialisable will never become valid — drop it
  }

  let target;
  try {
    target = new URL(config.url + '/v1/feedback');
  } catch (e) {
    note('bad telemetry URL: ' + describe(e));
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
        'User-Agent': 'cf-telemetry-trainer/' + EMITTER_VERSION,
        'X-CF-Signature':
          'sha256=' + crypto.createHmac('sha256', config.secret).update(body).digest('hex')
      }
    },
    (res) => {
      res.resume();
      const code = res.statusCode;
      if (code >= 200 && code < 300) return done(true);
      if (code < 500) {
        // The trainee has already been thanked, so this is louder than the
        // equivalent on the event path: a 4xx here means their words are gone.
        note('feedback rejected with ' + code +
             (code === 404 ? ' — this collector has no /v1/feedback endpoint'
              : code === 401 ? ' — signature rejected'
              : '') + '; discarded');
        return done(true);
      }
      note('feedback POST returned ' + code + '; will retry');
      done(false);
    }
  );

  req.on('timeout', () => req.destroy());
  req.on('error', (e) => {
    note('feedback POST failed: ' + describe(e));
    done(false);
  });
  req.end(body);
}

function flushFeedback() {
  if (feedbackFlushing || !config || !feedbackFile) return;
  // Its own clock, not the event path's nextAttemptAt: the separate spool
  // exists so a struggling feedback endpoint cannot hold up step events (and
  // vice versa), and sharing a backoff clock would silently recouple them.
  if (Date.now() < feedbackNextAttemptAt) return;

  let lines;
  try {
    lines = readLines(feedbackFile);
  } catch (e) {
    note('could not read the feedback spool: ' + describe(e));
    return;
  }
  if (lines.length === 0) return;

  let item;
  try {
    item = JSON.parse(lines[0]);
  } catch (e) {
    // Unparseable head would block the queue forever. Drop it and say so.
    note('dropped an unreadable feedback spool line');
    try { writeLines(feedbackFile, lines.slice(1)); } catch (e2) {}
    return;
  }

  feedbackFlushing = true;
  postFeedback(item, (ok) => {
    feedbackFlushing = false;
    if (ok) {
      feedbackBackoffMs = 0;
      feedbackNextAttemptAt = 0;
      try {
        writeLines(feedbackFile, readLines(feedbackFile).slice(1));
      } catch (e) {
        note('could not trim the feedback spool: ' + describe(e));
      }
      return;
    }
    // Retryable failure (5xx or transport error): back off exponentially,
    // same shape as the event path, but on its own clock — see above.
    feedbackBackoffMs = feedbackBackoffMs ? Math.min(feedbackBackoffMs * 2, BACKOFF_MAX_MS) : BACKOFF_START_MS;
    feedbackNextAttemptAt = Date.now() + feedbackBackoffMs;
    note('retrying feedback in ' + Math.round(feedbackBackoffMs / 1000) + 's; ' +
         lines.length + ' feedback item(s) waiting in the spool');
  });
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
    feedbackFile = path.join(stateDir, FEEDBACK_FILENAME);
    fs.mkdirSync(stateDir, { recursive: true });

    // A UUID per extension host start, NOT persisted. Uniqueness at the
    // collector is (install_id, session_id, seq), so a restarted Trainer that
    // begins again at seq 1 cannot collide with its previous run. Persisting a
    // counter instead would mean a lost or truncated counter file silently
    // discarding a whole restarted journey behind HTTP 200s.
    sessionId = crypto.randomUUID();
    seq = 0;

    flushTimer = setInterval(() => {
      try { flush(); } catch (e) { note('scheduled flush crashed: ' + describe(e)); }
      try { flushFeedback(); } catch (e) { note('scheduled feedback flush crashed: ' + describe(e)); }
    }, FLUSH_INTERVAL_MS);
    if (flushTimer.unref) flushTimer.unref();
    note('active: sending to ' + config.url + ' as install ' + config.installId +
         ', session ' + sessionId);
    flush();
  } catch (e) {
    note('failed to start, so no events will be sent: ' + describe(e));
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
    // Still swallowed — see the rule at the top of this file — but no longer
    // invisible. A failure here means the event was lost before it reached the
    // spool, so it will not even appear as a seq gap.
    note('dropped event ' + JSON.stringify(event) + ': ' + describe(e));
  }
}

/**
 * Record one piece of volunteered feedback. Never throws.
 *
 * Spooled to its own file and shipped one per request — never batched. At
 * 20 000 characters a payload reaches 80 KB, and several in one event batch
 * would exceed the collector's body limit, producing a 413 that the event
 * flusher counts as success and discards (feedback design §3).
 */
function submitFeedback(feedback) {
  try {
    if (!config || !feedbackFile) return;
    const line = JSON.stringify({
      schema_version: FEEDBACK_SCHEMA_VERSION,
      feedback_id: crypto.randomUUID(),
      install_id: config.installId,
      session_id: sessionId,
      step_id: (feedback && feedback.stepId) || null,
      text: String((feedback && feedback.text) || ''),
      no_contact: Boolean(feedback && feedback.noContact),
      ts: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
      emitter: EMITTER,
      emitter_version: EMITTER_VERSION
    });

    fs.appendFileSync(feedbackFile, line + '\n');
    let stat;
    try {
      stat = fs.statSync(feedbackFile);
    } catch (e) {
      stat = null;
    }
    if (stat && stat.size > FEEDBACK_SPOOL_MAX_BYTES) {
      const lines = readLines(feedbackFile);
      const kept = lines.slice(1);
      note('feedback spool is full; dropped the oldest of ' + lines.length);
      writeLines(feedbackFile, kept);
    }
    flushFeedback();
  } catch (e) {
    note('could not record feedback: ' + describe(e));
  }
}

/** Whether telemetry is configured. Drives whether the button is offered. */
function isActive() { return Boolean(config); }

function dispose() {
  try {
    if (flushTimer) clearInterval(flushTimer);
    flushTimer = null;
    flush();
  } catch (e) {
    note('shutdown flush failed; unsent events remain spooled: ' + describe(e));
  }
  try { flushFeedback(); } catch (e) {}
}

function setVersion(v) { if (v) EMITTER_VERSION = String(v); }

module.exports = { init, emit, submitFeedback, isActive, dispose, setVersion };
