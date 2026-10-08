// Second Brain page: router, rail keys, ⌘K, polling. Views live in their own modules.
import { $, el, store, load, isTyping, getLook, setLook, POLL_MS } from './core.js';
import * as inbox from './inbox.js';
import * as today from './today.js';
import * as ask from './ask.js';
import * as graph from './graph.js';
import * as projects from './projects.js';
import * as system from './system.js';
import * as palette from './palette.js';

// Numbers follow the design (07 meet is not built).
const VIEWS = [
  { id: 'inbox', k: '1', label: 'Inbox', mod: inbox, badge: (d) => inbox.inboxCount(d) },
  { id: 'today', k: '2', label: 'Today', mod: today, badge: (d) => today.dueCount(d) },
  { id: 'ask', k: '3', label: 'Ask', mod: ask, badge: () => 0 },
  { id: 'graph', k: '4', label: 'Graph', mod: graph, badge: () => 0 },
  { id: 'projects', k: '5', label: 'Projects', mod: projects, badge: () => 0 },
  { id: 'system', k: '6', label: 'System', mod: system, badge: () => 0 },
];
const DEFAULT = 'today';
let current = null;
let deferred = false;

// "#today/slug", "#inbox"; a bare "#slug" (older links) means today/slug.
function parseHash() {
  let raw = '';
  try {
    raw = decodeURIComponent(location.hash.slice(1));
  } catch (e) {
    raw = '';   // malformed escape: fall back to the default view
  }
  const [head, ...rest] = raw.split('/');
  const view = VIEWS.find((v) => v.id === head);
  if (view) return { view, param: rest.join('/') || null };
  return { view: VIEWS.find((v) => v.id === DEFAULT), param: raw || null };
}

function route() {
  const { view, param } = parseHash();
  if (current !== view) {
    if (current && current.mod.unmount) current.mod.unmount();
    current = view;
    view.mod.mount($('panel'), param);
    renderRail();
  } else if (param && view.mod.mount.length > 1) {
    view.mod.mount($('panel'), param);
  }
  if (store.data) view.mod.update();
}

function renderRail() {
  const keys = VIEWS.map((v) => {
    const on = v === current;
    const badge = store.data ? v.badge(store.data) : 0;
    return el('a', {
      class: 'key' + (on ? ' is-on' : ''), href: '#' + v.id, 'aria-current': on ? 'page' : null,
      'aria-label': v.label + (badge ? ' (' + badge + ')' : '') + ', key ' + v.k,
    },
      el('span', { class: 'key-top' }, el('span', { class: 'key-k' }, v.k),
        badge ? el('span', { class: 'key-badge' }, String(badge)) : el('span', { class: 'key-dot' })),
      el('span', { class: 'key-label' }, v.label));
  });
  $('rail-keys').replaceChildren(...keys);
}

function renderStatus() {
  const d = store.data;
  const open = d.tasks.filter((t) => t.status !== 'done').length;
  $('counts').textContent = open + ' open · ' + today.dueCount(d) + ' due · ' + inbox.inboxCount(d) + ' in';
}

function render() {
  renderStatus();
  renderRail();
  current.mod.update();
}

// A poll must not close a dropdown the owner has open: wait until it loses focus.
store.onChange = () => {
  if ((document.activeElement || {}).tagName === 'SELECT') deferred = true;
  else render();
};
document.addEventListener('focusout', (e) => {
  if (deferred && e.target.tagName === 'SELECT') {
    deferred = false;
    setTimeout(render, 0);
  }
});

window.addEventListener('hashchange', route);
document.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
    e.preventDefault();
    if (palette.isOpen()) palette.close(); else palette.open();
    return;
  }
  if (e.metaKey || e.ctrlKey || e.altKey || isTyping() || palette.isOpen()) return;
  if (e.key === '/') { e.preventDefault(); palette.open(); return; }
  if (e.key === 'c') { e.preventDefault(); palette.open('capture'); return; }
  const v = VIEWS.find((x) => x.k === e.key);
  if (v) location.hash = '#' + v.id;
});
$('search-key').addEventListener('click', () => palette.open());
document.addEventListener('visibilitychange', () => { if (!document.hidden) load(); });

setLook(getLook());
palette.init(VIEWS, (q) => ask.askNow(q));

function tickClock() {
  $('clock').textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}
tickClock();
setInterval(tickClock, 15000);
setInterval(() => { if (!document.hidden) load(); }, POLL_MS);
route();
load();
