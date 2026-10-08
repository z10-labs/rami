// Second Brain: Today screen. Talks to `brain serve` on 127.0.0.1.
// Everything from the brain is inserted as text (never as HTML).
'use strict';

const TOKEN = document.querySelector('meta[name="brain-token"]').content;
const POLL_MS = 10000;
const STATUSES = ['active', 'waiting', 'blocked', 'done'];
const ORDER = { blocked: 0, active: 1, waiting: 2, done: 3 };
const $ = (id) => document.getElementById(id);

let data = null;
let lastJson = '';
let selected = decodeURIComponent(location.hash.slice(1)) || null;
let busy = false;

// ---------------------------------------------------------------- helpers
function el(tag, attrs, ...kids) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') n.className = v;
    else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
    else n.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) {
    if (kid === null || kid === undefined || kid === false) continue;
    n.append(kid instanceof Node ? kid : String(kid));
  }
  return n;
}

const day = (ts) => (ts || '').slice(0, 10);
const hm = (ts) => (ts || '').slice(11, 16);
function shortWhen(ts) {
  if (!ts) return '—';
  return day(ts) === day(data.now) ? hm(ts) : ts.slice(5, 10) + ' ' + hm(ts);
}
function dayLabel(d) {
  const dt = new Date(d + 'T12:00');
  return isNaN(dt) ? d : dt.toLocaleDateString(undefined, { weekday: 'short', day: '2-digit', month: 'short' });
}
const openFollowups = (t) => t.followups.filter((f) => !f.done).sort((a, b) => a.due.localeCompare(b.due));
const isDue = (f) => !f.done && f.due <= data.now;
const sortedTasks = () => [...data.tasks].sort((a, b) =>
  (ORDER[a.status] ?? 9) - (ORDER[b.status] ?? 9) || b.updated.localeCompare(a.updated));

function whoOf(source) {
  if (source === 'you') return { label: 'you', cls: 'you', sub: '' };
  const m = /^session (\S+)(?: \((.*)\))?$/.exec(source);
  if (m) return { label: 'session', cls: 'session', sub: m[1] + (m[2] ? ' · ' + m[2] : '') };
  return { label: source || 'note', cls: 'bg', sub: '' };
}

// ---------------------------------------------------------------- api
async function api(path, body) {
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

function setStatusLine(ok, message) {
  $('led').classList.toggle('is-off', !ok);
  $('conn').textContent = ok ? 'local · live' : 'offline';
  const err = $('error');
  err.hidden = !message;
  err.textContent = message || '';
}

async function load() {
  try {
    const next = await api('api/state');
    const json = JSON.stringify(next);
    setStatusLine(true, '');
    if (json === lastJson) return;
    lastJson = json;
    data = next;
    render();
  } catch (e) {
    setStatusLine(false, 'brain serve not reachable: ' + e.message);
  }
}

async function act(path, body) {
  if (busy) return false;
  busy = true;
  try {
    const j = await api(path, body);
    data = j.state;
    lastJson = JSON.stringify(data);
    setStatusLine(true, '');
    render();
    return true;
  } catch (e) {
    setStatusLine(true, e.message);
    return false;
  } finally {
    busy = false;
  }
}

const taskPath = (slug, what) => 'api/tasks/' + encodeURIComponent(slug) + '/' + what;
const setStatus = (slug, status) => act(taskPath(slug, 'status'), { status });

// ---------------------------------------------------------------- render
function render() {
  const tasks = sortedTasks();
  if (!tasks.some((t) => t.slug === selected)) selected = tasks.length ? tasks[0].slug : null;
  const open = tasks.filter((t) => t.status !== 'done').length;
  const due = tasks.reduce((n, t) => n + t.followups.filter(isDue).length, 0);
  $('counts').textContent = open + ' open · ' + due + ' due';
  $('sub').textContent = (tasks.length - open) + '/' + tasks.length + ' done · ' + dayLabel(day(data.now)) +
    ' · refreshes every ' + POLL_MS / 1000 + 's';
  $('tasks').replaceChildren(...tasks.map(row));
  $('empty').hidden = tasks.length > 0;
  renderDetail(tasks.find((t) => t.slug === selected));
}

function row(t) {
  const done = t.status === 'done';
  const next = openFollowups(t)[0];
  const select = () => { selected = t.slug; history.replaceState(null, '', '#' + encodeURIComponent(t.slug)); render(); };
  return el('li', {
    class: 'row' + (t.slug === selected ? ' is-sel' : '') + (done ? ' is-done' : ''),
    tabindex: '0', 'aria-current': t.slug === selected ? 'true' : null,
    onclick: select,
    onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); select(); } },
  },
    el('span', { class: 'row-time' }, shortWhen(t.updated)),
    el('button', {
      class: 'check' + (done ? ' is-on' : ''), type: 'button',
      'aria-label': done ? 'Reopen ' + t.title : 'Mark ' + t.title + ' done',
      onclick: (e) => { e.stopPropagation(); setStatus(t.slug, done ? 'active' : 'done'); },
    }, done ? '✓' : ''),
    el('div', { class: 'row-main' },
      el('span', { class: 'row-title' }, t.title || t.slug),
      el('div', { class: 'meta' },
        el('span', { class: 'pill ' + t.status }, t.status),
        t.project && el('span', { class: 'proj' }, t.project),
        next && el('span', { class: isDue(next) ? 'due' : '' }, (isDue(next) ? 'due ' : 'next ') + shortWhen(next.due)),
        el('span', { title: 'tickets and sessions' }, '↳ ' + (t.tickets.length + t.sessions.length)),
        el('span', { title: 'log entries' }, '✎ ' + t.log.length))));
}

function renderDetail(t) {
  $('detail').hidden = !t;
  if (!t) return;
  const fus = [...openFollowups(t), ...t.followups.filter((f) => f.done)];
  const next = openFollowups(t)[0];
  $('detail-body').replaceChildren(
    el('div', { class: 'd-top' },
      el('span', { class: 'd-code' }, t.slug),
      el('span', { class: 'd-where' }, [t.project || 'no project', t.sessions.length + ' session' + (t.sessions.length === 1 ? '' : 's')].join(' · '))),
    el('h2', { class: 'd-title' }, t.title || t.slug),
    el('div', { class: 'statuses', role: 'group', 'aria-label': 'Status' },
      STATUSES.map((s) => el('button', {
        class: 'st', type: 'button', 'aria-pressed': String(t.status === s),
        onclick: () => { if (t.status !== s) setStatus(t.slug, s); },
      }, s))),
    el('dl', { class: 'facts' },
      el('div', {}, el('dt', {}, 'next check'), el('dd', {}, next ? shortWhen(next.due) : '—')),
      el('div', {}, el('dt', {}, 'updated'), el('dd', {}, shortWhen(t.updated))),
      el('div', {}, el('dt', {}, 'created'), el('dd', {}, t.created || '—'))),
    t.goal && el('p', { class: 'goal' }, t.goal),
    t.direction && el('div', { class: 'block' }, el('h3', { class: 'label' }, 'direction'), el('p', { class: 'prose' }, t.direction)),
    t.next && el('div', { class: 'next' }, el('span', { class: 'label' }, 'next'), el('p', {}, t.next)),
    el('div', { class: 'block' },
      el('h3', { class: 'label' }, 'follow-ups · ' + openFollowups(t).length + ' open'),
      fus.length ? el('ul', { class: 'checks' }, fus.map((f) => followup(f))) : el('span', { class: 'none' }, 'none')),
    el('div', { class: 'block' },
      el('h3', { class: 'label' }, 'links'),
      (t.tickets.length + t.sessions.length) ? el('div', { class: 'chips' },
        t.tickets.map(ticketChip),
        t.sessions.map((s) => el('span', { class: 'chip', title: s.id + (s.end ? ' · ended ' + s.end : '') },
          (s.folder || 'session') + ' · ' + s.short))) : el('span', { class: 'none' }, 'none linked')));
  renderUpdates(t);
}

function followup(f) {
  const due = isDue(f);
  return el('li', {},
    el('button', {
      class: 'ck' + (f.done ? ' is-done' : ''), type: 'button', disabled: f.done,
      'aria-label': f.done ? 'Done: ' + f.what : 'Tick off: ' + f.what,
      onclick: () => act('api/followups/' + encodeURIComponent(f.id) + '/done', { result: 'done (ticked on the page)' }),
    },
      el('span', { class: 'ck-box', 'aria-hidden': 'true' }, f.done ? '✓' : ''),
      el('span', {},
        el('span', { class: 'ck-text' }, f.what),
        el('span', { class: 'ck-due' + (due ? ' is-due' : '') }, (f.done ? 'was due ' : due ? 'due ' : 'check ') + shortWhen(f.due)))));
}

function ticketChip(t) {
  if (/^https?:\/\//i.test(t)) {
    const label = t.replace(/^https?:\/\/(www\.)?/i, '').replace(/#.*$/, '');
    return el('a', { class: 'chip', href: t, target: '_blank', rel: 'noopener noreferrer', title: t }, label);
  }
  return el('span', { class: 'chip' }, t);
}

function renderUpdates(t) {
  const items = [];
  let lastDay = '';
  for (const e of [...t.log].reverse()) {
    if (day(e.at) !== lastDay) {
      lastDay = day(e.at);
      items.push(el('li', { class: 'day' }, dayLabel(lastDay)));
    }
    const who = whoOf(e.source);
    items.push(el('li', { class: 'upd' },
      el('span', { class: 'upd-who' }, el('b', { class: who.cls }, who.label), who.sub && el('span', {}, who.sub), el('span', {}, hm(e.at))),
      el('span', { class: 'upd-text' }, e.text)));
  }
  $('updates').replaceChildren(...items);
}

// ---------------------------------------------------------------- wiring
$('composer').addEventListener('submit', async (e) => {
  e.preventDefault();
  const input = $('upd');
  const text = input.value.trim();
  if (!text || !selected) return;
  const button = e.target.querySelector('button');
  button.disabled = true;
  if (await act(taskPath(selected, 'log'), { text })) input.value = '';
  button.disabled = false;
  input.focus();
});
$('refresh').addEventListener('click', () => { lastJson = ''; load(); });
window.addEventListener('hashchange', () => { selected = decodeURIComponent(location.hash.slice(1)); if (data) render(); });
document.addEventListener('visibilitychange', () => { if (!document.hidden) load(); });

function tickClock() {
  $('clock').textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}
tickClock();
setInterval(tickClock, 15000);
setInterval(() => { if (!document.hidden) load(); }, POLL_MS);
load();
