# Requirements: Greenfield Trainer Workflow for the Constructor Fabric Try Environment

Status: v3.1 — ACTIVE (baseline approved 2026-07-09; maintained as the Trainer evolves). Target repo: jelastic-jps/constructor-fabric only.
Ground-truth repos (read-only): constructorfabric/studio, constructorfabric/studio-kit-sdlc.

Resolved decisions (v1 review):
- Delivery: interactive code-server webview; prompts are suggestions the trainee types in
  their own words or copy-pastes — never injected into chat.
- Fixed reference app with UI; own-idea path is a post-training suggestion only.
- Full path: artifacts → CPT traceability → generated code → passing tests → running app.
- "Almost greenfield": Studio pre-deployed/pre-configured; everything else is guided.
- Implementation lives in jelastic-jps/constructor-fabric only.
- Chat-first: trainee-facing instructions use `cf-*` skills wherever possible; terminal
  only where no skill equivalent exists.
- App stack: Python/Flask + pytest + vanilla HTML/JS. UI exposure via code-server
  /proxy/<port>/. Coverage gate: 100% of `to_code` IDs. Studio stays on `latest`
  (no version pinning). Wrap-up commit is optional, via `cf-git-commit`. Session budget
  calibrated via pilot run. Training restartable at wrap-up.
- Restart cleanup archives (never deletes) produced artifacts/code to a timestamped
  workspace folder. For the traceability step, a terminal command is acceptable if the
  current release has no chat-skill equivalent (per the "only where unavoidable" clause),
  with the Trainer presenting the result meaningfully.

Resolved decisions (implementation review, 2026-07-09):
- Prompts use the kit's conversational router in slash-command form
  (`/cf make PRD/DESIGN/ADR/DECOMPOSITION/FEATURE`, `/cf implement`)
  in natural inline-prose form.
- Artifact gates are registry-driven: Studio's `artifacts.toml` is the source of
  truth for artifact locations; gates never hardcode paths. Artifact placement is
  left entirely to Studio — no layout nudges in prompts (decided 2026-07-09); any
  registered location passes. The PRD prompt embeds the product brief as natural
  inline prose — no "Context:" header, no line breaks, human-style sentence flow —
  expanded at render time from `trainer/content/brief.md` via a `{{BRIEF_INLINE}}`
  placeholder (single source; decided 2026-07-09).
- Plain `cfs validate` is NOT used as a gate anywhere — it passes vacuously on an
  empty project. Validation discipline is taught via the workflows' own
  validate-review-fix loops instead.
- Ungated steps are marked completed once the trainee has entered and then left them.
- These requirement/design documents live in the repo (docs/trainer/) as living
  documents and are updated together with Trainer changes.
- CDSL is not named or taught in the Trainer (2026-07-09): trainee-facing texts say
  "precise numbered steps"; the notation the kit uses underneath stays out of scope.
- Step order: DESIGN before ADR (2026-07-09), matching the kit GREENFIELD guide's
  quick-reference sequence; the storage ADR is made after (and can amend) the DESIGN.
- API-first reference app (2026-07-09): the UI requirement is removed; a web UI is
  explicitly out of scope for v1 in the brief. Supersedes the v1-review decision
  "fixed reference app with UI".
- Run step is ungated and port-agnostic (2026-07-09): no fixed port, no Trainer
  "open app" button, no HTTP-probe gate. The trainee runs the app per the project's
  README/GETTING_STARTED or asks the agent ("Run the app" prompt). Supersedes the
  proxy one-click requirement (old FR-5) and the port-5000 expectation.
- No provider/model/API-key provisioning (2026-07-17): the install form requests
  only an optional IDE password. The chat agent (GitHub Copilot) authenticates
  with the trainee's GitHub account; the model is chosen in the chat UI via the
  Auto picker, and a personal Anthropic/OpenAI key can be added via Manage
  Models — both taught in Trainer step 2. All key/model plumbing (manifest
  settings + env, `.constructor-fabric-ai.env`, workspace `.env` copies,
  supervisor env, terminal-env settings, open-agent key export) was removed,
  along with the verify assert on `terminal.integrated.env.linux`.
- IDE password is mandatory and never recorded (2026-07-17): the install form
  requires the password; it is argon2-hashed into code-server's own
  `hashed-password` config and the plaintext transport file is deleted. It is
  not shown in the success text, not logged, not placed in the supervisor
  environment, and the legacy `?password=` auto-login URL patch is removed
  (verify asserts all of this). Lost passwords require reinstalling.
- User-facing branding pass (2026-07-18): marketplace short description, install
  form, topology labels, success screen, and the code-server login page (i18n
  patch in start-services.sh) all use the "Constructor Studio Training
  Environment" naming; the password is called "environment password"
  everywhere; login page header/hint/SIGN IN button customized; success screen
  reduced to heading + link + password note.
- Legacy sweep completed (2026-07-18): deleted the unreferenced VNC/desktop-era
  remnants — scripts/install-ides.sh, scripts/app-server.py, scripts/run-cfc.sh,
  and configs/ (openbox/LXDE files). Notify webhook tooling kept (operational).
- Trainer navigation moved to a top bar (2026-07-21, user decision — the left
  sidebar consumed too much screen space): numbered status chips with
  short-title tooltips replace the sidebar step list (labels under the chips
  were tried and rejected); the in-content step header became a one-line
  sticky element (fonts/colors unchanged). Step short titles are curriculum
  data (`shortTitle`), not renderer constants.

## 1. Overview

### 1.1 Purpose
Replace the current static "showcase" Trainer in the try environment with an interactive,
stateful, guided training experience that walks an absolute beginner through building a
small web application from scratch ("almost greenfield") using the real Constructor Studio
SDLC pipeline — PRD → DESIGN → ADR → DECOMPOSITION → FEATURE → CODE — all the way to
CPT traceability in code, passing tests, and the app actually running.

### 1.2 Background / problems with the current Trainer
- Stops at planning artifacts; never reaches code, tests, a running app, or the
  traceability payoff.
- Teaches a pipeline shape ("PRD → features → tasks → plans", generic `/studio` prompts)
  that does not match the SDLC kit's real pipeline and `cf-sdlc-*` presets.
- Passive: static copy-paste deck, no state, no verification of step completion.
- Content duplicated across 4+ drifting files; dead Electron/VNC/LXDE delivery paths.

## 2. Actors
- **Trainee** — absolute beginner to Constructor Studio (may also be new to AI-assisted
  SDLC in general). Interacts with: Trainer panel, IDE chat agent, occasionally terminal.
- **Chat agent** — the AI coding assistant preconfigured in code-server; executes the
  Studio `cf-*` workflows when prompted by the Trainee. Not controlled by the Trainer.
- **Trainer** — the interactive webview + verification backend being specified here.
- **Environment operator** — deploys the JPS manifest (only an optional IDE password;
  no LLM provider/model/API key — removed 2026-07-17, see decision log).

## 3. Scope

### In scope
1. Interactive Trainer (code-server webview extension + verification backend) in
   jelastic-jps/constructor-fabric.
2. Curriculum covering the full SDLC-kit greenfield path through to a running, tested,
   traceable app.
3. Fixed reference application (small API-first service) as training subject.
4. Environment-prep changes in the same repo needed for the curriculum to work
   (app-port preview, workspace preparation, content cleanup).
5. Removal/retirement of legacy Trainer delivery paths and duplicated prompt content.

### Out of scope (non-goals)
1. Modifying constructorfabric/studio or studio-kit-sdlc (only if absolutely unavoidable;
   any such need is escalated first).
2. Deep-linking or auto-injecting prompts into the chat agent; automating the agent.
3. Free-form "bring your own app idea" path (mentioned as a post-training suggestion only).
4. True greenfield `cfs init` training — Studio comes pre-deployed and pre-configured.
5. Multi-user/classroom features, scoring, certification.

## 4. Reference application (training subject)
- **Fixed app**: a minimal API-first team task service ("TaskLite"): create, list
  (grouped by status), complete, delete via a public API; persisted storage; a web
  UI is explicitly out of scope for v1 (decided 2026-07-09). The brief is
  product-only; no port or URL-shape expectations remain (run step is
  port-agnostic and ungated).
- Deliberately mirrors the SDLC kit's own "taskman" running example so kit templates,
  examples, and the external taskman reference repo stay usable as the answer key —
  but as an HTTP service instead of a CLI.
- **Stack**: Python 3.11 (decided 2026-07-13, after a walkthrough produced a Go
  app the container cannot run) — stated in the DESIGN prompt ("Imply
  implementation in Python 3.11.", where stack belongs in the pipeline). Supersedes the earlier stack-left-to-Studio decision. The environment
  ships Python 3.11 (uv) and Node 22; no compilers.
- Constraints: fully implementable and runnable inside the container; tests runnable
  headlessly; service reachable from the trainee's browser via code-server proxy; small
  enough for a full pipeline run within one session's time/token budget
  (target: 2–3 features in DECOMPOSITION, all implemented).

## 5. Functional requirements
Priorities: p1 = must have for first release, p2 = should have, p3 = nice to have.

### FR-1 Trainer shell (p1)
1. Trainer is delivered as a code-server webview extension (as today) that auto-opens on
   first IDE start and can be reopened at any time via a command/launcher.
2. Trainer never blocks IDE usage; it is a side panel/tab the trainee can hide.
3. Trainer renders a step-based curriculum with: step list/progress overview, current
   step content, navigation (next/back/jump-to-completed), and per-step verification UI.

### FR-2 Curriculum content (p1)
1. Each step provides: (a) concept explanation written for absolute beginners,
   (b) what to do — in the IDE chat and, only where unavoidable, the terminal,
   (c) an example prompt the trainee may copy or rephrase in their own words
   (explicitly framed as such — no injection into chat), (d) what success looks like,
   (e) troubleshooting hints for common failures (validation findings, agent misfires).
2. **Chat-first principle**: trainee-facing instructions use `cf-*` chat skills wherever
   a skill exists for the job; terminal commands appear only where no skill equivalent
   exists. (The Trainer's own backend checks may use the `cfs` CLI freely — invisible
   to the trainee.)
3. Prompts must use the SDLC kit's documented conversational command surface in
   chat slash-command form (`/cf make
   PRD/DESIGN/ADR/DECOMPOSITION/FEATURE`, `/cf implement`),
   matching GREENFIELD.md's canonical "command + Context block" shape.
   (Amended v3.1, 2026-07-09 — was: `cf-sdlc-*` preset names.)
4. Curriculum (draft, ~12 steps; final numbering during design):
   1. Welcome — what Constructor Studio is; the SDLC pipeline map; Studio-for-structure /
      AI-for-judgment; the validate-review-fix loop discipline.
   2. Meet the environment — IDE tour (Trainer panel, chat on the right, Explorer
      on the left); say "hello" in the chat as a smoke test (sign-in if prompted,
      GitHub recommended); note that Constructor Studio is already preinstalled and
      preconfigured. (`cf-help` is mentioned in the wrap-up, not here.)
   3. The reference app brief — hand the trainee the TaskLite product brief (the raw
      input a PM would have); explain artifacts vs. chat.
   4. Create and validate PRD — author via chat (`/cf make PRD`, Context =
      the brief verbatim), then `/cf validate PRD` as a second prompt with
      agent-driven fixes (per GREENFIELD.md's generate→validate rhythm); gate: a PRD
      artifact registered in Studio's registry with its file present.
   5. Create and validate DESIGN — `/cf make DESIGN from PRD. …` (inline
      prose; prescribes only product-shaped constraints: single start command,
      as small as possible — stack choice is left to the Studio workflow), then
      `/cf validate DESIGN`; gate: DESIGN registered.
   6. Create and validate ADR — one decision: task storage, made after DESIGN per
      the kit's quick-reference order (`/cf make ADR for TaskLite task
      storage. Compare SQLite against a plain JSON file …` — inline prose, no
      stack givens), then `/cf validate ADR`; gate: ADR registered.
   7. Create and validate DECOMPOSITION — `/cf make DECOMPOSITION. Aim for
      2 to 3 small features …` (inline prose), then `/cf validate
      DECOMPOSITION`; explain ordering/dependencies; gate: DECOMPOSITION registered.
   8. Create and validate FEATURE specs — all features in one workflow run
      (`/cf make FEATURE for all features`), then `/cf validate FEATURE
      for all features`; explain precise numbered behavior steps and `to_code`
      IDs (CDSL itself is not named); gate: FEATURE specs registered.
   9. Implement and validate code — `/cf implement all features` (bare
      command, no Context; the workflow still proceeds one feature at a time, in
      decomposition order), then `/cf validate code`; explain `@cpt-*`
      markers and the checkbox cascade; gate: `@cpt` markers present in code (the test suite is exercised
      by the workflow itself, not gated — decided 2026-07-09). NOTE: environment expectations (pytest, port 5000, relative URLs)
      are no longer prompted anywhere — the gates and run/troubleshooting content
      surface them discover-and-fix style.
   10. Run the app (ungated) — per the project's README/GETTING_STARTED in a
       terminal, or by asking the agent ("Run the app" prompt); no fixed port,
       no liveness gate.
   11. Traceability payoff (ungated) — via chat (`/cf show the TaskLite
       traceability map`); explore the requirement→code chain end-to-end. No
       coverage gate and no terminal companion (decided 2026-07-09; supersedes the
       100% `to_code` coverage gate and the terminal-fallback decision).
   12. Wrap-up (ungated) — recap; "Keep learning" first (`/cf-help` prompt + guide
       links), then restart / own-idea invitation. No commit step (removed
       2026-07-09 — deferred to a possible future advanced training).

### FR-3 Step verification (p1)
1. Every step declares machine-checkable completion criteria; the Trainer backend
   (extension host, Node side) executes them on demand ("Check my progress" button)
   and on step entry.
2. Check types (minimum set): artifact-registry queries (artifacts of a given kind
   present in `.cf-studio/config/artifacts.toml` with their files on disk — locations
   are registry-driven, never hardcoded paths); file/glob existence; command exit
   code + parsed output (`cfs spec-coverage --min-coverage 100`);
   HTTP liveness probe on the app port; git status.
   Plain `cfs validate` is deliberately NOT a gate (vacuous PASS on empty projects).
3. Check results are displayed as a per-step checklist with pass/fail and, on failure,
   an actionable hint (e.g., surfacing validation findings verbatim).
4. Checks are read-only with respect to the trainee's workspace (they never write,
   fix, or generate artifacts/code). Exception: the Trainer's own state file (FR-4).
5. A trainee may proceed past a failed gate only via an explicit "skip anyway"
   affordance that records the skip in state (p2).

### FR-4 Progress state & restart (p1)
1. Trainer state (current step, per-step check results, skips, timestamps) persists in
   a single file inside the workspace (e.g., `.constructor-fabric-trainer/state.json`)
   and survives IDE reloads, container restarts, and re-deploys of the extension.
2. Reopening the Trainer resumes at the last incomplete step.
3. **Restart at wrap-up (p1)**: the wrap-up step offers "Restart training", which
   resets Trainer state to step 1 and archives everything produced during the run
   (baseline-diff; move to a timestamped folder inside the workspace — never delete),
   including artifacts placed under `.cf-studio/artifacts/`, and restores the
   pre-training artifact registry (`artifacts.toml` snapshot taken at training start;
   the modified copy is kept in the archive) so the workspace precondition set (FR-9)
   holds again for a fresh run (including a run with the trainee's own app idea).
   Studio-owned roots (`.cf-studio` itself, `.git`) are never archived wholesale.
4. A general reset affordance (outside wrap-up) restarts training state without
   touching workspace artifacts (p2).
5. Ungated steps (which have no checks) are marked completed once the trainee has
   entered and then navigated away from them.

### FR-5 Reference-app runnability (p1)
1. The trainee runs the app themselves, following the project's README /
   GETTING_STARTED instructions in a terminal, or by asking the agent to run it
   ("Run the app" prompt). No fixed port, no Trainer-provided open button, no
   liveness gate (decided 2026-07-09; supersedes the proxy one-click mechanism).

### FR-6 Single source of truth for content (p1)
1. All curriculum content (steps, texts, example prompts, check definitions) lives in
   exactly one canonical location in the repo (`trainer/`), in a structured form
   (content definition + renderer, not prose baked into scripts).
2. All duplicated/derived copies are removed or generated from the canonical source:
   the embedded fallback deck in `install-constructor-studio.sh`,
   `CONSTRUCTOR_FABRIC_PROMPTS.md` generation in `auto-bootstrap.sh`,
   `open-agent.sh` banner prompts.

### FR-7 Legacy retirement (p1)
1. Remove the dead Electron delivery path (`trainer/main.js`, `run-trainer.sh`,
   Electron autostart writes) and stale references to it (workspace README text,
   `.constructor-fabric.json` `"trainer": "Electron"` marker).
2. Remove or explicitly quarantine unused VNC/LXDE-era assets (`configs/`,
   `patch-x11vnc.py`, `install-ides.sh`, `landing.html`) — final list at design time (p2).

### FR-8 Deployment integration (p1)
1. `manifest.jps` `verify` extends to assert the new Trainer is installed, its state
   mechanism works, and the workspace precondition set (FR-9) holds.
2. Version bump and install-form behavior unchanged unless the curriculum requires new
   parameters.

### FR-9 Workspace preconditions — "almost greenfield" (p1)
1. Pre-provisioned before the trainee arrives: Studio installed (`cfs` on PATH), SDLC
   kit installed/registered, `cfs init` + `cfs generate-agents` completed (all
   supported agent integrations — the copilot-only narrowing of 2026-07-09 was
   reverted the same day), then `cfs update --with-kits yes` as the final
   deployment step (runtime + kits refreshed to latest; non-fatal), chat agent
   configured with provider/model/token, baseline validation PASS.
2. NOT pre-provisioned: any SDLC artifacts, any application code, any test scaffolding —
   `architecture/`, `.cf-studio/artifacts/`, and `src/` must be absent at training start.
3. The Trainer's step 2 states, in one sentence, that Constructor Studio is already
   preinstalled and preconfigured in the workspace. No deeper provisioning
   explanation is required.

## 6. Non-functional requirements
- **NFR-1 Beginner-proof (p1)**: no step assumes prior knowledge of Studio, spec-driven
  development, or the IDE; every command/prompt is given in full; every failure mode
  surfaced by a gate has a written recovery path (re-prompt agent, re-run validation,
  read findings).
- **NFR-2 Deterministic gates (p1)**: step gates rely only on deterministic checks
  (exit codes, file presence, HTTP probe) — never on LLM judgment.
- **NFR-3 Robust to agent variance (p1)**: the curriculum works when the agent's output
  differs from the example (different wording, extra artifacts); gates check validity,
  not similarity to a golden output.
- **NFR-4 Idempotent provisioning (p2)**: bootstrap/install scripts remain re-runnable;
  re-deploys don't wipe trainee progress or workspace content.
- **NFR-5 Self-contained webview (p2)**: Trainer UI works within code-server webview
  CSP; no external network dependencies at runtime.
- **NFR-6 Session budget (p2)**: a full run (all gates passed) achievable within a
  bounded time/token budget on default models; budget calibrated via a pilot run, then
  encoded as guidance text ("this takes ~N minutes").

## 7. Acceptance criteria (feature-level)
1. A fresh JPS install brings a trainee, with no prior knowledge and only the Trainer's
   guidance, to: a complete registered artifact set (PRD, ≥1 ADR, DESIGN, DECOMPOSITION,
   all FEATUREs); implemented app code with `@cpt-*` markers;
   app running and responding;
2. Trainer survives page reload and container restart with progress intact.
3. "Restart training" at wrap-up returns the workspace to trainable state (artifacts
   archived, state reset) and a second full run is possible.
4. Repo contains exactly one source of curriculum content; grep finds no stale
   duplicated prompt decks and no Electron/VNC-era Trainer references.
5. `manifest.jps` verify passes on a clean deploy.

## 8. Dependencies, assumptions, risks
- **D1**: SDLC kit's `cf-studio` routing surface and artifact registry format as
  shipped in the latest Studio release. **A1**: kit remains installable/registered
  as today (fetched from GitHub during `cfs init --yes` — network required at
  provisioning time; accepted).
- **A2**: the preconfigured chat agent in code-server can execute Studio skills
  (generated host integrations) reliably.
- **R1**: full implement stage is the longest/most variable step (model quality, token
  cost). Mitigation: small feature count, per-feature gating, troubleshooting content,
  pilot-run calibration (NFR-6).
- **R2**: code-server proxy quirks for the app UI (path prefixes). Mitigation: app
  constraint "proxy-friendly relative URLs".
- **R3**: Studio ships from `latest` (decided — no pinning), so upstream renames of
  skills/outputs can break the curriculum between deploys. Mitigations: chat-first
  content leaning on stable entrypoints (`cf`, `cf-help` routing); `manifest.jps`
  verify catching breakage at deploy time; residual risk accepted.

## 9. Open questions
None currently. This is a living document: new decisions are recorded in the
"Resolved decisions" blocks above and folded into the requirements as they are made.
