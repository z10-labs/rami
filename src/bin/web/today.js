// Today: open tasks (and those finished today) with a detail pane.
import { $, el, store, act, taskPath, shortWhen, day, hm, dayLabel, panelHead, keepFocus, reducedMotion, POLL_MS } from './core.js';

const STATUSES = ['active', 'waiting', 'blocked', 'done'];
const ORDER = { blocked: 0, active: 1, waiting: 2, done: 3 };
let selected = null;
let project = null;   // "#today/@name" shows one project's tasks
let explicit = false; // the selection came from a link (#today/<slug>)

const openFollowups = (t) => t.followups.filter((f) => !f.done).sort((a, b) => a.due.localeCompare(b.due));
const isDue = (f) => !f.done && f.due <= store.data.now;
const setStatus = (slug, status) => act(taskPath(slug, 'status'), { status });
export const dueCount = (data) => data.tasks.reduce((n, t) => n + t.followups.filter((f) => !f.done && f.due <= data.now).length, 0);

function whoOf(source) {
  if (source === 'you') return { label: 'you', cls: 'you', sub: '' };
  const m = /^session (\S+)(?: \((.*)\))?$/.exec(source);
  if (m) return { label: 'session', cls: 'session', sub: m[1] + (m[2] ? ' · ' + m[2] : '') };
  return { label: source || 'note', cls: 'bg', sub: '' };
}

export function mount(panel, param) {
  if (param && param.startsWith('@')) project = param.slice(1) || null;
  else if (param) { selected = param; explicit = true; }
  panel.replaceChildren(
    panelHead('02', 'today', 'sub'),
    el('div', { class: 'today' },
      el('section', { class: 'list', 'aria-label': 'Tasks' },
        el('ul', { id: 'tasks', class: 'rows' }),
        el('p', { id: 'empty', class: 'empty', hidden: true },
          el('span', { class: 'empty-big' }, 'nothing open.'),
          el('span', { class: 'empty-sub' }, 'tasks appear here when a claude session starts real work'))),
      el('section', { class: 'detail', id: 'detail', 'aria-label': 'Task detail', hidden: true },
        el('div', { id: 'detail-body' }),
        el('div', { class: 'block' },
          el('h2', { class: 'label' }, 'updates'),
          el('form', { class: 'composer', id: 'composer', onsubmit: postUpdate },
            el('label', { class: 'sr-only', for: 'upd' }, 'Post an update'),
            el('input', { id: 'upd', name: 'upd', autocomplete: 'off', maxlength: '300', placeholder: 'post an update…' }),
            el('button', { type: 'submit', class: 'btn-key' }, 'POST')),
          el('ol', { class: 'updates', id: 'updates' })))));
}

async function postUpdate(e) {
  e.preventDefault();
  const input = $('upd');
  const text = input.value.trim();
  if (!text || !selected) return;
  const button = e.target.querySelector('button');
  button.disabled = true;
  if (await act(taskPath(selected, 'log'), { text })) input.value = '';
  button.disabled = false;
  input.focus();
}

const inProject = (t) => !project || (t.project || 'unfiled') === project;
const sortedTasks = () => store.data.tasks.filter(inProject).sort((a, b) =>
  (ORDER[a.status] ?? 9) - (ORDER[b.status] ?? 9) || b.updated.localeCompare(a.updated));

export function update() {
  keepFocus(render, '#upd');
}

function render() {
  if (explicit) {
    explicit = false;
    const t = store.data.tasks.find((x) => x.slug === selected);
    if (t && !inProject(t)) project = null;
  }
  const tasks = sortedTasks();
  if (!tasks.some((t) => t.slug === selected)) {
    selected = tasks.length ? tasks[0].slug : null;
    // A link to a task that is gone: show the URL of what is actually shown.
    if (location.hash.startsWith('#today')) history.replaceState(null, '', selected ? '#today/' + encodeURIComponent(selected) : '#today');
  }
  const open = tasks.filter((t) => t.status !== 'done').length;
  $('sub').replaceChildren(
    project ? el('a', { class: 'filter-chip', href: '#today/@', 'aria-label': 'Show all projects' }, project + ' ×') : '',
    (tasks.length - open) + '/' + tasks.length + ' done · ' + dayLabel(day(store.data.now)) +
    ' · refreshes every ' + POLL_MS / 1000 + 's');
  $('tasks').replaceChildren(...tasks.map(row));
  $('empty').hidden = tasks.length > 0;
  renderDetail(tasks.find((t) => t.slug === selected));
}

function select(slug) {
  selected = slug;
  history.replaceState(null, '', '#today/' + encodeURIComponent(slug));
  update();
  // On narrow screens the detail sits below the list: bring it into view.
  if (window.matchMedia('(max-width: 980px)').matches) {
    $('detail').scrollIntoView({ block: 'start', behavior: reducedMotion() ? 'auto' : 'smooth' });
  }
}

function row(t) {
  const done = t.status === 'done';
  const next = openFollowups(t)[0];
  return el('li', {
    class: 'row' + (t.slug === selected ? ' is-sel' : '') + (done ? ' is-done' : ''),
    tabindex: '0', 'aria-current': t.slug === selected ? 'true' : null, 'data-fk': 'row:' + t.slug,
    onclick: () => select(t.slug),
    onkeydown: (e) => {
      if (e.target !== e.currentTarget) return;   // keys on the check button are the button's
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); select(t.slug); }
    },
  },
    el('span', { class: 'row-time' }, shortWhen(t.updated)),
    el('button', {
      class: 'check' + (done ? ' is-on' : ''), type: 'button', 'data-fk': 'check:' + t.slug,
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
        class: 'st', type: 'button', 'aria-pressed': String(t.status === s), 'data-fk': 'st:' + s,
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
      fus.length ? el('ul', { class: 'checks' }, fus.map(followup)) : el('span', { class: 'none' }, 'none')),
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
      class: 'ck' + (f.done ? ' is-done' : ''), type: 'button', disabled: f.done, 'data-fk': 'fu:' + f.id,
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
