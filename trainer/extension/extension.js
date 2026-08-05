// Constructor Fabric Trainer — extension backend.
// Hosts the trainer webview, runs deterministic step checks against the
// workspace (read-only), and persists training progress. The curriculum and
// UI live next to this file in the extension directory; the only file the
// trainer ever writes inside the workspace is its own state under
// .constructor-fabric-trainer/ (plus archive moves on an explicit restart).
const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const http = require('http');
const { execFile } = require('child_process');

// A missing or broken emitter must never stop the Trainer loading. The image
// ships a baked copy and bootstrap.sh refreshes it, but an older image whose
// refresh failed would otherwise throw here and take the whole extension down —
// which is exactly the failure mode telemetry is forbidden from causing.
let telemetry;
try {
  telemetry = require('./telemetry');
} catch (e) {
  telemetry = {
    init() {}, emit() {}, dispose() {}, setVersion() {},
    submitFeedback() {}, isActive() { return false; }
  };
}

const STATE_DIRNAME = '.constructor-fabric-trainer';
const STATE_FILENAME = 'state.json';
const ARCHIVE_DIRNAME = 'training-archive';
const STATE_SCHEMA_VERSION = 1;
// Never walked at all (trainer-owned or archive).
const WALK_SKIP = new Set([STATE_DIRNAME, ARCHIVE_DIRNAME]);
// Recorded as a single opaque entry ("name/") without recursing inside, so
// baseline capture stays fast and an app-created .venv still archives as one
// rename on restart.
const WALK_OPAQUE = new Set(['.git', 'node_modules', '__pycache__', '.venv', '.pytest_cache']);
// .cf-studio is Studio-owned and must never be archived wholesale, but its
// artifacts/ subtree is where workflows may place artifacts — those belong to
// the training run and must be tracked (and archived on restart).
const STUDIO_DIRNAME = '.cf-studio';
const STUDIO_WALK_CHILDREN = ['artifacts'];
const ARTIFACTS_TOML_REL = STUDIO_DIRNAME + '/config/artifacts.toml';
// Top-level entries that may never be moved wholesale on restart, even when
// an older baseline does not list them.
const PROTECTED_TOP = new Set([STUDIO_DIRNAME, STATE_DIRNAME, ARCHIVE_DIRNAME, '.git']);
const MAX_DETAIL_CHARS = 4000;

let panel;
let checksRunning = false;

function workspaceRoot() {
  const folders = vscode.workspace.workspaceFolders;
  if (folders && folders.length) return folders[0].uri.fsPath;
  return '/home/developer/workspaces/constructor-fabric-workspace';
}

function toolEnv() {
  const home = process.env.HOME || '/home/developer';
  const prefix = [
    path.join(home, 'studio', '.venv', 'bin'),
    path.join(home, '.local', 'bin'),
    '/usr/local/bin',
    '/opt/node-current/bin'
  ].join(':');
  return Object.assign({}, process.env, { PATH: prefix + ':' + (process.env.PATH || '') });
}

function run(cmd, args, opts) {
  const options = Object.assign(
    { cwd: workspaceRoot(), env: toolEnv(), timeout: 60000, maxBuffer: 8 * 1024 * 1024 },
    opts || {}
  );
  return new Promise((resolve) => {
    execFile(cmd, args, options, (error, stdout, stderr) => {
      resolve({
        code: error ? (typeof error.code === 'number' ? error.code : 1) : 0,
        error: error && typeof error.code !== 'number' ? String(error.message || error) : null,
        stdout: String(stdout || ''),
        stderr: String(stderr || '')
      });
    });
  });
}

function truncate(text) {
  const s = String(text || '').trim();
  if (s.length <= MAX_DETAIL_CHARS) return s;
  return s.slice(0, MAX_DETAIL_CHARS) + '\n… (output truncated)';
}

// Extract the first JSON object from mixed CLI output.
function parseJsonLoose(text) {
  const s = String(text || '');
  const start = s.indexOf('{');
  if (start === -1) return null;
  try {
    return JSON.parse(s.slice(start));
  } catch (e) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Workspace listing (baseline capture + restart archiving)

function listWorkspaceEntries(root) {
  const entries = [];
  const stack = [''];
  let guard = 0;
  while (stack.length) {
    if (++guard > 50000) break; // runaway safety; workspaces here are small
    const rel = stack.pop();
    const abs = rel ? path.join(root, rel) : root;
    let names;
    try {
      names = fs.readdirSync(abs, { withFileTypes: true });
    } catch (e) {
      continue;
    }
    for (const d of names) {
      const childRel = rel ? rel + '/' + d.name : d.name;
      if (d.isSymbolicLink()) {
        entries.push(childRel);
        continue;
      }
      if (d.isDirectory()) {
        if (WALK_SKIP.has(d.name)) continue;
        if (childRel === STUDIO_DIRNAME) {
          entries.push(childRel + '/');
          for (const sub of STUDIO_WALK_CHILDREN) {
            if (fs.existsSync(path.join(abs, d.name, sub))) stack.push(childRel + '/' + sub);
          }
          continue;
        }
        if (WALK_OPAQUE.has(d.name)) {
          entries.push(childRel + '/');
          continue;
        }
        stack.push(childRel);
      } else {
        entries.push(childRel);
      }
    }
  }
  return entries;
}

// ---------------------------------------------------------------------------
// State

function statePath() {
  return path.join(workspaceRoot(), STATE_DIRNAME, STATE_FILENAME);
}

function readArtifactsToml() {
  try {
    return fs.readFileSync(path.join(workspaceRoot(), ARTIFACTS_TOML_REL), 'utf8');
  } catch (e) {
    return null;
  }
}

function defaultState(curriculum) {
  return {
    schemaVersion: STATE_SCHEMA_VERSION,
    startedAt: new Date().toISOString(),
    baseline: listWorkspaceEntries(workspaceRoot()),
    // Registry snapshot: workflows register artifacts in artifacts.toml as
    // they create them; restart must restore the pre-training registry or a
    // second run starts with registrations pointing at archived files.
    artifactsTomlBaseline: readArtifactsToml(),
    currentStep: curriculum.steps.length ? curriculum.steps[0].id : null,
    steps: {},
    archives: []
  };
}

function loadState(curriculum) {
  const p = statePath();
  try {
    const data = JSON.parse(fs.readFileSync(p, 'utf8'));
    if (data && data.schemaVersion === STATE_SCHEMA_VERSION && Array.isArray(data.baseline)) {
      return data;
    }
    fs.renameSync(p, p + '.unsupported-' + Date.now());
  } catch (e) {
    // missing or unreadable → re-initialize below
  }
  const fresh = defaultState(curriculum);
  saveState(fresh);
  return fresh;
}

function saveState(state) {
  const p = statePath();
  fs.mkdirSync(path.dirname(p), { recursive: true });
  const tmp = p + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2) + '\n');
  fs.renameSync(tmp, p);
}

// ---------------------------------------------------------------------------
// Checks

async function checkFileExists(params) {
  const candidates = params.anyOf || [params.path];
  for (const rel of candidates) {
    if (rel && fs.existsSync(path.join(workspaceRoot(), rel))) {
      return { ok: true, summary: rel + ' found' };
    }
  }
  return { ok: false, summary: candidates.join(' / ') + ' not found' };
}

async function checkGlobNonempty(params) {
  const dir = path.join(workspaceRoot(), params.dir);
  let re;
  try {
    re = new RegExp(params.pattern || '.');
  } catch (e) {
    re = /./;
  }
  let names = [];
  try {
    names = fs.readdirSync(dir).filter((n) => re.test(n));
  } catch (e) {
    return { ok: false, summary: params.dir + '/ does not exist yet' };
  }
  if (!names.length) return { ok: false, summary: 'no matching files in ' + params.dir + '/' };
  return { ok: true, summary: names.length + ' file(s): ' + names.slice(0, 5).join(', ') };
}

// Registry-driven artifact check: Studio's source of truth for artifact
// locations is .cf-studio/config/artifacts.toml (paths may be anywhere in the
// project). Parsed with tomllib from the Studio venv's Python 3.11, which
// toolEnv() puts first on PATH.
const ARTIFACT_QUERY_PY = [
  'import json, sys, tomllib',
  'from pathlib import Path',
  'kind, root = sys.argv[1], Path(sys.argv[2])',
  'reg = root / sys.argv[3]',
  'found = []',
  'def walk(systems):',
  '    for s in systems or []:',
  '        if not isinstance(s, dict): continue',
  '        for a in s.get("artifacts") or []:',
  '            if isinstance(a, dict) and a.get("kind") == kind:',
  '                p = str(a.get("path") or "")',
  '                found.append({"path": p, "exists": bool(p) and (root / p).exists()})',
  '        ch = s.get("children")',
  '        if isinstance(ch, list) and ch and isinstance(ch[0], dict): walk(ch)',
  'if reg.exists():',
  '    try:',
  '        walk(tomllib.loads(reg.read_text()).get("systems"))',
  '    except tomllib.TOMLDecodeError as e:',
  '        print(json.dumps({"invalid_registry": str(e)}))',
  '        raise SystemExit(0)',
  'print(json.dumps(found))'
].join('\n');

async function checkArtifactRegistered(params) {
  const kind = params.kind;
  const min = params.min == null ? 1 : params.min;
  const res = await run('python3', ['-c', ARTIFACT_QUERY_PY, kind, workspaceRoot(), ARTIFACTS_TOML_REL]);
  if (res.code !== 0) {
    return { ok: false, summary: 'could not read the artifact registry', detail: truncate(res.stderr || res.stdout) };
  }
  const parsedLoose = parseJsonLoose(res.stdout);
  if (parsedLoose && parsedLoose.invalid_registry) {
    // Workflows occasionally write the registry as JSON-style TOML (multi-line
    // inline tables), which neither strict TOML nor Studio itself accepts.
    return {
      ok: false,
      summary: 'the artifact registry (' + ARTIFACTS_TOML_REL + ') is not valid TOML',
      detail: truncate(
        parsedLoose.invalid_registry +
        '\n\nRecovery: tell the agent — "The artifact registry .cf-studio/config/artifacts.toml ' +
        'is not valid TOML. Rewrite it with valid TOML syntax (single-line inline tables, ' +
        'no trailing commas), keeping all registered entries."'
      )
    };
  }
  let found;
  try {
    found = JSON.parse(res.stdout);
  } catch (e) {
    return { ok: false, summary: 'could not parse the artifact registry query', detail: truncate(res.stdout) };
  }
  const present = found.filter((f) => f.exists);
  const missing = found.filter((f) => !f.exists);
  if (present.length >= min) {
    return { ok: true, summary: kind + ' registered: ' + present.map((f) => f.path).slice(0, 5).join(', ') };
  }
  if (missing.length) {
    return {
      ok: false,
      summary: kind + ' registered but file missing: ' + missing.map((f) => f.path).join(', ')
    };
  }
  return { ok: false, summary: 'no ' + kind + ' artifact registered in ' + ARTIFACTS_TOML_REL };
}

async function checkCfsValidate() {
  const res = await run('cfs', ['validate', '--json'], { timeout: 120000 });
  if (res.error) return { ok: false, summary: 'could not run cfs validate', detail: truncate(res.error) };
  const parsed = parseJsonLoose(res.stdout);
  if (parsed && parsed.status) {
    const ok = parsed.status === 'PASS';
    return {
      ok,
      summary: 'cfs validate: ' + parsed.status,
      detail: ok ? '' : truncate(JSON.stringify(parsed, null, 2))
    };
  }
  return {
    ok: res.code === 0,
    summary: 'cfs validate exited with code ' + res.code,
    detail: res.code === 0 ? '' : truncate(res.stdout + '\n' + res.stderr)
  };
}

async function checkCfsCoverage(params) {
  const min = params.minCoverage == null ? 100 : params.minCoverage;
  let res = await run('cfs', ['spec-coverage', '--min-coverage', String(min), '--json'], { timeout: 120000 });
  if (res.code !== 0 && /unrecognized|no such option|--json/i.test(res.stderr)) {
    res = await run('cfs', ['spec-coverage', '--min-coverage', String(min)], { timeout: 120000 });
  }
  if (res.error) return { ok: false, summary: 'could not run cfs spec-coverage', detail: truncate(res.error) };
  const parsed = parseJsonLoose(res.stdout);
  const pct = parsed && parsed.summary && parsed.summary.coverage_pct != null ? parsed.summary.coverage_pct : null;
  const ok = res.code === 0;
  return {
    ok,
    summary: pct != null ? 'coverage: ' + pct + '% (required: ' + min + '%)' : 'spec-coverage exited with code ' + res.code,
    detail: ok ? '' : truncate(parsed ? JSON.stringify(parsed, null, 2) : res.stdout + '\n' + res.stderr)
  };
}

async function checkMarkersPresent() {
  // Traceability references must exist in code, not (only) in the artifact
  // documents — those are markdown and may live anywhere (docs/,
  // architecture/, …), so all .md files are excluded outright. Loosened
  // (decided 2026-07-13): bare `cpt-…` ID references count, not only strict
  // `@cpt-` marker syntax — agents vary in how faithfully they emit markers.
  const res = await run('grep', [
    '-rl', '--binary-files=without-match', '--exclude=*.md',
    '--exclude-dir=.git', '--exclude-dir=.cf-studio', '--exclude-dir=' + STATE_DIRNAME,
    '--exclude-dir=' + ARCHIVE_DIRNAME, '--exclude-dir=architecture', '--exclude-dir=node_modules',
    '--exclude-dir=.venv', '--exclude-dir=__pycache__',
    '-E', '-e', '\\bcpt-[a-z0-9]', '.'
  ]);
  if (res.code === 0 && res.stdout.trim()) {
    const files = res.stdout.trim().split('\n');
    return { ok: true, summary: 'CPT traceability references in ' + files.length + ' file(s)' };
  }
  return { ok: false, summary: 'no CPT references (cpt-…) found in source files' };
}

async function checkTestsPass() {
  const root = workspaceRoot();
  // Interpreter candidates, most specific first. A bare "python3" resolves to
  // the Studio venv via toolEnv()'s PATH (which has no pytest), so the system
  // interpreter — where agents typically pip-install project deps when they
  // create no venv — must be tried explicitly before the PATH fallback.
  const candidates = [
    path.join(root, '.venv', 'bin', 'python'),
    path.join(root, 'venv', 'bin', 'python'),
    '/usr/bin/python3',
    'python3'
  ].filter((py) => !py.startsWith('/') || fs.existsSync(py));
  let last = null;
  for (const py of candidates) {
    const res = await run(py, ['-m', 'pytest', '-q'], { timeout: 300000 });
    last = res;
    if (res.code === 0) {
      return {
        ok: true,
        summary: 'pytest passed (' + py + ')',
        detail: truncate(res.stdout.split('\n').slice(-3).join('\n'))
      };
    }
    // Interpreter has no pytest → try the next candidate; real test failures stop here.
    if (!/No module named pytest/i.test(res.stdout + res.stderr)) break;
  }
  const noPytest = last && /No module named pytest/i.test(last.stdout + last.stderr);
  return {
    ok: false,
    summary: noPytest ? 'pytest is not installed for any project interpreter' : 'pytest failed',
    detail: truncate(last ? last.stdout + '\n' + last.stderr : '')
  };
}

function checkHttpProbe(params) {
  const port = params.port || 5000;
  return new Promise((resolve) => {
    const req = http.get({ host: '127.0.0.1', port, path: params.path || '/', timeout: 5000 }, (res) => {
      res.resume();
      resolve({
        ok: res.statusCode < 500,
        summary: 'HTTP ' + res.statusCode + ' from 127.0.0.1:' + port
      });
    });
    req.on('timeout', () => {
      req.destroy();
      resolve({ ok: false, summary: 'timeout connecting to 127.0.0.1:' + port });
    });
    req.on('error', (e) => resolve({ ok: false, summary: 'nothing listening on 127.0.0.1:' + port + ' (' + e.code + ')' }));
  });
}

async function checkGitCommitted() {
  const head = await run('git', ['rev-parse', '--short', 'HEAD']);
  if (head.code !== 0) return { ok: false, summary: 'no git commit yet' };
  const status = await run('git', ['status', '--porcelain']);
  if (status.code === 0 && !status.stdout.trim()) {
    return { ok: true, summary: 'committed (' + head.stdout.trim() + '), working tree clean' };
  }
  return { ok: false, summary: 'commit ' + head.stdout.trim() + ' exists but there are uncommitted changes' };
}

const CHECKERS = {
  file_exists: checkFileExists,
  glob_nonempty: checkGlobNonempty,
  artifact_registered: checkArtifactRegistered,
  cfs_validate: checkCfsValidate,
  cfs_coverage: checkCfsCoverage,
  markers_present: checkMarkersPresent,
  tests_pass: checkTestsPass,
  http_probe: checkHttpProbe,
  git_committed: checkGitCommitted
};

// 1-based position in the curriculum. The collector rejects an out-of-range
// index, so an unknown step yields undefined and the prop is simply omitted.
function stepIndex(curriculum, stepId) {
  const i = curriculum.steps.findIndex((s) => s.id === stepId);
  return i < 0 ? undefined : i + 1;
}

async function runStepChecks(curriculum, state, stepId) {
  const step = curriculum.steps.find((s) => s.id === stepId);
  if (!step) return [];
  const results = [];
  for (const check of step.checks || []) {
    const impl = CHECKERS[check.type];
    let result;
    try {
      result = impl
        ? await impl(check.params || {})
        : { ok: false, summary: 'unknown check type: ' + check.type };
    } catch (e) {
      result = { ok: false, summary: 'check crashed', detail: truncate(String(e && e.stack ? e.stack : e)) };
    }
    results.push(Object.assign({ id: check.id, label: check.label, failHint: check.failHint }, result));
  }
  const stepState = state.steps[stepId] || {};
  const statusBefore = stepState.status;
  stepState.lastCheckAt = new Date().toISOString();
  stepState.checks = {};
  for (const r of results) stepState.checks[r.id] = { ok: r.ok, summary: r.summary };
  const allOk = results.every((r) => r.ok);
  if (step.gated) {
    if (allOk) stepState.status = 'passed';
    else if (stepState.status !== 'skipped') stepState.status = 'pending';
  } else {
    stepState.status = 'passed';
  }
  state.steps[stepId] = stepState;
  saveState(state);

  // check_id and the ok boolean ONLY. `summary` can contain cfs validate
  // output — arbitrary text derived from the trainee's own artifacts — and
  // must never leave the container.
  for (const r of results) {
    telemetry.emit('step_check_run', { step_id: stepId, check_id: r.id, ok: !!r.ok });
  }

  // Completion is the final step first reaching 'passed'. Guarded on the prior
  // status because an ungated step is re-marked 'passed' every time its checks
  // run, which would otherwise emit on every click.
  const lastStep = curriculum.steps[curriculum.steps.length - 1];
  if (lastStep && lastStep.id === stepId && statusBefore !== 'passed' && stepState.status === 'passed') {
    telemetry.emit('training_completed', {});
  }

  return results;
}

// ---------------------------------------------------------------------------
// Restart training (wrap-up): archive everything created since baseline.

function restartTraining(curriculum, state) {
  const root = workspaceRoot();
  const baseline = new Set(state.baseline);
  const baselineTop = new Set(state.baseline.map((e) => e.split('/')[0]));
  const current = listWorkspaceEntries(root);
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const archiveRel = ARCHIVE_DIRNAME + '/' + stamp;
  const archiveAbs = path.join(root, archiveRel);

  const topMoves = new Set();
  const fileMoves = [];
  for (const entry of current) {
    if (baseline.has(entry)) continue;
    const top = entry.split('/')[0];
    if (PROTECTED_TOP.has(top)) {
      // Never move a protected root wholesale (even if an older baseline
      // predates it); archive only the tracked files inside it.
      if (entry !== top + '/' && entry !== top) fileMoves.push(entry);
    } else if (!baselineTop.has(top)) {
      topMoves.add(top);
    } else {
      fileMoves.push(entry);
    }
  }

  let moved = 0;
  const moveOne = (rel) => {
    const src = path.join(root, rel.replace(/\/$/, ''));
    const dst = path.join(archiveAbs, rel.replace(/\/$/, ''));
    if (!fs.existsSync(src)) return;
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.renameSync(src, dst);
    moved++;
  };
  if (topMoves.size || fileMoves.length) {
    fs.mkdirSync(archiveAbs, { recursive: true });
    for (const top of topMoves) moveOne(top);
    for (const rel of fileMoves) moveOne(rel);
  }

  // Restore the pre-training artifact registry (workflows appended their
  // artifact registrations to it); keep the modified copy in the archive.
  if (typeof state.artifactsTomlBaseline === 'string') {
    const regAbs = path.join(root, ARTIFACTS_TOML_REL);
    const regNow = readArtifactsToml();
    if (regNow !== null && regNow !== state.artifactsTomlBaseline) {
      fs.mkdirSync(archiveAbs, { recursive: true });
      fs.writeFileSync(path.join(archiveAbs, 'artifacts.toml'), regNow);
      fs.writeFileSync(regAbs, state.artifactsTomlBaseline);
      moved++;
    }
  }

  const fresh = defaultState(curriculum);
  fresh.archives = (state.archives || []).concat(
    moved ? [{ at: new Date().toISOString(), dir: archiveRel, moved }] : []
  );
  saveState(fresh);
  return { state: fresh, moved, archiveDir: moved ? archiveRel : null };
}

// ---------------------------------------------------------------------------
// Webview

// The AI coding agent deployed into this environment (claude | codex |
// copilot), chosen on the install form and written to ~/.cf-coding-agent by
// the JPS manifest. Same fallback as the deploy scripts: missing or invalid
// file means the built-in Copilot was kept.
const CODING_AGENTS = ['claude', 'codex', 'copilot'];
function deployedAgent() {
  try {
    const raw = fs.readFileSync(path.join(process.env.HOME || '/home/developer', '.cf-coding-agent'), 'utf8').trim();
    return CODING_AGENTS.includes(raw) ? raw : 'copilot';
  } catch (e) {
    return 'copilot';
  }
}

// A curriculum section value is either a plain string or an object keyed by
// agent ({claude: ..., codex: ..., copilot: ...}) resolved at load time, so
// the webview only ever sees plain strings.
function resolveSectionsForAgent(curriculum, agent) {
  for (const step of curriculum.steps || []) {
    const sections = step.sections || {};
    for (const key of Object.keys(sections)) {
      const value = sections[key];
      if (value && typeof value === 'object' && !Array.isArray(value)) {
        sections[key] = value[agent] !== undefined ? value[agent] : value.default;
      }
    }
  }
  return curriculum;
}

function loadCurriculum(context) {
  const raw = fs.readFileSync(path.join(context.extensionPath, 'content', 'curriculum.json'), 'utf8');
  return resolveSectionsForAgent(JSON.parse(raw), deployedAgent());
}

function loadBrief(context) {
  try {
    return fs.readFileSync(path.join(context.extensionPath, 'content', 'brief.md'), 'utf8');
  } catch (e) {
    return '';
  }
}

function webviewHtml(context, webview) {
  const uiRoot = vscode.Uri.file(path.join(context.extensionPath, 'ui'));
  let html = fs.readFileSync(path.join(context.extensionPath, 'ui', 'index.html'), 'utf8');
  return html
    .replace(/%%CSP%%/g, webview.cspSource)
    .replace(/%%BASE%%/g, webview.asWebviewUri(uiRoot).toString());
}

async function handleMessage(context, msg) {
  const curriculum = loadCurriculum(context);
  const state = loadState(curriculum);
  const post = (m) => { if (panel) panel.webview.postMessage(m); };

  switch (msg.type) {
    case 'ready': {
      post({
        type: 'init',
        curriculum,
        brief: loadBrief(context),
        state,
        env: {
          workspaceRoot: workspaceRoot(),
          appName: curriculum.app.name,
          // Drives whether the Feedback button is offered at all. An
          // environment deployed from an unsubstituted JPS has no telemetry
          // config, and inviting someone to write 20 000 characters into a
          // void is worse than offering nothing (feedback design §4.5).
          feedbackEnabled: telemetry.isActive()
        }
      });
      telemetry.emit('trainer_opened', {});

      // The FIRST step also completes on entry, and for two reasons.
      //
      // As a metric: it is the "someone signed in and actually opened the
      // Trainer" meter, which is the first thing the funnel should measure.
      //
      // As a correctness fix: step_entered is emitted only from setStep, and
      // the funnel is built exclusively from step_entered. Opening the Trainer
      // shows step 1 without any setStep, so a trainee who read the welcome and
      // clicked to step 2 registered on step 2 but never on step 1 — leaving
      // the first curriculum row reading LOWER than the second.
      const first = curriculum.steps[0];
      if (first && state.currentStep === first.id) {
        const firstState = state.steps[first.id] || {};
        if (firstState.status !== 'passed' && firstState.status !== 'skipped') {
          firstState.status = 'passed';
          firstState.completedAt = new Date().toISOString();
          state.steps[first.id] = firstState;
          saveState(state);
          post({ type: 'stateChanged', state });
          telemetry.emit('step_entered', { step_id: first.id, step_index: 1 });
          telemetry.emit('step_completed', { step_id: first.id, step_index: 1 });
        }
      }
      break;
    }
    case 'setStep': {
      if (curriculum.steps.some((s) => s.id === msg.stepId)) {
        // An ungated step (no gate to pass) counts as completed once the
        // trainee has entered it and navigated away.
        const prev = curriculum.steps.find((s) => s.id === state.currentStep);
        if (prev && prev.id !== msg.stepId && !prev.gated) {
          const prevState = state.steps[prev.id] || {};
          if (prevState.status !== 'passed' && prevState.status !== 'skipped') {
            prevState.status = 'passed';
            prevState.completedAt = new Date().toISOString();
            state.steps[prev.id] = prevState;
            telemetry.emit('step_completed', { step_id: prev.id, step_index: stepIndex(curriculum, prev.id) });
          }
        }
        state.currentStep = msg.stepId;

        // The final step is the exception to the rule above: there is nowhere
        // to navigate away to, so it completes on ENTRY. Otherwise the training
        // could only ever register as finished by running that step's checks,
        // and a trainee who reaches the end and stops would never count as
        // having completed it.
        const last = curriculum.steps[curriculum.steps.length - 1];
        const enteringLast = !!last && last.id === msg.stepId;
        const lastState = enteringLast ? (state.steps[msg.stepId] || {}) : null;
        const finishesNow =
          enteringLast && lastState.status !== 'passed' && lastState.status !== 'skipped';
        if (finishesNow) {
          lastState.status = 'passed';
          lastState.completedAt = new Date().toISOString();
          state.steps[msg.stepId] = lastState;
        }

        saveState(state);
        post({ type: 'stateChanged', state });
        telemetry.emit('step_entered', { step_id: msg.stepId, step_index: stepIndex(curriculum, msg.stepId) });
        if (finishesNow) {
          telemetry.emit('step_completed', { step_id: msg.stepId, step_index: stepIndex(curriculum, msg.stepId) });
          telemetry.emit('training_completed', {});
        }
      }
      break;
    }
    case 'runChecks': {
      if (checksRunning) break;
      checksRunning = true;
      post({ type: 'busy', stepId: msg.stepId });
      try {
        const results = await runStepChecks(curriculum, state, msg.stepId);
        post({ type: 'checkResults', stepId: msg.stepId, results, state });
      } finally {
        checksRunning = false;
      }
      break;
    }
    case 'skipStep': {
      const stepState = state.steps[msg.stepId] || {};
      stepState.status = 'skipped';
      stepState.skippedAt = new Date().toISOString();
      state.steps[msg.stepId] = stepState;
      saveState(state);
      post({ type: 'stateChanged', state });
      telemetry.emit('step_skipped', { step_id: msg.stepId, step_index: stepIndex(curriculum, msg.stepId) });
      break;
    }
    case 'submitFeedback': {
      // Wrapped like every other telemetry call: no telemetry failure may
      // throw into the message loop and take the Trainer down with it
      // (telemetry spec §11.4). The webview has already shown its
      // acknowledgement and expects no reply.
      try {
        telemetry.submitFeedback({
          text: msg.text,
          noContact: Boolean(msg.noContact),
          stepId: msg.stepId
        });
      } catch (e) {
        // Deliberately swallowed; submitFeedback reports its own failures.
      }
      break;
    }
    case 'openExternal': {
      try {
        await vscode.env.openExternal(vscode.Uri.parse(msg.url));
      } catch (e) {
        vscode.window.showErrorMessage('Could not open: ' + msg.url);
      }
      break;
    }
    case 'restartTraining': {
      try {
        const result = restartTraining(curriculum, state);
        post({ type: 'restarted', state: result.state, moved: result.moved, archiveDir: result.archiveDir });
        // The spool lives under STATE_DIRNAME, which is in PROTECTED_TOP, so a
        // restart never archives it — pending events survive and still ship.
        telemetry.emit('training_restarted', {});
        vscode.window.showInformationMessage(
          result.moved
            ? 'Training restarted. ' + result.moved + ' item(s) archived to ' + result.archiveDir + '.'
            : 'Training restarted. Nothing needed archiving.'
        );
      } catch (e) {
        vscode.window.showErrorMessage('Restart failed: ' + String(e && e.message ? e.message : e));
        post({ type: 'stateChanged', state: loadState(curriculum) });
      }
      break;
    }
    default:
      break;
  }
}

function openTrainer(context) {
  if (panel) {
    panel.reveal(vscode.ViewColumn.One);
    return;
  }
  panel = vscode.window.createWebviewPanel(
    'constructorFabricTrainer',
    'Constructor Fabric Trainer',
    vscode.ViewColumn.One,
    {
      enableScripts: true,
      retainContextWhenHidden: true,
      localResourceRoots: [vscode.Uri.file(context.extensionPath)]
    }
  );
  panel.onDidDispose(() => { panel = undefined; }, null, context.subscriptions);
  panel.webview.onDidReceiveMessage(
    (msg) => { handleMessage(context, msg).catch((e) => console.error('trainer message failed', e)); },
    null,
    context.subscriptions
  );
  panel.webview.html = webviewHtml(context, panel.webview);
}

function activate(context) {
  // Dormant unless manifest.jps planted its config; never throws either way.
  try {
    telemetry.setVersion(require('./package.json').version);
    telemetry.init(path.join(workspaceRoot(), STATE_DIRNAME));
  } catch (e) {
    // Telemetry must never affect activation.
  }

  context.subscriptions.push(
    vscode.commands.registerCommand('constructorFabric.openTrainer', () => openTrainer(context))
  );
  openTrainer(context);
  // code-server restores the editor layout asynchronously on startup; retry so
  // the trainer reliably surfaces as the visible tab.
  setTimeout(() => openTrainer(context), 700);
  setTimeout(() => openTrainer(context), 2000);
}

function deactivate() { telemetry.dispose(); }
module.exports = { activate, deactivate };
