// Projects: tasks grouped by repository, in columns by how they are doing.
// A card opens Today filtered to that project.
import { $, el, store, panelHead, shortWhen, keepFocus } from './core.js';

const COLUMNS = [
  ['blocked', 'blocked'], ['active', 'active'], ['waiting', 'waiting'], ['quiet', 'quiet · nothing open'],
];
const SEGMENTS = 10;

export function mount(panel) {
  panel.replaceChildren(
    panelHead('05', 'projects', 'proj-sub'),
    el('div', { class: 'proj-grid', id: 'proj-grid' }));
}

// Ten segments split by task status, in the order work moves.
function segments(p) {
  const parts = [['done', p.done], ['active', p.active], ['waiting', p.waiting], ['blocked', p.blocked]];
  const out = [];
  let used = 0;
  parts.forEach(([cls, n], i) => {
    let k = p.total ? Math.round((n / p.total) * SEGMENTS) : 0;
    if (n && !k) k = 1;
    if (i === parts.length - 1) k = Math.max(0, Math.min(k, SEGMENTS - used));
    for (let j = 0; j < k && used < SEGMENTS; j++, used++) out.push(el('span', { class: 'seg seg-' + cls }));
  });
  while (used++ < SEGMENTS) out.push(el('span', { class: 'seg' }));
  return out;
}

function card(p) {
  const open = p.total - p.done;
  const name = p.name === 'unfiled' ? 'unfiled' : p.name;
  return el('a', {
    class: 'pcard', href: '#today/@' + encodeURIComponent(p.name), 'data-fk': 'proj:' + p.name,
    'aria-label': name + ': ' + open + ' open of ' + p.total + ' tasks. Open in Today.',
  },
    el('span', { class: 'pcard-top' }, el('span', { class: 'pcard-id' + (p.name === 'unfiled' ? ' is-unfiled' : '') },
      p.name === 'unfiled' ? 'unfiled · no session' : name),
      el('span', { class: 'pcard-n' }, p.total + ' task' + (p.total === 1 ? '' : 's'))),
    el('span', { class: 'pcard-title' }, open ? open + ' open' : 'all done'),
    el('span', { class: 'pcard-meta' }, [
      p.blocked && p.blocked + ' blocked', p.waiting && p.waiting + ' waiting', p.done && p.done + ' done',
      'upd ' + shortWhen(p.updated)].filter(Boolean).join(' · ')),
    el('span', { class: 'segs', 'aria-hidden': 'true' }, segments(p)));
}

export function update() {
  keepFocus(() => {
    const ps = store.data.projects;
    $('proj-sub').textContent = ps.length + ' projects · grouped by the repo each task’s sessions ran in';
    $('proj-grid').replaceChildren(...COLUMNS.map(([state, label]) => {
      const cards = ps.filter((p) => p.state === state);
      return el('section', { class: 'pcol', 'aria-label': label },
        el('h2', { class: 'pcol-head' }, el('span', {}, label), el('span', { class: 'pcol-n' }, String(cards.length))),
        ...cards.map(card),
        cards.length ? null : el('span', { class: 'none' }, 'none'));
    }));
  });
}
