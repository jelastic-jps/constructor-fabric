/* Node test for the feedback path. Run: node trainer/extension/telemetry.test.js
 * No framework — the extension host has none, and adding one for this would be
 * a dependency the Trainer does not otherwise carry. */
const assert = require('assert');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');

const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'cf-fb-'));
const home = fs.mkdtempSync(path.join(os.tmpdir(), 'cf-home-'));

const received = [];
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    received.push({ url: req.url, body: JSON.parse(body),
                    signature: req.headers['x-cf-signature'] });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end('{"ok":true}');
  });
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  fs.writeFileSync(path.join(home, '.cf-telemetry'),
    'TELEMETRY_URL=http://127.0.0.1:' + port + '\nTELEMETRY_SECRET=s3cret\n');
  fs.writeFileSync(path.join(home, '.cf-install-id'), 'inst-0000000000000001\n');
  process.env.HOME = home;
  os.homedir = () => home;

  const telemetry = require('./telemetry');
  telemetry.setVersion('2.0.0');
  telemetry.init(stateDir);

  assert.strictEqual(telemetry.isActive(), true, 'should be active');

  telemetry.submitFeedback({ text: 'the PRD step was confusing',
                             noContact: true, stepId: 'prd' });

  const spool = path.join(stateDir, 'feedback.jsonl');
  assert.ok(fs.existsSync(spool), 'feedback spool should exist');
  const line = JSON.parse(fs.readFileSync(spool, 'utf8').trim().split('\n')[0]);
  assert.strictEqual(line.text, 'the PRD step was confusing');
  assert.strictEqual(line.no_contact, true);
  assert.strictEqual(line.step_id, 'prd');
  assert.strictEqual(line.emitter, 'trainer');
  assert.ok(line.feedback_id && line.feedback_id.length >= 8, 'needs an id');

  setTimeout(() => {
    const posts = received.filter((r) => r.url === '/v1/feedback');
    assert.strictEqual(posts.length, 1, 'one POST to /v1/feedback');
    assert.strictEqual(posts[0].body.text, 'the PRD step was confusing');
    assert.ok(posts[0].signature.startsWith('sha256='), 'must be signed');
    assert.ok(!Array.isArray(posts[0].body), 'single item, never a batch');
    assert.strictEqual(fs.readFileSync(spool, 'utf8').trim(), '',
                       'spool drains on 200');

    // The event spool must be untouched by any of this.
    const eventSpool = path.join(stateDir, 'spool.jsonl');
    if (fs.existsSync(eventSpool)) {
      const lines = fs.readFileSync(eventSpool, 'utf8').trim();
      assert.ok(!lines.includes('the PRD step was confusing'),
                'feedback must not enter the event spool');
    }

    server.close();
    fs.rmSync(stateDir, { recursive: true, force: true });
    fs.rmSync(home, { recursive: true, force: true });
    console.log('ok — feedback emitter');

    runIndependenceTest();
  }, 400);
});

/*
 * Regression test for the coupling the separate feedback spool exists to
 * prevent: a struggling /v1/feedback must not delay /v1/events, and vice
 * versa. The collector here always 500s feedback (so it backs off and
 * retries) and always 200s events. If flushFeedback() ever goes back to
 * gating on the *event* path's nextAttemptAt/backoff state instead of its
 * own, this fails: the feedback backoff (30s) would also block the event
 * flush, and the event spool would still hold the event well within this
 * test's short window instead of draining immediately.
 */
function runIndependenceTest() {
  const stateDir2 = fs.mkdtempSync(path.join(os.tmpdir(), 'cf-fb2-'));
  const home2 = fs.mkdtempSync(path.join(os.tmpdir(), 'cf-home2-'));

  const received2 = [];
  const server2 = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      received2.push({ url: req.url, body: JSON.parse(body) });
      if (req.url === '/v1/feedback') {
        // Always fail feedback, so it backs off and stays spooled.
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end('{"ok":false}');
      } else {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end('{"ok":true,"stored":true}');
      }
    });
  });

  server2.listen(0, '127.0.0.1', () => {
    const port2 = server2.address().port;
    fs.writeFileSync(path.join(home2, '.cf-telemetry'),
      'TELEMETRY_URL=http://127.0.0.1:' + port2 + '\nTELEMETRY_SECRET=s3cret\n');
    fs.writeFileSync(path.join(home2, '.cf-install-id'), 'inst-0000000000000002\n');
    process.env.HOME = home2;
    os.homedir = () => home2;

    // Fresh module instance: module-level state (config, both spool files,
    // both backoff clocks) must not leak from the first scenario.
    delete require.cache[require.resolve('./telemetry')];
    const telemetry2 = require('./telemetry');
    telemetry2.setVersion('2.0.0');
    telemetry2.init(stateDir2);

    telemetry2.submitFeedback({ text: 'independence check',
                                noContact: false, stepId: null });

    setTimeout(() => {
      const feedbackSpool2 = path.join(stateDir2, 'feedback.jsonl');
      const feedbackRemaining = fs.readFileSync(feedbackSpool2, 'utf8').trim();
      assert.ok(feedbackRemaining.length > 0,
        'a failed (500) feedback POST must stay spooled, not be discarded');

      // Now drive an event through. The feedback path is backed off 30s at
      // this point; the event path must be entirely unaffected by that.
      telemetry2.emit('trainer_test_event', { note: 'must not be blocked' });

      setTimeout(() => {
        const eventSpool2 = path.join(stateDir2, 'spool.jsonl');
        const eventsRemaining = fs.existsSync(eventSpool2)
          ? fs.readFileSync(eventSpool2, 'utf8').trim() : 'MISSING';
        assert.strictEqual(eventsRemaining, '',
          "event flush must not be blocked by the feedback path's backoff");

        const eventPosts = received2.filter((r) => r.url === '/v1/events');
        assert.strictEqual(eventPosts.length, 1,
          'the event must actually have reached the collector, not just be presumed unblocked');

        const feedbackPosts = received2.filter((r) => r.url === '/v1/feedback');
        assert.ok(feedbackPosts.length >= 1, 'feedback POST must have been attempted');

        server2.close();
        fs.rmSync(stateDir2, { recursive: true, force: true });
        fs.rmSync(home2, { recursive: true, force: true });
        console.log('ok — feedback backoff does not block events');

        runOverflowTest();
      }, 400);
    }, 400);
  });
}

// Must match telemetry.js's FEEDBACK_SPOOL_MAX_BYTES. Not exported — the
// constant is deliberately private — so this is asserted against the same
// literal value described in the brief and in telemetry.js's own comment.
const FEEDBACK_SPOOL_MAX_BYTES_EXPECTED = 1 * 1024 * 1024;

/*
 * Regression test for the overflow trim: it must cut back to under budget,
 * not drop a single fixed-size line. A dropped line can be far smaller than
 * an 80 KB item, so a naive "slice(1)" can net-grow the file across a burst
 * of large submissions while offline — defeating the cap in exactly the
 * bursty-offline case it exists for.
 *
 * Deliberately mixed sizes: a backlog of small items followed by one item
 * large enough that removing just the single oldest (small) line cannot
 * bring the file back under budget. Uniform-size items would not catch this
 * — dropping one ~N KB line to make room for one new ~N KB line is a wash
 * either way, so the two implementations would look identical.
 */
function runOverflowTest() {
  const stateDir3 = fs.mkdtempSync(path.join(os.tmpdir(), 'cf-fb3-'));
  const home3 = fs.mkdtempSync(path.join(os.tmpdir(), 'cf-home3-'));

  const server3 = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end('{"ok":true,"stored":true}');
    });
  });

  server3.listen(0, '127.0.0.1', () => {
    const port3 = server3.address().port;
    fs.writeFileSync(path.join(home3, '.cf-telemetry'),
      'TELEMETRY_URL=http://127.0.0.1:' + port3 + '\nTELEMETRY_SECRET=s3cret\n');
    fs.writeFileSync(path.join(home3, '.cf-install-id'), 'inst-0000000000000003\n');
    process.env.HOME = home3;
    os.homedir = () => home3;

    delete require.cache[require.resolve('./telemetry')];
    const telemetry3 = require('./telemetry');
    telemetry3.setVersion('2.0.0');
    telemetry3.init(stateDir3);

    // Submitted in a tight synchronous loop so none of server3's responses
    // land until this loop returns — the trim itself happens inline inside
    // submitFeedback(), independent of the network.
    const SMALL = 'x'.repeat(50000); // ~50 KB per item, well under the cap on its own
    const SMALL_COUNT = 10;
    for (let i = 0; i < SMALL_COUNT; i++) {
      telemetry3.submitFeedback({ text: SMALL + '-small-' + i,
                                  noContact: false, stepId: null });
    }

    // ~700 KB on top of ~500 KB of small items overflows the 1 MiB cap by
    // roughly 150 KB — far more than any single ~50 KB oldest line can shed.
    const HUGE = 'x'.repeat(700000);
    telemetry3.submitFeedback({ text: HUGE + '-huge',
                                noContact: false, stepId: null });

    const feedbackSpool3 = path.join(stateDir3, 'feedback.jsonl');
    const raw = fs.readFileSync(feedbackSpool3, 'utf8');
    const byteSize = Buffer.byteLength(raw, 'utf8');
    assert.ok(byteSize <= FEEDBACK_SPOOL_MAX_BYTES_EXPECTED,
      'feedback spool must be trimmed back under its byte budget, not merely ' +
      'reduced by dropping one oldest line regardless of size ' +
      '(was ' + byteSize + ' bytes, budget ' + FEEDBACK_SPOOL_MAX_BYTES_EXPECTED + ')');

    const lines = raw.trim().length ? raw.trim().split('\n') : [];
    assert.ok(lines.length > 0 && lines.length < SMALL_COUNT + 1,
      'trimming must have dropped more than one small item to make room for the huge one');
    const newest = JSON.parse(lines[lines.length - 1]);
    assert.ok(newest.text.endsWith('-huge'),
      'drop OLDEST, keep newest — the most recently submitted item must survive');

    server3.close();
    fs.rmSync(stateDir3, { recursive: true, force: true });
    fs.rmSync(home3, { recursive: true, force: true });
    console.log('ok — feedback spool overflow trims to budget, keeping newest');

    runFlushWedgeTest();
  });
}

/*
 * Regression test for the try/catch flushFeedback() wraps around
 * postFeedback(): a *synchronous* throw from the transport must not leave
 * feedbackFlushing stuck true forever, which would silently kill feedback
 * delivery for the life of the process (every later flushFeedback() call
 * would hit the `if (feedbackFlushing ...) return;` guard and do nothing,
 * forever, with no error visible anywhere).
 *
 * setVersion() does String(v) with no sanitising, and the result goes
 * straight into the User-Agent header. A version string containing a
 * control character is a concrete, reachable trigger: Node's http.request
 * throws ERR_INVALID_CHAR synchronously, before postFeedback ever gets a
 * chance to call back — verified directly against node:20-alpine.
 */
function runFlushWedgeTest() {
  const stateDir4 = fs.mkdtempSync(path.join(os.tmpdir(), 'cf-fb4-'));
  const home4 = fs.mkdtempSync(path.join(os.tmpdir(), 'cf-home4-'));

  const received4 = [];
  const server4 = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      received4.push({ url: req.url });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end('{"ok":true}');
    });
  });

  server4.listen(0, '127.0.0.1', () => {
    const port4 = server4.address().port;
    fs.writeFileSync(path.join(home4, '.cf-telemetry'),
      'TELEMETRY_URL=http://127.0.0.1:' + port4 + '\nTELEMETRY_SECRET=s3cret\n');
    fs.writeFileSync(path.join(home4, '.cf-install-id'), 'inst-0000000000000004\n');
    process.env.HOME = home4;
    os.homedir = () => home4;

    delete require.cache[require.resolve('./telemetry')];
    const telemetry4 = require('./telemetry');
    // Control character in the version -> invalid User-Agent header value ->
    // http.request throws synchronously inside postFeedback.
    telemetry4.setVersion('1.0\n0');
    telemetry4.init(stateDir4);

    telemetry4.submitFeedback({ text: 'first, wedges feedbackFlushing if unguarded',
                                noContact: false, stepId: null });

    // That first flush's catch set a real ~30s backoff clock (feedbackNextAttemptAt),
    // which would itself block a second attempt made this soon — masking the
    // wedge either way. Fast-forward Date.now() past it so the second
    // submission's flush is gated only by feedbackFlushing, which is the one
    // thing this test cares about.
    const realNow = Date.now;
    Date.now = () => realNow() + 60000;
    try {
      telemetry4.setVersion('2.0.1'); // valid again, so this flush can reach the server
      telemetry4.submitFeedback({ text: 'second, proves the guard released the flag',
                                  noContact: false, stepId: null });
    } finally {
      Date.now = realNow;
    }

    setTimeout(() => {
      const posts = received4.filter((r) => r.url === '/v1/feedback');
      assert.ok(posts.length >= 1,
        'a feedback submission after a synchronous postFeedback throw must still ' +
        'attempt a POST — feedbackFlushing must not stay wedged true forever');

      server4.close();
      fs.rmSync(stateDir4, { recursive: true, force: true });
      fs.rmSync(home4, { recursive: true, force: true });
      console.log('ok — a synchronous postFeedback throw does not wedge feedbackFlushing');
    }, 400);
  });
}
