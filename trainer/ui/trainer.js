/* Constructor Fabric Trainer — webview renderer.
 * Receives the curriculum, brief, and progress state from the extension
 * backend, renders the current step, and sends user intents (navigate, run
 * checks, skip, restart, open links) back. No network access, no libraries. */
(function () {
  'use strict';

  var vscode = acquireVsCodeApi();
  var curriculum = null;
  var brief = '';
  var state = null;
  var env = {};
  var lastResults = {}; // stepId -> results array from the latest check run
  var busyStep = null;
  var confirmingRestart = false;

  // ---------------------------------------------------------------- helpers

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function inlineMd(s) {
    var out = esc(s);
    out = out.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a data-href="$2">$1</a>');
    out = out.replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>');
    out = out.replace(/\*([^*]+)\*/g, '<em>$1</em>');
    out = out.replace(/`([^`]+)`/g, function (m, c) {
      return '<code' + (/^\/cf/.test(c) ? ' class="slash-cmd"' : '') + '>' + c + '</code>';
    });
    return out;
  }

  function renderTable(rows) {
    var parse = function (r) {
      var cells = r.split('|');
      if (cells.length && cells[0].trim() === '') cells.shift();
      if (cells.length && cells[cells.length - 1].trim() === '') cells.pop();
      return cells.map(function (c) { return c.trim(); });
    };
    var header = parse(rows[0]);
    var body = rows.slice(1)
      .filter(function (r) { return !/^[\s|:-]+$/.test(r); })
      .map(parse);
    var html = '<table><thead><tr>' +
      header.map(function (c) { return '<th>' + inlineMd(c) + '</th>'; }).join('') +
      '</tr></thead><tbody>';
    body.forEach(function (cells) {
      html += '<tr>' + cells.map(function (c) { return '<td>' + inlineMd(c) + '</td>'; }).join('') + '</tr>';
    });
    return html + '</tbody></table>';
  }

  // Tint slash commands at line starts the way Copilot chat renders them.
  // Applied to already-escaped text; spans do not affect textContent (copy).
  function highlightSlashCommands(escaped) {
    return escaped.replace(/(^|\n)(\/[a-z][a-z0-9-]*)/g, '$1<span class="slash-cmd">$2</span>');
  }

  // The brief flattened to one flowing human-style sentence stream: heading
  // dropped, markdown markers stripped, every line joined with spaces. Used by
  // {{BRIEF_INLINE}} so prompts read like something a person would type.
  function briefInlineText(md) {
    var text = String(md).trim().split(/\n\s*\n/)
      .filter(function (p) { return !/^#/.test(p.trim()); })
      .map(function (p) {
        return p.split('\n').map(function (l) { return l.trim().replace(/^-\s+/, ''); }).join(' ');
      })
      .join(' ')
      .replace(/\*\*([^*]+)\*\*/g, '$1')
      .replace(/\*([^*]+)\*/g, '$1');
    // "make PRD for TaskLite. TaskLite is …" reads robotic; start with "It is".
    var appName = curriculum && curriculum.app ? curriculum.app.name : '';
    if (appName && text.indexOf(appName + ' is ') === 0) {
      text = 'It is ' + text.slice((appName + ' is ').length);
    }
    return text;
  }

  // The brief is markdown authored with hard line wraps; as chat-prompt text it
  // must be plain: headings/bold markers stripped, paragraphs unwrapped into
  // single lines (bullets kept on their own lines).
  function briefPlainText(md) {
    var paras = String(md).trim().split(/\n\s*\n/);
    return paras.map(function (p) {
      var out = [];
      p.split('\n').forEach(function (ln) {
        if (/^\s*-\s+/.test(ln) || !out.length) out.push(ln.trim());
        else out[out.length - 1] += ' ' + ln.trim();
      });
      return out.join('\n');
    }).join('\n\n')
      .replace(/^#+\s*/gm, '')
      .replace(/\*\*([^*]+)\*\*/g, '$1')
      .replace(/\*([^*]+)\*/g, '$1');
  }

  // Minimal markdown: paragraphs, ## headings, - and 1. lists, ``` fences.
  function renderMd(text) {
    if (!text) return '';
    var lines = String(text).split('\n');
    var html = [];
    var i = 0;
    while (i < lines.length) {
      var line = lines[i];
      if (/^```/.test(line)) {
        var code = [];
        i++;
        while (i < lines.length && !/^```/.test(lines[i])) { code.push(lines[i]); i++; }
        i++;
        html.push('<pre><code>' + esc(code.join('\n')) + '</code></pre>');
      } else if (/^##+\s/.test(line)) {
        html.push('<h3>' + inlineMd(line.replace(/^##+\s/, '')) + '</h3>');
        i++;
      } else if (/^\|/.test(line)) {
        var trows = [];
        while (i < lines.length && /^\|/.test(lines[i])) { trows.push(lines[i]); i++; }
        html.push(renderTable(trows));
      } else if (/^\s*-\s+/.test(line)) {
        var items = [];
        while (i < lines.length && /^\s*-\s+/.test(lines[i])) {
          var item = lines[i].replace(/^\s*-\s+/, '');
          i++;
          // Wrapped list items continue on indented/plain follow-up lines.
          while (i < lines.length && lines[i].trim() !== '' &&
                 !/^```|^##+\s|^\s*-\s+|^\s*\d+\.\s+|^\|/.test(lines[i])) {
            item += ' ' + lines[i].trim();
            i++;
          }
          items.push('<li>' + inlineMd(item) + '</li>');
        }
        html.push('<ul>' + items.join('') + '</ul>');
      } else if (/^\s*\d+\.\s+/.test(line)) {
        var oitems = [];
        while (i < lines.length && /^\s*\d+\.\s+/.test(lines[i])) {
          var oitem = lines[i].replace(/^\s*\d+\.\s+/, '');
          i++;
          while (i < lines.length && lines[i].trim() !== '' &&
                 !/^```|^##+\s|^\s*-\s+|^\s*\d+\.\s+|^\|/.test(lines[i])) {
            oitem += ' ' + lines[i].trim();
            i++;
          }
          oitems.push('<li>' + inlineMd(oitem) + '</li>');
        }
        html.push('<ol>' + oitems.join('') + '</ol>');
      } else if (line.trim() === '') {
        i++;
      } else {
        var para = [];
        while (i < lines.length && lines[i].trim() !== '' &&
               !/^```|^##+\s|^\s*-\s+|^\s*\d+\.\s+|^\|/.test(lines[i])) {
          para.push(lines[i]);
          i++;
        }
        html.push('<p>' + inlineMd(para.join(' ')) + '</p>');
      }
    }
    return '<div class="md">' + html.join('') + '</div>';
  }

  function stepById(id) {
    for (var k = 0; k < curriculum.steps.length; k++) {
      if (curriculum.steps[k].id === id) return curriculum.steps[k];
    }
    return null;
  }

  function stepIndex(id) {
    for (var k = 0; k < curriculum.steps.length; k++) {
      if (curriculum.steps[k].id === id) return k;
    }
    return 0;
  }

  function stepStatus(step) {
    var st = (state.steps || {})[step.id];
    if (st && (st.status === 'passed' || st.status === 'skipped')) return st.status;
    return 'pending';
  }

  function stepDone(step) {
    if (!step.gated) return true; // ungated steps never block progress
    var s = stepStatus(step);
    return s === 'passed' || s === 'skipped';
  }

  // Steps unlock in order: everything up to (and including) the first gated
  // step that is not yet passed/skipped.
  function unlockedIndex() {
    for (var k = 0; k < curriculum.steps.length; k++) {
      if (!stepDone(curriculum.steps[k])) return k;
    }
    return curriculum.steps.length - 1;
  }

  function post(msg) { vscode.postMessage(msg); }

  // ---------------------------------------------------------------- render

  function render() {
    if (!curriculum || !state) return;
    renderNav();
    renderStep();
    renderFooter();
  }

  function renderNav() {
    var current = state.currentStep;
    var maxIdx = unlockedIndex();
    var html = curriculum.steps.map(function (step, idx) {
      var status = stepStatus(step);
      var mark = String(idx + 1);
      var cls = ['nav-step'];
      if (step.id === current) cls.push('active');
      if (status === 'passed') cls.push('passed');
      if (status === 'skipped') cls.push('skipped');
      if (idx > maxIdx) cls.push('locked');
      return '<div class="' + cls.join(' ') + '" data-step="' + esc(step.id) + '" data-idx="' + idx + '">' +
        '<div class="mark">' + mark + '</div>' +
        '<div><b>' + esc(step.title) + '</b><span>' + esc(step.subtitle || '') + '</span></div>' +
        '</div>';
    }).join('');
    document.getElementById('nav').innerHTML = html;
    Array.prototype.forEach.call(document.querySelectorAll('.nav-step'), function (el) {
      el.addEventListener('click', function () {
        var idx = Number(el.getAttribute('data-idx'));
        if (idx <= unlockedIndex()) goToStep(el.getAttribute('data-step'));
      });
    });
  }

  function checkRowsHtml(step) {
    var results = lastResults[step.id];
    var saved = (state.steps || {})[step.id];
    var rows = (step.checks || []).map(function (check) {
      var r = null;
      if (results) {
        for (var k = 0; k < results.length; k++) if (results[k].id === check.id) r = results[k];
      } else if (saved && saved.checks && saved.checks[check.id]) {
        r = saved.checks[check.id];
        r = { id: check.id, ok: r.ok, summary: r.summary, label: check.label, failHint: check.failHint };
      }
      var cls = r ? (r.ok ? 'ok' : 'fail') : 'unknown';
      var icon = r ? (r.ok ? '✓' : '✗') : '○';
      var html = '<div class="check-row ' + cls + '">' +
        '<div class="icon">' + icon + '</div>' +
        '<div><div>' + esc(check.label) + '</div>' +
        (r ? '<div class="summary">' + esc(r.summary || '') + '</div>' : '') +
        '</div></div>';
      if (r && !r.ok) {
        if (r.detail) html += '<div class="check-detail">' + esc(r.detail) + '</div>';
        if (check.failHint) html += '<div class="check-hint">' + inlineMd(check.failHint) + '</div>';
      }
      return html;
    });
    return rows.join('');
  }

  function renderStep() {
    var step = stepById(state.currentStep) || curriculum.steps[0];
    var idx = stepIndex(step.id);
    var s = step.sections || {};
    var html = '';

    html += '<div class="step-head"><div class="kicker">Step ' + (idx + 1) + ' of ' +
      curriculum.steps.length + '</div><h2>' + esc(step.title) + '</h2></div>';

    if (s.concept) html += renderMd(s.concept);

    if (s.actions) {
      html += '<div class="section-label">What to do</div>' + renderMd(s.actions);
    }

    if (step.includeBrief && brief) {
      html += '<div class="section-label">The brief</div>' +
        '<div class="brief-panel">' + renderMd(brief) + '</div>';
    }

    // A step may define a single examplePrompt or a prompts array
    // [{label, text}, ...]. {{BRIEF}} expands to the canonical product brief
    // (single source: content/brief.md) so prompt Context never drifts.
    var promptList = s.prompts || (s.examplePrompt ? [{ text: s.examplePrompt }] : []);
    if (promptList.length) {
      html += '<div class="section-label">Example prompt' + (promptList.length > 1 ? 's' : '') + '</div>';
      promptList.forEach(function (p, k) {
        var promptValue = String(p.text)
          .replace('{{BRIEF_INLINE}}', briefInlineText(brief))
          .replace('{{BRIEF}}', briefPlainText(brief));
        html += '<div class="prompt-box">' +
          '<div class="prompt-head"><span>' + esc(p.label || 'Say this in the chat') + '</span>' +
          '<span><button class="btn secondary copy-btn" data-prompt="' + k + '">Copy</button>' +
          '<span class="copy-note" id="copyNote-' + k + '"></span></span></div>' +
          '<pre class="prompt-text" id="promptText-' + k + '">' + highlightSlashCommands(esc(promptValue)) + '</pre>' +
          '</div>';
      });
      if (s.afterPrompt) html += renderMd(s.afterPrompt);
    }

    if ((step.checks || []).length) {
      var gateLabel = step.gated ? 'Step gate' : 'Optional check';
      html += '<div class="section-label">' + gateLabel + '</div><div class="checks">' +
        checkRowsHtml(step) +
        '<div class="check-actions">' +
        '<button class="btn primary" id="checkBtn"' + (busyStep ? ' disabled' : '') + '>Check my progress</button>' +
        (busyStep === step.id ? '<div class="spinner"></div><span class="summary">Running checks…</span>' : '') +
        (canSkip(step) ? '<span class="skip-link" id="skipLink">Skip anyway (not recommended)</span>' : '') +
        '</div></div>';
    }

    if (s.success) {
      html += '<div class="section-label">What success looks like</div>' + renderMd(s.success);
    }

    if (step.isWrapup) {
      html += '<div class="section-label">Keep going</div><div class="links-row">' +
        '<button class="btn secondary" data-link="' + esc(curriculum.links.quickstart) + '">Studio Quickstart guide</button>' +
        '<button class="btn secondary" data-link="' + esc(curriculum.links.greenfield) + '">Greenfield guide</button>' +
        '<button class="btn secondary" data-link="' + esc(curriculum.links.brownfield) + '">Brownfield guide</button>' +
        '</div>';
      html += '<div class="section-label">Start over</div>';
      if (confirmingRestart) {
        html += '<div class="confirm-box">' +
          '<b>Restart training?</b>' +
          '<p>Everything you built (artifacts, code, tests) will be <b>moved</b> to a ' +
          '<code>training-archive/</code> folder inside the workspace — nothing is deleted. ' +
          'The trainer resets to step 1.</p>' +
          '<div class="row"><button class="btn danger" id="confirmRestartBtn">Yes, archive and restart</button>' +
          '<button class="btn secondary" id="cancelRestartBtn">Cancel</button></div></div>';
      } else {
        html += '<div><button class="btn danger" id="restartBtn">Restart training</button></div>';
      }
    }

    if (s.troubleshooting) {
      html += '<details class="trouble"><summary>Something not working?</summary>' +
        renderMd(s.troubleshooting) + '</details>';
    }

    document.getElementById('content').innerHTML = html;
    wireStepHandlers(step);
  }

  function canSkip(step) {
    if (!step.gated || !step.skippable) return false;
    if (stepStatus(step) !== 'pending') return false;
    var saved = (state.steps || {})[step.id];
    var attempted = lastResults[step.id] || (saved && saved.lastCheckAt);
    return Boolean(attempted);
  }

  function wireStepHandlers(step) {
    Array.prototype.forEach.call(document.querySelectorAll('.prompt-text'), function (pre) {
      // Manual Ctrl+C on a selection also carries a text/html flavor, which
      // the chat input converts into a fenced code block on paste. Strip it:
      // copy the plain selection only, same as the Copy button.
      pre.addEventListener('copy', function (ev) {
        var sel = window.getSelection ? String(window.getSelection()) : '';
        if (sel && ev.clipboardData) {
          ev.clipboardData.setData('text/plain', sel);
          ev.preventDefault();
        }
      });
    });
    Array.prototype.forEach.call(document.querySelectorAll('.copy-btn'), function (btn) {
      btn.addEventListener('click', function () {
        var k = btn.getAttribute('data-prompt');
        var text = document.getElementById('promptText-' + k).textContent;
        var note = document.getElementById('copyNote-' + k);
        var done = function (ok) { note.textContent = ok ? 'Copied' : 'Select and press Ctrl+C'; };
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(false); });
        } else {
          done(false);
        }
      });
    });
    var checkBtn = document.getElementById('checkBtn');
    if (checkBtn) {
      checkBtn.addEventListener('click', function () {
        if (busyStep) return;
        busyStep = step.id;
        render();
        post({ type: 'runChecks', stepId: step.id });
      });
    }
    var skipLink = document.getElementById('skipLink');
    if (skipLink) {
      skipLink.addEventListener('click', function () { post({ type: 'skipStep', stepId: step.id }); });
    }
    var restartBtn = document.getElementById('restartBtn');
    if (restartBtn) {
      restartBtn.addEventListener('click', function () { confirmingRestart = true; render(); });
    }
    var confirmRestartBtn = document.getElementById('confirmRestartBtn');
    if (confirmRestartBtn) {
      confirmRestartBtn.addEventListener('click', function () {
        confirmingRestart = false;
        post({ type: 'restartTraining', archive: true });
      });
    }
    var cancelRestartBtn = document.getElementById('cancelRestartBtn');
    if (cancelRestartBtn) {
      cancelRestartBtn.addEventListener('click', function () { confirmingRestart = false; render(); });
    }
    Array.prototype.forEach.call(document.querySelectorAll('[data-link]'), function (el) {
      el.addEventListener('click', function () { post({ type: 'openExternal', url: el.getAttribute('data-link') }); });
    });
    Array.prototype.forEach.call(document.querySelectorAll('.md a[data-href]'), function (el) {
      el.addEventListener('click', function (ev) {
        ev.preventDefault();
        post({ type: 'openExternal', url: el.getAttribute('data-href') });
      });
    });
  }

  function renderFooter() {
    var step = stepById(state.currentStep) || curriculum.steps[0];
    var idx = stepIndex(step.id);
    var prevBtn = document.getElementById('prevBtn');
    var nextBtn = document.getElementById('nextBtn');
    var note = document.getElementById('footNote');
    prevBtn.disabled = idx === 0;
    var last = idx === curriculum.steps.length - 1;
    var blocked = step.gated && !stepDone(step);
    nextBtn.disabled = last || blocked;
    nextBtn.textContent = last ? 'Finished' : 'Next';
    note.textContent = blocked
      ? 'Pass the step gate above (or skip it) to continue.'
      : esc(step.title) + ' — ' + (step.subtitle || '');
  }

  function goToStep(id) {
    confirmingRestart = false;
    state.currentStep = id;
    post({ type: 'setStep', stepId: id });
    render();
    autoCheck(id);
  }

  // Run the gate automatically when a gated step is entered for the first
  // time, so returning users immediately see their verified progress.
  function autoCheck(id) {
    var step = stepById(id);
    if (!step || !step.gated || busyStep) return;
    var saved = (state.steps || {})[id];
    if (saved && saved.lastCheckAt) return;
    if (!lastResults[id]) {
      busyStep = id;
      render();
      post({ type: 'runChecks', stepId: id });
    }
  }

  // ---------------------------------------------------------------- wiring

  document.getElementById('prevBtn').addEventListener('click', function () {
    var idx = stepIndex(state.currentStep);
    if (idx > 0) goToStep(curriculum.steps[idx - 1].id);
  });
  document.getElementById('nextBtn').addEventListener('click', function () {
    var idx = stepIndex(state.currentStep);
    if (idx < curriculum.steps.length - 1) goToStep(curriculum.steps[idx + 1].id);
  });

  window.addEventListener('message', function (event) {
    var msg = event.data || {};
    switch (msg.type) {
      case 'init':
        curriculum = msg.curriculum;
        brief = msg.brief || '';
        state = msg.state;
        env = msg.env || {};
        render();
        break;
      case 'stateChanged':
        state = msg.state;
        render();
        break;
      case 'busy':
        busyStep = msg.stepId;
        render();
        break;
      case 'checkResults':
        busyStep = null;
        lastResults[msg.stepId] = msg.results;
        state = msg.state;
        render();
        break;
      case 'restarted':
        busyStep = null;
        lastResults = {};
        confirmingRestart = false;
        state = msg.state;
        render();
        break;
      default:
        break;
    }
  });

  post({ type: 'ready' });
})();
