// ⌘K palette: search tasks, log lines, decisions and archived tasks, or run a
// command (go to a view, capture the text, ask about it).
import { el, api, act } from './core.js';

const SEARCH_DELAY_MS = 150;
let views = [];
let onAsk = () => {};
let root = null;
let opener = null;
let items = [];
let active = 0;
let timer = null;
let seq = 0;
let mode = 'search';   // 'capture': quick capture from anywhere (key c)

export function init(viewList, askHandler) {
  views = viewList;
  onAsk = askHandler;
}

export const isOpen = () => !!root;

export function open(how) {
  if (root) return;
  mode = how === 'capture' ? 'capture' : 'search';
  opener = document.activeElement;
  const capturing = mode === 'capture';
  const input = el('input', {
    id: 'pal-q', autocomplete: 'off', role: 'combobox', 'aria-expanded': 'true', 'aria-controls': 'pal-list',
    'aria-label': capturing ? 'Capture a note' : 'Search or run a command', maxlength: capturing ? '300' : null,
    placeholder: capturing ? 'capture a task, idea or link… enter to file' : 'search tasks, logs, decisions… or type a command',
    oninput: () => (capturing ? show(input.value.trim(), []) : schedule(input.value)), onkeydown: keys,
  });
  root = el('div', { class: 'pal-backdrop', onclick: (e) => { if (e.target === root) close(); } },
    el('div', { class: 'pal', role: 'dialog', 'aria-modal': 'true', 'aria-label': capturing ? 'Quick capture' : 'Search' },
      el('div', { class: 'pal-head' }, el('span', { class: 'pal-mark', 'aria-hidden': 'true' }, capturing ? '›' : '⌘'), input,
        el('span', { class: 'pal-esc', 'aria-hidden': 'true' }, 'ESC')),
      el('ul', { class: 'pal-list', id: 'pal-list', role: 'listbox' })));
  document.body.append(root);
  input.focus();
  show('', []);
}

export function close() {
  if (!root) return;
  root.remove();
  root = null;
  clearTimeout(timer);
  pending = null;
  seq++;   // results of a search still in flight are dropped
  if (opener && opener.focus) opener.focus();
}

let pending = null;   // a search that is scheduled or running: { query, promise }

function schedule(q) {
  clearTimeout(timer);
  const query = q.trim();
  if (!query) { pending = null; return show('', []); }
  pending = { query, promise: null };
  timer = setTimeout(() => search(query), SEARCH_DELAY_MS);
}

function search(query) {
  clearTimeout(timer);
  const mine = ++seq;
  const promise = api('api/search?q=' + encodeURIComponent(query)).then(
    (r) => { if (mine === seq && root) show(query, r.results); },
    (e) => { if (mine === seq && root) show(query, [], e.message); });
  pending = { query, promise };
  return promise.then(() => { if (mine === seq) pending = null; });
}

function commands(q) {
  const lower = q.toLowerCase().trim();
  const go = views.filter((v) => !q || v.label.toLowerCase().includes(lower) || ('go ' + v.label.toLowerCase()).includes(lower))
    .map((v) => ({ type: 'go', label: 'Go to ' + v.label, hint: v.k, run: () => { location.hash = '#' + v.id; } }));
  if (!q) return go;
  return [
    ...go,
    { type: 'ask', label: 'Ask: ' + q, hint: 'answer from the brain', run: () => onAsk(q) },
    { type: 'capture', label: 'Capture: ' + q, hint: q.length > 300 ? 'first 300 characters' : 'to the inbox',
      run: () => act('api/captures', { text: q }).then((ok) => { if (ok && mode === 'search') location.hash = '#inbox'; }) },
  ];
}

function show(q, results, error) {
  const found = results.map((r) => ({
    type: r.type, label: r.label, hint: r.type === 'log' || r.type === 'decision' ? r.hint : r.slug,
    run: () => {
      if (r.type === 'archived') onAsk('What happened in the archived task ' + r.slug + '?');
      else location.hash = '#today/' + encodeURIComponent(r.slug);
    },
  }));
  // Text that names a screen ("system", "go inbox") puts that screen first.
  const cmds = commands(q);
  const named = q && cmds.filter((c) => c.type === 'go' && c.label.toLowerCase().replace('go to ', '').startsWith(q.toLowerCase().replace(/^go( to)? /, '')));
  if (mode === 'capture') items = q ? cmds.filter((c) => c.type === 'capture') : [];
  else items = q ? (named.length ? [...named, ...found, ...cmds.filter((c) => !named.includes(c))] : [...found, ...cmds]) : cmds;
  active = 0;
  const list = root.querySelector('#pal-list');
  list.replaceChildren(
    ...(error ? [el('li', { class: 'pal-none' }, 'search failed: ' + error)] : []),
    ...(mode === 'search' && q && !found.length && !error ? [el('li', { class: 'pal-none' }, 'no match · enter to ask, or capture it')] : []),
    ...(mode === 'capture' && !q ? [el('li', { class: 'pal-none' }, 'goes to the inbox; Rami suggests where it belongs')] : []),
    ...items.map((it, i) => el('li', {
      class: 'pal-item', role: 'option', id: 'pal-' + i, 'aria-selected': String(i === active),
      onclick: () => run(i), onmousemove: () => highlight(i),
    }, el('span', { class: 'pal-type' }, it.type), el('span', { class: 'pal-label' }, it.label),
      el('span', { class: 'pal-hint' }, it.hint || ''))));
  if (mode === 'search' && q && !found.length && !error) active = items.findIndex((it) => it.type === 'ask');
  highlight(active);
}

function highlight(i) {
  if (!root || !items.length) return;
  active = (i + items.length) % items.length;
  root.querySelectorAll('.pal-item').forEach((n, j) => n.setAttribute('aria-selected', String(j === active)));
  const cur = root.querySelector('#pal-' + active);
  root.querySelector('#pal-q').setAttribute('aria-activedescendant', cur ? cur.id : '');
  if (cur) cur.scrollIntoView({ block: 'nearest' });
}

function run(i) {
  const it = items[i];
  if (!it) return;
  close();
  it.run();
}

function keys(e) {
  if (e.key === 'Escape') { e.preventDefault(); close(); }
  else if (e.key === 'ArrowDown') { e.preventDefault(); highlight(active + 1); }
  else if (e.key === 'ArrowUp') { e.preventDefault(); highlight(active - 1); }
  else if (e.key === 'Enter') {
    e.preventDefault();
    if (mode === 'capture') {   // file exactly what is in the box; nothing if it is empty
      const text = e.target.value.trim();
      close();
      if (text) act('api/captures', { text });
      return;
    }
    // Enter before the search came back: wait for it, then run the top item.
    if (pending) (pending.promise || search(pending.query)).then(() => run(active));
    else run(active);
  }
  else if (e.key === 'Tab') { e.preventDefault(); } // keep focus in the dialog
}
