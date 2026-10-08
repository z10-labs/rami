// Inbox: capture quick notes, accept or change where Rami suggests they go,
// tick off reminders that belong to no task, and clear the brain's messages.
import { $, el, store, act, hm, day, dayLabel, shortWhen, taskTitle, keepFocus } from './core.js';

const TEXT_MAX = 300;
const capPath = (id, what) => 'api/captures/' + encodeURIComponent(id) + '/' + what;
export const inboxCount = (data) => data.captures.length + data.notes.length + data.reminders.length;

export function mount(panel) {
  panel.replaceChildren(
    el('div', { class: 'panel-head' },
      el('span', { class: 'panel-num' }, '01'),
      el('h1', { id: 'view-heading' }, 'inbox'),
      el('span', { class: 'panel-sub', id: 'inbox-sub' }),
      el('span', { class: 'spacer' }),
      el('button', { class: 'btn-acc', type: 'button', id: 'process-all', onclick: processAll }, 'process all ↵')),
    el('div', { class: 'inbox' },
      el('form', { class: 'capture', onsubmit: capture },
        el('div', { class: 'capture-field' },
          el('span', { class: 'capture-mark', 'aria-hidden': 'true' }, '›'),
          el('label', { class: 'sr-only', for: 'cap' }, 'Capture a note'),
          el('input', { id: 'cap', autocomplete: 'off', maxlength: String(TEXT_MAX), placeholder: 'capture a task, idea or link…', oninput: countdown }),
          el('span', { class: 'capture-hint', id: 'cap-hint', 'aria-live': 'polite' }, 'enter to file')),
        el('button', { type: 'submit', class: 'capture-add' }, 'ADD')),
      el('ul', { class: 'caps', id: 'caps', 'aria-label': 'Unsorted captures' }),
      section('reminders-wrap', 'reminders · no task', 'reminders'),
      section('notes-wrap', 'from the brain', 'notes'),
      el('p', { class: 'empty', id: 'inbox-empty', hidden: true },
        el('span', { class: 'empty-big' }, 'inbox zero.'),
        el('span', { class: 'empty-sub' }, 'tasks went to today · notes went to their task logs'))));
  $('cap').focus();
}

function section(wrapId, title, listId) {
  return el('section', { class: 'notes', id: wrapId, 'aria-labelledby': listId + '-h' },
    el('h2', { class: 'label', id: listId + '-h' }, title),
    el('ul', { class: 'caps', id: listId }));
}

function countdown() {
  const left = TEXT_MAX - $('cap').value.length;
  $('cap-hint').textContent = left <= 50 ? left + ' left' : 'enter to file';
  $('cap-hint').classList.toggle('is-low', left <= 50);
}

async function capture(e) {
  e.preventDefault();
  const input = $('cap');
  const text = input.value.trim();
  if (!text) return;
  if (await act('api/captures', { text })) input.value = '';
  countdown();
  input.focus();
}

// Accept every capture. Unless the owner picked a destination, the server
// decides at accept time, so an earlier accept (say, a new task) is taken into
// account for the next one.
async function processAll() {
  const button = $('process-all');
  button.disabled = true;
  for (const c of [...store.data.captures]) {
    if (!(await act(capPath(c.id, 'accept'), picked.has(c.id) ? choiceBody(c) : {}))) break;
  }
  button.disabled = false;
}

const picked = new Map();
const choiceOf = (c) => picked.get(c.id) || c.kind + ':' + c.dest;
function choiceBody(c) {
  const [kind, dest] = choiceOf(c).split(':');
  return { kind, dest: dest || '' };
}

const whenLabel = (when) => (when ? dayLabel(day(when)) + ' ' + hm(when) : 'next workday');
const remindLabel = (dest, when) => 'reminder · ' + whenLabel(when) + ' · ' + (dest ? taskTitle(dest) : 'no task');
function choiceLabel(kind, dest, when) {
  if (kind === 'log') return 'log · ' + taskTitle(dest);
  if (kind === 'task') return 'new task · ' + dest;
  return remindLabel(dest, when);
}

function choiceSelect(c) {
  const open = store.data.tasks.filter((t) => t.status !== 'done');
  const opts = [
    ['task:' + (c.kind === 'task' ? c.dest : ''), c.kind === 'task' ? choiceLabel('task', c.dest) : 'new task'],
    ['remind:' + (c.kind === 'remind' ? c.dest : ''), remindLabel(c.kind === 'remind' ? c.dest : '', c.when)],
    ...open.map((t) => ['log:' + t.slug, 'log · ' + (t.title || t.slug)]),
  ];
  const current = choiceOf(c);
  if (!opts.some(([v]) => v === current)) opts.unshift([current, choiceLabel(...current.split(':'), c.when)]);
  const sel = el('select', {
    class: 'sugg sugg-' + current.split(':')[0], 'aria-label': 'Where "' + c.text + '" goes', 'data-fk': 'sel:' + c.id,
    onchange: (e) => { picked.set(c.id, e.target.value); e.target.className = 'sugg sugg-' + e.target.value.split(':')[0]; },
  }, opts.map(([v, label]) => el('option', { value: v }, '→ ' + label)));
  sel.value = current;
  return sel;
}

function capRow(c) {
  return el('li', { class: 'cap' },
    el('span', { class: 'cap-time' }, hm(c.at)),
    el('span', { class: 'cap-src' }, c.src),
    el('div', { class: 'cap-main' }, el('span', { class: 'cap-text' }, c.text), choiceSelect(c)),
    el('div', { class: 'cap-actions' },
      el('button', { class: 'mini', type: 'button', title: 'Accept', 'aria-label': 'Accept: ' + c.text, 'data-fk': 'ok:' + c.id,
        onclick: () => act(capPath(c.id, 'accept'), choiceBody(c)) }, '✓'),
      el('button', { class: 'mini ghost', type: 'button', title: 'Dismiss', 'aria-label': 'Dismiss: ' + c.text, 'data-fk': 'no:' + c.id,
        onclick: () => act(capPath(c.id, 'dismiss'), {}) }, '×')));
}

function reminderRow(f) {
  const due = f.due <= store.data.now;
  return el('li', { class: 'cap' },
    el('span', { class: 'cap-time' }, shortWhen(f.due)),
    el('span', { class: 'cap-src cap-remind' }, due ? 'DUE' : 'REMIND'),
    el('div', { class: 'cap-main' }, el('span', { class: 'cap-text' }, f.what)),
    el('div', { class: 'cap-actions' },
      el('button', { class: 'mini', type: 'button', title: 'Done', 'aria-label': 'Done: ' + f.what, 'data-fk': 'rem:' + f.id,
        onclick: () => act('api/followups/' + encodeURIComponent(f.id) + '/done', { result: 'done (ticked in the inbox)' }) }, '✓')));
}

function noteRow(n) {
  return el('li', { class: 'cap' },
    el('span', { class: 'cap-time' }, n.at ? shortWhen(n.at) : ''),
    el('span', { class: 'cap-src cap-brain' }, 'BRAIN'),
    el('div', { class: 'cap-main' },
      el('span', { class: 'cap-text' }, n.text),
      n.task && el('a', { class: 'sugg-link', href: '#today/' + encodeURIComponent(n.task) }, '↳ ' + taskTitle(n.task))),
    el('div', { class: 'cap-actions' },
      el('button', { class: 'mini', type: 'button', title: 'Mark read', 'aria-label': 'Mark read: ' + n.text, 'data-fk': 'note:' + n.id,
        onclick: () => act('api/notes/' + encodeURIComponent(n.id) + '/dismiss', {}) }, '✓')));
}

export function update() {
  keepFocus(render, '#cap');
}

function render() {
  const { captures, notes, reminders } = store.data;
  for (const id of picked.keys()) if (!captures.some((c) => c.id === id)) picked.delete(id);
  $('inbox-sub').textContent = captures.length + ' unsorted · ' + reminders.length + ' reminders · ' +
    notes.length + ' from the brain';
  $('process-all').hidden = captures.length === 0;
  $('caps').replaceChildren(...[...captures].reverse().map(capRow));
  $('reminders').replaceChildren(...reminders.map(reminderRow));
  $('reminders-wrap').hidden = reminders.length === 0;
  $('notes').replaceChildren(...[...notes].reverse().map(noteRow));
  $('notes-wrap').hidden = notes.length === 0;
  $('inbox-empty').hidden = inboxCount(store.data) > 0;
}
