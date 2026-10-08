// Ask: questions answered from the brain by a read-only claude run.
import { $, el, api, store, panelHead, dayLabel, day, hm, reducedMotion } from './core.js';

const SUGGESTIONS = ["What's blocked right now?", 'What did I work on today?', 'What is due next?', 'What did we decide recently?'];
let history = [];
let pending = null;   // the question being answered
let prefill = '';

export function askNow(q) {
  prefill = q;
  if (location.hash === '#ask') send(q);
  else location.hash = '#ask';
}

export async function mount(panel) {
  const model = (store.data && store.data.model) || '';
  panel.replaceChildren(
    panelHead('03', 'ask', 'ask-sub'),
    el('div', { class: 'msgs', id: 'msgs', 'aria-live': 'polite' }),
    el('div', { class: 'ask-foot' },
      el('div', { class: 'chips', id: 'ask-sugg' }, SUGGESTIONS.map((s) => el('button', {
        class: 'chip', type: 'button', disabled: !!pending, onclick: () => send(s),
      }, s))),
      el('form', { class: 'capture', onsubmit: (e) => { e.preventDefault(); send($('ask-q').value); } },
        el('div', { class: 'capture-field ask-field' },
          el('span', { class: 'capture-mark', 'aria-hidden': 'true' }, '?'),
          el('label', { class: 'sr-only', for: 'ask-q' }, 'Ask your brain'),
          el('input', { id: 'ask-q', autocomplete: 'off', maxlength: '500', placeholder: 'ask your brain…' })),
        el('button', { type: 'submit', class: 'capture-add send', id: 'ask-send', disabled: !!pending }, 'SEND'))));
  $('ask-sub').textContent = 'claude ' + (model || 'haiku') + ' · reads ~/brain, read-only · answers take ~15s';
  renderMsgs();
  try {
    history = (await api('api/ask')).history;
  } catch (e) {
    history = [];
  }
  if (!$('ask-q')) return;   // the owner left Ask while history was loading
  renderMsgs();
  if (prefill) {
    const q = prefill;
    prefill = '';
    send(q);
  } else {
    $('ask-q').focus();
  }
}

function setPending(on) {
  if ($('ask-send')) $('ask-send').disabled = on;
  document.querySelectorAll('#ask-sugg button').forEach((b) => { b.disabled = on; });
}

export function update() { /* answers do not depend on the polled state */ }

async function send(q) {
  q = (q || '').trim();
  if (!q || pending) return;
  pending = q;
  $('ask-q').value = '';
  setPending(true);
  renderMsgs();
  try {
    history = [...history, await api('api/ask', { question: q })];
  } catch (e) {
    history = [...history, { at: '', question: q, answer: 'Could not answer: ' + e.message, refs: [], error: true }];
  } finally {
    pending = null;
    setPending(false);
    if ($('ask-q')) {
      renderMsgs();
      $('ask-q').focus();
    }
  }
}

// The small Markdown the model uses (bullets, `code`, **bold**), built as DOM
// nodes: the answer is still only ever inserted as text.
function inline(text) {
  return text.split(/(`[^`]+`|\*\*[^*]+\*\*)/).filter(Boolean).map((part) => {
    if (part.startsWith('`') && part.endsWith('`') && part.length > 2) return el('code', {}, part.slice(1, -1));
    if (part.startsWith('**') && part.endsWith('**') && part.length > 4) return el('b', {}, part.slice(2, -2));
    return part;
  });
}

function markdown(text) {
  const out = [];
  let list = null;
  for (const line of text.split('\n')) {
    const m = /^\s*[-*•]\s+(.*)$/.exec(line);
    if (m) {
      if (!list) out.push(list = el('ul', { class: 'md-list' }));
      list.append(el('li', {}, inline(m[1])));
    } else if (line.trim()) {
      list = null;
      out.push(el('p', {}, inline(line.trim())));
    } else {
      list = null;
    }
  }
  return out;
}

function msg(who, cls, text, refs, at) {
  return el('div', { class: 'msg' },
    el('span', { class: 'msg-who ' + cls }, who, at && el('span', { class: 'msg-at' }, at)),
    el('div', { class: 'msg-body' },
      cls === 'you' ? el('p', { class: 'msg-text is-q' }, text) : el('div', { class: 'msg-text md' }, markdown(text)),
      refs && refs.length ? el('div', { class: 'chips' }, refs.map((r) =>
        el('a', { class: 'chip', href: '#today/' + encodeURIComponent(r) }, '↳ ' + r))) : null));
}

function renderMsgs() {
  const box = $('msgs');
  if (!box) return;
  const out = [];
  if (!history.length && !pending) {
    out.push(el('p', { class: 'empty' }, el('span', { class: 'empty-big' }, 'ask anything.'),
      el('span', { class: 'empty-sub' }, 'about your tasks, logs, decisions and follow-ups')));
  }
  let lastDay = '';
  for (const h of history.slice(-30)) {
    if (h.at && day(h.at) !== lastDay) {
      lastDay = day(h.at);
      out.push(el('div', { class: 'day' }, dayLabel(lastDay)));
    }
    out.push(msg('you', 'you', h.question, null, h.at ? hm(h.at) : ''));
    out.push(msg('brain', h.error ? 'err' : 'brain', h.answer, h.refs, ''));
  }
  if (pending) {
    out.push(msg('you', 'you', pending, null, ''));
    out.push(el('div', { class: 'msg' }, el('span', { class: 'msg-who brain' }, 'brain'),
      el('p', { class: 'msg-text thinking' }, 'reading your brain', el('span', { class: 'cursor', 'aria-hidden': 'true' }, '▍'))));
  }
  box.replaceChildren(...out);
  box.scrollTo({ top: box.scrollHeight, behavior: reducedMotion() ? 'auto' : 'smooth' });
}
