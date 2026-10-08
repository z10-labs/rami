// Shared helpers for the Second Brain page: DOM building, API calls, time
// formatting. Everything from the brain is inserted as text, never as HTML.

export const TOKEN = document.querySelector('meta[name="brain-token"]').content;
export const POLL_MS = 10000;
export const $ = (id) => document.getElementById(id);

export const store = { data: null, lastJson: '', queue: Promise.resolve(), onChange: () => {} };

export function el(tag, attrs, ...kids) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') n.className = v;
    // Styles go through the CSSOM: the page's CSP forbids style attributes.
    else if (k === 'style') for (const [prop, val] of Object.entries(v)) n.style.setProperty(prop, val);
    else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
    else n.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) {
    if (kid === null || kid === undefined || kid === false) continue;
    n.append(kid instanceof Node ? kid : String(kid));
  }
  return n;
}

// ---------------------------------------------------------------- time
export const day = (ts) => (ts || '').slice(0, 10);
export const hm = (ts) => (ts || '').slice(11, 16);
export function shortWhen(ts) {
  if (!ts) return '—';
  return day(ts) === day(store.data.now) ? hm(ts) : ts.slice(5, 10) + ' ' + hm(ts);
}
export function dayLabel(d) {
  const dt = new Date(d + 'T12:00');
  return isNaN(dt) ? d : dt.toLocaleDateString(undefined, { weekday: 'short', day: '2-digit', month: 'short' });
}

// ---------------------------------------------------------------- api
export async function api(path, body) {
  const opt = { headers: { 'X-Brain-Token': TOKEN } };
  if (body !== undefined) {
    opt.method = 'POST';
    opt.headers['Content-Type'] = 'application/json';
    opt.body = JSON.stringify(body);
  }
  const r = await fetch(path, opt);
  let j = {};
  try { j = await r.json(); } catch (e) { /* non-JSON error page */ }
  if (!r.ok) throw new Error(j.error || 'HTTP ' + r.status);
  return j;
}

export function setStatusLine(ok, message) {
  $('led').classList.toggle('is-off', !ok);
  $('conn').textContent = ok ? 'local · live' : 'offline';
  const err = $('error');
  err.hidden = !message;
  err.textContent = message || '';
}

function accept(next) {
  const json = JSON.stringify(next);
  if (json === store.lastJson) return;
  store.lastJson = json;
  store.data = next;
  store.onChange();
}

export async function load(force) {
  if (force) store.lastJson = '';
  try {
    const next = await api('api/state');
    setStatusLine(true, '');
    accept(next);
  } catch (e) {
    setStatusLine(false, 'brain serve not reachable: ' + e.message);
  }
}

// POST an action; on success the reply carries the new state. Actions run one
// at a time in click order, so quick clicks are queued rather than dropped.
export function act(path, body) {
  const run = async () => {
    try {
      const j = await api(path, body);
      setStatusLine(true, '');
      accept(j.state);
      return true;
    } catch (e) {
      setStatusLine(true, e.message);
      return false;
    }
  };
  const p = store.queue.then(run);
  store.queue = p.catch(() => false);
  return p;
}

// Re-render without losing keyboard focus. Elements carry data-fk keys
// ("ok:<id>"): the element with the same key gets focus back. If it is gone or
// disabled (an accepted capture, a ticked follow-up), focus goes to the element
// of the same kind now at its place, else to `fallback` (a selector).
export function keepFocus(render, fallback) {
  const cur = document.activeElement;
  const key = cur && cur.dataset ? cur.dataset.fk : null;
  const kind = key ? key.split(':')[0] + ':' : '';
  const sameKind = () => [...document.querySelectorAll('[data-fk^="' + CSS.escape(kind) + '"]')];
  const index = key ? sameKind().indexOf(cur) : -1;
  render();
  if (!key || (document.activeElement && document.activeElement !== document.body)) return;
  const usable = (n) => n && !n.disabled && n.isConnected;
  let n = document.querySelector('[data-fk="' + CSS.escape(key) + '"]');
  if (!usable(n)) {
    const peers = sameKind().filter(usable);
    n = peers[Math.min(Math.max(index, 0), peers.length - 1)];
  }
  if (!usable(n) && fallback) n = document.querySelector(fallback);
  if (usable(n)) n.focus({ preventScroll: true });
}

export const reducedMotion = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;

export const taskPath = (slug, what) => 'api/tasks/' + encodeURIComponent(slug) + '/' + what;
export const taskTitle = (slug) => (store.data.tasks.find((t) => t.slug === slug) || {}).title || slug;
export const isTyping = () => ['INPUT', 'TEXTAREA', 'SELECT'].includes((document.activeElement || {}).tagName);

export function panelHead(num, title, subId) {
  return el('div', { class: 'panel-head' },
    el('span', { class: 'panel-num' }, num),
    el('h1', { id: 'view-heading' }, title),
    el('span', { class: 'panel-sub', id: subId }));
}
