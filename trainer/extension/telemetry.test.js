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
      }, 400);
    }, 400);
  });
}
