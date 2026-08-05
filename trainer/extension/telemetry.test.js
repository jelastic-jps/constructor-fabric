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
  }, 400);
});
