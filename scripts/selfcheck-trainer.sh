#!/bin/sh
# Static sanity checks for the Trainer — run from the repo root before a PR
# and from CI-less local development. Requires node and python3.
set -eu
cd "$(dirname "$0")/.."

fail=0

echo "== shell syntax =="
for s in scripts/*.sh docker-entrypoint.sh; do
  if bash -n "$s"; then echo "ok: $s"; else echo "FAIL: $s"; fail=1; fi
done

echo "== extension javascript =="
if command -v node >/dev/null 2>&1; then
  if node --check trainer/extension/extension.js; then echo "ok: extension.js"; else fail=1; fi
  if node --check trainer/ui/trainer.js; then echo "ok: trainer.js"; else fail=1; fi
else
  echo "skip: node not installed here (start-services.sh re-checks in-container)"
fi

echo "== trainer files =="
for f in trainer/extension/package.json trainer/extension/extension.js \
         trainer/ui/index.html trainer/ui/trainer.js trainer/ui/trainer.css \
         trainer/content/curriculum.json trainer/content/brief.md; do
  if [ -s "$f" ]; then echo "ok: $f"; else echo "FAIL: missing $f"; fail=1; fi
done

echo "== curriculum =="
python3 - <<'PYCURR' || fail=1
import json

data = json.load(open('trainer/content/curriculum.json'))
steps = data['steps']
assert len(steps) >= 12, f'expected >= 12 steps, got {len(steps)}'
assert data['app']['name'] and data['app']['port'], 'app name/port required'
ids = [s['id'] for s in steps]
assert len(ids) == len(set(ids)), 'duplicate step ids'
known_checks = {'file_exists', 'glob_nonempty', 'artifact_registered', 'cfs_validate',
                'cfs_coverage', 'markers_present', 'tests_pass', 'http_probe', 'git_committed'}
AGENTS = {'claude', 'codex', 'copilot'}
for s in steps:
    assert s.get('title') and 'sections' in s, f'step {s.get("id")} incomplete'
    for key in ('concept', 'actions', 'success', 'troubleshooting'):
        assert key in s['sections'], f'step {s["id"]} missing section {key}'
        v = s['sections'][key]
        # A section is a plain string, or an object keyed by coding agent
        # (resolved by the extension against ~/.cf-coding-agent at load time).
        if isinstance(v, dict):
            assert set(v) == AGENTS or 'default' in v, \
                f'step {s["id"]} section {key}: conditional must cover {sorted(AGENTS)} or provide default'
            assert all(isinstance(x, str) for x in v.values()), \
                f'step {s["id"]} section {key}: conditional values must be strings'
        else:
            assert isinstance(v, str), f'step {s["id"]} section {key}: must be string or agent-keyed object'
    for c in s.get('checks', []):
        assert c['type'] in known_checks, f'step {s["id"]}: unknown check type {c["type"]}'
        assert c.get('id') and c.get('label'), f'step {s["id"]}: check needs id+label'
    if s.get('gated'):
        assert s.get('checks'), f'gated step {s["id"]} has no checks'

# Telemetry is disclosed, not silent. Step 1 is the only place a trainee is told
# their progress is recorded, so the sentence must survive curriculum edits —
# losing it turns disclosed collection into silent collection.
welcome = steps[0]['sections']['concept']
assert isinstance(welcome, str), 'step 1 concept must be a plain string for the disclosure check'
assert 'records your progress' in welcome, 'step 1 is missing the telemetry disclosure sentence'
assert 'never records your prompts' in welcome, 'step 1 disclosure must state what is NOT recorded'
gated = [s['id'] for s in steps if s.get('gated')]
assert gated, 'no gated steps at all'
print(f'curriculum OK: {len(steps)} steps, gated: {", ".join(gated)}')
PYCURR

echo "== extension manifest =="
python3 - <<'PYPKG' || fail=1
import json
pkg = json.load(open('trainer/extension/package.json'))
assert pkg['main'] == './extension.js'
assert 'onStartupFinished' in pkg['activationEvents']
assert pkg['version'] == '2.0.0', 'keep in sync with start-services.sh and manifest.jps'
print('extension package.json OK:', pkg['version'])
PYPKG

echo "== legacy content must stay gone =="
for f in trainer/index.html trainer/main.js trainer/package.json scripts/run-trainer.sh; do
  if [ -e "$f" ]; then echo "FAIL: legacy file resurrected: $f"; fail=1; fi
done
# auto-bootstrap.sh may mention the old prompts file (it deletes it); this
# script mentions it here. Anything else is content duplication creeping back.
bad="$(grep -rln "CONSTRUCTOR_FABRIC_PROMPTS" scripts/ 2>/dev/null \
  | grep -v -e '^scripts/auto-bootstrap.sh$' -e '^scripts/selfcheck-trainer.sh$' || true)"
if [ -n "$bad" ]; then
  echo "FAIL: duplicated prompts content in: $bad"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "SELFCHECK FAILED"
  exit 1
fi
echo "SELFCHECK PASSED"
