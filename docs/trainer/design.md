# Design: Greenfield Trainer Workflow (constructor-fabric try environment)

Status: v3 — ACTIVE (as-built; maintained as the Trainer evolves). Implements
requirements v3.1 (see requirements.md).
Repo: jelastic-jps/constructor-fabric only.
Resolved decisions: app port 5000 behind /proxy/5000/; delivery as a SINGLE PR;
restart archiving via baseline-diff; verification includes a full local Docker
bootstrap replay with URL + IDE password handed to the user for a personal
end-to-end walkthrough. Implementation-review decisions (registry-driven gates,
no `cfs validate` gates, `/cf` slash-command prompts, ungated-step
completion rule) are recorded in requirements.md and reflected below.

## 1. Component overview

```
trainer/                          ← single source of truth (FR-6), all new
├── extension/
│   ├── package.json              VS Code extension manifest (commands, activation)
│   └── extension.js              Backend: webview host, check runner, state store
├── ui/
│   ├── index.html                Webview shell
│   ├── trainer.js                Renderer: steps, progress, checks UI, msg protocol
│   └── trainer.css               Styles (self-contained, no external assets)
└── content/
    ├── curriculum.json           The 12 steps: texts, prompts, check definitions
    └── brief.md                  TaskLite product brief (rendered inside step 3)
```

Delivery change vs today: `start-services.sh` stops generating the extension from
heredocs and instead copies `trainer/extension/ + ui/ + content/` verbatim into
`~/.local/share/code-server/extensions/constructor-fabric.constructor-fabric-trainer-<ver>/`
(registration in `extensions.json` stays as-is). The webview loads UI and content
from the extension directory (`localResourceRoots` = extension dir), NOT from a copy
in the workspace — this removes the current 3-way fallback chain
(`.constructor-fabric-trainer/index.html` → `.trainer-welcome.html` → repo path) and
the workspace content copy entirely. The only Trainer file in the workspace is state:
`<workspace>/.constructor-fabric-trainer/state.json`.

## 2. Extension backend (`extension.js`)

Keeps today's proven activation pattern (command `constructorFabric.openTrainer`,
auto-open on startup with the 700/2000 ms re-open timers, `retainContextWhenHidden`).
New responsibilities:

**Message protocol** (webview `postMessage` ↔ backend):
- ui → ext: `ready` · `runChecks {stepId}` · `setStep {stepId}` (also marks the
  step being left as completed when it is ungated — FR-4.5 entered-then-exited
  rule) · `skipStep {stepId}` (records skip, FR-3.5) · `openExternal {url}`
  (app UI link via `vscode.env.asExternalUri`) ·
  `restartTraining {archive: bool}` (wrap-up only) · `resetProgress` (state only, p2)
- ext → ui: `init {curriculum, brief, state, env}` (env = workspace root, app
  name/port, resolved external app URL) · `checkResults {stepId, results[], state}` ·
  `stateChanged {state}` · `busy {stepId}` (checks running) · `restarted {state, …}`

**Check runner**: `child_process.execFile`, `cwd` = workspace root, `PATH` prefixed
with `~/studio/.venv/bin:~/.local/bin` (same as auto-bootstrap.sh). Per-check timeout
(default 60 s; test runs 300 s). All checks read-only on the workspace (FR-3.4).
`cfs` invoked with `--json` wherever available; raw findings passed to the UI verbatim
as the failure detail.

**State store**: atomic write (tmp file + rename) of
`.constructor-fabric-trainer/state.json`:

```json
{
  "schemaVersion": 1,
  "startedAt": "<iso>",
  "baseline": ["<relative paths present at training start>"],
  "artifactsTomlBaseline": "<content of .cf-studio/config/artifacts.toml at start>",
  "currentStep": "prd",
  "steps": { "<id>": { "status": "pending|passed|skipped",
                        "lastCheckAt": "<iso>",
                        "checks": { "<checkId>": { "ok": true, "summary": "..." } } } },
  "archives": [ { "at": "<iso>", "dir": "training-archive/<ts>" } ]
}
```

`baseline` is captured on first activation: a workspace file listing. Trainer-owned
dirs (state, archive) are skipped; heavy dirs (`.git`, `node_modules`, `.venv`,
`__pycache__`, `.pytest_cache`) are recorded as single opaque entries; `.cf-studio/`
is recorded opaquely EXCEPT its `artifacts/` subtree, which is walked — workflows
may register artifacts there, and those belong to the training run. The
`artifactsTomlBaseline` snapshot exists because workflows append artifact
registrations to the registry as they work; restart must restore it (§6). Baseline
drives restart archiving without hardcoding artifact paths.

## 3. Content model (`curriculum.json`)

```json
{
  "version": 1,
  "app": { "name": "TaskLite", "port": 5000 },
  "steps": [
    {
      "id": "prd",
      "title": "Write the PRD",
      "gated": true,
      "skippable": true,
      "sections": {
        "concept": "<markdown>",
        "actions": "<markdown>",
        "examplePrompt": "<plain text or null>",
        "success": "<markdown>",
        "troubleshooting": "<markdown>"
      },
      "checks": [
        { "id": "prd-registered", "type": "artifact_registered",
          "params": { "kind": "PRD" },
          "label": "A PRD artifact is registered and its file exists",
          "failHint": "<markdown>" }
      ]
    }
  ]
}
```

- Section bodies are a constrained markdown subset (headings, bold/code, lists,
  fenced blocks); rendered by a small renderer in `trainer.js` — no external
  libraries (NFR-5). Steps define a single `examplePrompt` or a `prompts` array
  (`[{label, text}, …]`); each renders in its own copyable box headed
  "Say this in the chat" (or the item's label; never injected; FR-2.1c).
- Prompts are chat slash commands; the renderer tints the leading `/command` token
  with the IDE's link color (`--vscode-textLink-foreground`), matching Copilot chat.
- Copying is plain-text only: the Copy button uses `clipboard.writeText`, and a
  `copy`-event handler on the prompt box strips the `text/html` clipboard flavor
  from manual selections — otherwise the chat input converts rich pastes into
  fenced code blocks.
- `gated: true` → "Next" enabled only when all checks pass or the trainee uses
  "Skip anyway" (recorded). Steps 1–3 and 12 are ungated and complete via the
  entered-then-exited rule (FR-4.5).
- UI conventions (top navigation since 2026-07-21; replaces the earlier sticky
  sidebar): a compact sticky top bar holds the CF brand and one numbered chip
  per step, colored by status (green passed / amber skipped / neutral pending,
  teal ring for active; locked steps dimmed and unclickable). Hovering a chip
  shows the step's `shortTitle` (a per-step field in curriculum.json) as a
  tooltip. The step header inside the content is a single line
  ("STEP N OF 12" kicker + title) and is itself sticky under the top bar, so
  step context stays visible while long content scrolls.

## 4. Check types (backend implementations)

| type | params | pass condition |
|---|---|---|
| `artifact_registered` | `kind`, `min?` | ≥min artifacts of `kind` in `.cf-studio/config/artifacts.toml` (systems walked recursively, incl. children) with files present on disk — registry-driven, no hardcoded paths; parsed via Python 3.11 `tomllib` from the Studio venv |
| `file_exists` | `path` \| `anyOf: [paths]` | file/dir exists (workspace-relative); available but unused by current curriculum |
| `glob_nonempty` | `dir`, `pattern` | ≥1 match; available but unused by current curriculum |
| `cfs_validate` | — | implemented but deliberately NOT used as a gate: `cfs validate` passes vacuously on an empty project (decided 2026-07-09) |
| `cfs_coverage` | `minCoverage` (default 100) | implemented but unused as a gate (traceability step ungated — decided 2026-07-09): `cfs spec-coverage --min-coverage N --json` exit 0 |
| `markers_present` | — | grep finds `cpt-…` traceability references in code (loosened 2026-07-13: bare IDs count, not only strict `@cpt-` syntax); all `*.md` files excluded (artifacts may live anywhere), plus architecture/, .cf-studio/ etc. |
| `tests_pass` | — | implemented but unused as a gate (decided 2026-07-09): `python -m pytest -q` exit 0; interpreter resolved most-specific-first: `<ws>/.venv/bin/python` → `<ws>/venv/bin/python` → `/usr/bin/python3` → PATH `python3` (agents often install deps into system Python; bare `python3` resolves to the Studio venv, which has no pytest). "No module named pytest" advances to the next candidate; real test failures stop and surface output |
| `http_probe` | `port`, `path?` | implemented but unused as a gate (run step ungated — decided 2026-07-09): GET `http://127.0.0.1:<port>/` responds < 500 |
| `git_committed` | — | implemented but unused (commit removed from wrap-up — decided 2026-07-09): `git rev-parse HEAD` succeeds ∧ clean tree |

## 5. Curriculum: steps, prompts, gates

Chat-first throughout (FR-2.2); step 2 is a chat smoke test ("hello" + sign-in);
all authoring via
the kit's `/cf` conversational router in slash-command form. Example prompts
follow GREENFIELD.md's "command + Context block" pattern; artifact placement is
left to Studio (gates accept any registered location, no layout nudges). The PRD
prompt embeds the brief as natural inline prose (no Context header/line breaks),
expanded at render time from `content/brief.md` via `{{BRIEF_INLINE}}` (single
source; a paragraph-preserving `{{BRIEF}}` variant also exists). Gate = backend
checks; the workflows' own validate/review loops do the validation teaching.

| # | id | Trainee does (chat unless noted) | Gate checks |
|---|----|----------------------------------|-------------|
| 1 | `welcome` | Read: what Studio is, pipeline map, validate→review→fix loop | none |
| 2 | `environment` | IDE tour (chat right, Explorer left); say "hello" in chat (GitHub sign-in if prompted); "Studio is preinstalled and preconfigured" | none |
| 3 | `brief` | Read the TaskLite brief (rendered from `brief.md`); artifacts-vs-chat concept | none |
| 4 | `prd` | `/cf make PRD for TaskLite. <brief inlined as prose>`, then `/cf validate PRD` (second prompt) | `artifact_registered(PRD)` |
| 5 | `design` | `/cf make DESIGN from PRD. Imply implementation in Python 3.11. <constraints as inline prose>` (single command, as small as possible), then `/cf validate DESIGN` | `artifact_registered(DESIGN)` |
| 6 | `adr` | `/cf make ADR for TaskLite task storage. Compare SQLite against a plain JSON file …` (inline prose), then `/cf validate ADR` | `artifact_registered(ADR)` |
| 7 | `decomposition` | `/cf make DECOMPOSITION. Aim for 2 to 3 small features …` (inline prose), then `/cf validate DECOMPOSITION` | `artifact_registered(DECOMPOSITION)` |
| 8 | `features` | `/cf make FEATURE for all features` (one run), then `/cf validate FEATURE for all features`; numbered behavior steps + `to_code` explained (CDSL not named — decided) | `artifact_registered(FEATURE)` |
| 9 | `implement` | `/cf implement all features` (bare command; per-feature internally), then `/cf validate code`; `@cpt-*` markers + checkbox cascade explained | `markers_present` (tests exercised by the workflow, not gated — decided) |
| 10 | `run` | Per README/GETTING_STARTED in a terminal, or ask the agent ("Run the app") | none (ungated — decided) |
| 11 | `traceability` | `/cf show the TaskLite traceability map` (bare command) | none (ungated — decided) |
| 12 | `wrapup` | Recap; Keep-learning first (`/cf-help` prompt + guide links); restart / own-idea invitation | none (no commit — removed, deferred to future advanced training) |

The Trainer provides no app link or port assumption (decided 2026-07-09): the run
step is ungated, and reaching the app is part of following the project's own docs.

## 6. Restart at wrap-up (FR-4.3)

1. Trainee clicks "Restart training" (wrap-up step only) → inline confirmation
   explaining exactly what will move where.
2. Backend computes `current files − baseline` (state's `baseline` list) and **moves**
   them to `training-archive/<UTC timestamp>/` preserving relative paths. Whole new
   top-level entries move as single renames; files added inside pre-existing dirs
   (including `.cf-studio/artifacts/`) move individually. Never deletes. Protected
   roots (`.cf-studio`, `.git`, the state dir, the archive dir) can never be moved
   wholesale, even against a pre-fix baseline.
3. The artifact registry is restored from the `artifactsTomlBaseline` snapshot (the
   workflow-modified copy is kept in the archive as `artifacts.toml`), so run two
   starts with a clean registry.
4. State reset to step 1; new `baseline` + registry snapshot captured; archive
   recorded in `state.archives`. FR-9 precondition (empty artifact tree + no app
   code) holds again.

## 7. Provisioning & cleanup changes (as built)

- **`scripts/start-services.sh`**: heredoc-generated extension replaced by a copy of
  repo `trainer/` into the extension dir, gated by hard file-presence checks,
  in-container `node --check` of `extension.js`, and a curriculum JSON sanity parse;
  workspace HTML copy and fallback page dropped (stale copies removed, `state.json`
  preserved); `extensions.json` registration and Copilot logic untouched.
  Agent-conditional user settings are merged here; for the **claude** path this
  now includes `"terminal.integrated.env.linux": {"BROWSER": null}`, which
  removes the VS Code browser shim from integrated terminals so the Claude Code
  CLI stays on its manual-code OAuth flow instead of the loopback popup that
  dead-ends in a web IDE (see requirements.md, decision 2026-08-06). The
  pre-existing `pop()` of that key stays and runs first — it purges the legacy
  API-key variant an older baked image may have written — so the claude value is
  written after it.
- **`scripts/bootstrap.sh`**: downloads the new 7-file trainer set (extension/ui/
  content) with baked-image fallback; places `scripts/auto-bootstrap.sh` at
  `~/studio/auto-bootstrap.sh` (download with baked-copy fallback) — the repo file
  is the single source; the embedded CFCAUTO heredoc is gone.
- **`scripts/auto-bootstrap.sh`** (canonical): no prompts-file generation (stale
  `CONSTRUCTOR_FABRIC_PROMPTS.md` actively deleted); README text updated;
  `"trainer": "code-server-webview"`; non-fatal greenfield warning when a fresh
  workspace already contains `architecture/`, `src/`, or `.cf-studio/artifacts/`;
  ends Studio deployment with `cfs update --with-kits yes --yes` in the workspace
  (refreshes runtime + installed kits to latest; non-fatal on network failure);
  agent generation targets all supported agents (`cfs generate-agents`), with the
  post-generation verification asserting the four agent families (windsurf,
  claude, copilot, openai). A copilot-only narrowing was tried and reverted.
- **`scripts/install-constructor-studio.sh`**: fallback Electron deck, run-trainer,
  desktop autostart, and embedded auto-bootstrap all removed. Studio's skill-engine
  cache is seeded via the SUPPORTED path — `cfs update --source "$STUDIO_DIR"
  --force` (Studio's own `make update` equivalent), which writes the full source
  tree plus the cache markers (`.version` `local:` form, `.provenance.json`,
  `version.toml`); the script tolerates the phase's expected non-zero exit on fresh
  installs and instead verifies the cache contents explicitly. (Root-caused during
  the walkthrough: hand-seeding only `skills/` left `.core/workflows/write-docs.md`
  missing, breaking every kit preset; the install audit vs. Studio source
  established `cfs update --source` as the intended mechanism.)
- **`Dockerfile`**: same supported cache seeding at build time (after the editable
  install, since `cfs` performs it); resolved release tag moved to
  `.studio-release-version` for setuptools-scm; build asserts cache completeness,
  provenance, and `.core/workflows/write-docs.md` in the baked workspace;
  `.trainer-welcome.html` copy removed. Studio stays on `latest`.
- **Legacy removal (p1, done)**: `trainer/main.js`, old `trainer/package.json`,
  `trainer/index.html`, `scripts/run-trainer.sh`, `scripts/open-agent.sh`
  (vestigial duplicate; the embedded copy's welcome text now points at the Trainer).
- **Legacy quarantine (p2, later)**: `configs/` (LXDE/Openbox), `patch-x11vnc.py`,
  `scripts/install-ides.sh` (dead run-trainer launcher + stale `--goto` already
  fixed), `scripts/run-cfc.sh`, `assets/landing.html`.
- **`manifest.jps`** (version 0.6.0): `verify` asserts all 7 trainer extension files,
  parseable `content/curriculum.json` with ≥12 steps, greenfield preconditions (no
  `architecture/`, no `src/`, no `.cf-studio/artifacts/`), and a complete Studio
  core runtime (`.cf-studio/.core/workflows/write-docs.md` exists); keeps `cfs info
  FOUND` / `cfs validate PASS`; new SCRIPT_VERSION for cache busting.
- **`scripts/selfcheck-trainer.sh`** (new): shell syntax, JS syntax (when node is
  available), trainer file presence, curriculum schema (step/check shape, known
  check types, gated-steps-have-checks), and legacy-content-stays-gone guards.

## 8. Verification plan (pre-PR)

- `bash -n` / shellcheck on modified scripts; `node --check` on `extension.js`;
  JSON parse + schema sanity of `curriculum.json` (CI-less repo → a tiny
  `scripts/selfcheck-trainer.sh` run manually and from manifest verify).
- Local smoke of the check runner against a fixture workspace (checks pass/fail as
  expected without a real deploy).
- **Local Docker end-to-end replay (required before PR review)**: build the image
  from the repo `Dockerfile`, start a container that replays the full JPS bootstrap
  path (`bootstrap.sh` → `install-constructor-studio.sh` → `start-services.sh` →
  `auto-bootstrap.sh`) with the same env the manifest would inject (since
  2026-07-22: the environment password and the AI coding agent choice — no
  LLM provider/model/API key),
  expose port 8080 locally, then hand the user the access URL and the IDE
  password so they can personally walk through the entire Trainer curriculum
  end-to-end. Friction found in that walkthrough is fixed before the PR is opened.
- The user's Docker walkthrough doubles as the pilot run: record wall-clock/token
  spend, encode as "takes ~N minutes" text (NFR-6).

## 9. Delivery plan (single PR, cross-reviewed, never self-merged)

One PR (decided) containing: legacy retirement + content dedup (FR-7 p1 removals,
§7 script cleanups), the new `trainer/` (extension, ui, content incl. brief.md),
`start-services.sh` wiring, manifest verify extension + version bump. The p2
VNC-era quarantine (configs/, patch-x11vnc.py, install-ides.sh, landing.html) may
ride along or follow later at implementation-review discretion.

PR process: show the diff before pushing, report lines added/removed + files
changed, commit trailer "Done with the help of: Claude Fable 5"; check whether DCO
sign-off applies to the jelastic-jps org before first commit. PR opens only after
the user's Docker walkthrough (§8) passes.

## Appendix A — TaskLite product brief

Canonical text lives at `trainer/content/brief.md` (single source of truth; rendered
inside curriculum step 3). In short: an API-first team task service — create (title
+ optional description), list grouped by To Do/Done, complete, delete, all through
the public API; persistence across restarts; self-contained (no external services);
no accounts/login/notifications; a web UI is explicitly out of scope for v1
(decided 2026-07-09, superseding "app with UI"). The brief is product-only; the
environment expectations (port 5000, relative URLs) surface at the run step.
Scope note in the DECOMPOSITION prompt: "aim for 2–3 small features."

## Appendix B — Open design decisions

None currently. Baseline decisions: D-1 port 5000/proxy, D-2 single PR, D-3
baseline-diff archiving. Implementation-review decisions (2026-07-09) are listed in
requirements.md "Resolved decisions" and incorporated throughout this document.
This is a living document — keep it in sync with Trainer changes.
