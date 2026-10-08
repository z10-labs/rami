// Graph: projects, tasks and decisions, and how they connect.
// Positions come from a small deterministic force layout (same data, same picture).
import { $, el, api, store, panelHead, keepFocus } from './core.js';
import { askNow } from './ask.js';

const ITERATIONS = 300;
const PAD = 9;            // keep nodes this far (in %) from the edges
const NS = 'http://www.w3.org/2000/svg';
let data = null;
let pos = new Map();
let picked = null;
let lastKey = '';

export async function mount(panel) {
  panel.replaceChildren(
    panelHead('04', 'graph', 'graph-sub'),
    el('div', { class: 'graph' },
      el('div', { class: 'graph-canvas', id: 'graph-canvas' },
        document.createElementNS(NS, 'svg')),
      el('aside', { class: 'graph-side', id: 'graph-side', 'aria-live': 'polite' })));
  const svg = $('graph-canvas').querySelector('svg');
  svg.setAttribute('viewBox', '0 0 100 100');
  svg.setAttribute('preserveAspectRatio', 'none');
  svg.setAttribute('aria-hidden', 'true');
  await refresh();
}

export async function update() {
  if ($('graph-canvas')) await refresh();
}

async function refresh() {
  try {
    data = await api('api/graph');
  } catch (e) {
    $('graph-sub').textContent = 'graph unavailable: ' + e.message;
    return;
  }
  const key = data.nodes.map((n) => n.id).join('|') + '#' + data.edges.map((e) => e.a + e.b).join('|');
  if (key !== lastKey) {
    lastKey = key;
    pos = layout(data.nodes, data.edges);
  }
  if (!data.nodes.some((n) => n.id === picked)) picked = (data.nodes.find((n) => n.kind === 'project') || data.nodes[0] || {}).id || null;
  keepFocus(render);
}

function hash(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
  return (h >>> 0) / 4294967295;
}

function layout(nodes, edges) {
  const p = new Map(nodes.map((n, i) => {
    const a = (i / Math.max(1, nodes.length)) * Math.PI * 2 + hash(n.id);
    const r = n.kind === 'project' ? 12 : 30;
    return [n.id, { x: 50 + r * Math.cos(a), y: 50 + r * Math.sin(a), vx: 0, vy: 0 }];
  }));
  const links = edges.filter((e) => p.has(e.a) && p.has(e.b));
  for (let it = 0; it < ITERATIONS; it++) {
    const cool = 1 - it / ITERATIONS;
    for (const a of p.values()) {
      for (const b of p.values()) {
        if (a === b) continue;
        const dx = a.x - b.x, dy = a.y - b.y, d2 = Math.max(dx * dx + dy * dy, 1);
        a.vx += (dx / d2) * 6; a.vy += (dy / d2) * 6;
      }
      a.vx += (50 - a.x) * 0.02; a.vy += (50 - a.y) * 0.02;
    }
    for (const e of links) {
      const a = p.get(e.a), b = p.get(e.b);
      const want = e.kind === 'project' ? 20 : 16;
      const dx = b.x - a.x, dy = b.y - a.y, d = Math.max(Math.hypot(dx, dy), 0.01);
      const f = ((d - want) / d) * 0.08;
      a.vx += dx * f; a.vy += dy * f; b.vx -= dx * f; b.vy -= dy * f;
    }
    for (const a of p.values()) {
      a.x = Math.min(100 - PAD, Math.max(PAD, a.x + a.vx * cool));
      a.y = Math.min(100 - PAD, Math.max(PAD, a.y + a.vy * cool));
      a.vx *= 0.5; a.vy *= 0.5;
    }
  }
  // Stretch the result to use the whole canvas.
  const xs = [...p.values()].map((a) => a.x), ys = [...p.values()].map((a) => a.y);
  const fit = (v, lo, hi) => (hi - lo < 1 ? 50 : PAD + ((v - lo) / (hi - lo)) * (100 - 2 * PAD));
  const [x0, x1, y0, y1] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
  for (const a of p.values()) { a.x = fit(a.x, x0, x1); a.y = fit(a.y, y0, y1); }
  return p;
}

const neighbours = (id) => data.edges.filter((e) => e.a === id || e.b === id)
  .map((e) => ({ id: e.a === id ? e.b : e.a, kind: e.kind }));
const byId = (id) => data.nodes.find((n) => n.id === id);

function size(n) {
  if (n.kind === 'project') return 16 + 4 * Math.min(6, neighbours(n.id).length);
  if (n.kind === 'task') return 12 + Math.min(10, Math.round((n.log || 0) / 3));
  return 10;
}

function render() {
  const projects = data.nodes.filter((n) => n.kind === 'project').length;
  const tasks = data.nodes.filter((n) => n.kind === 'task').length;
  $('graph-sub').textContent = projects + ' projects · ' + tasks + ' open tasks · linked by repo, shared sessions and decisions';
  const svg = $('graph-canvas').querySelector('svg');
  const near = new Set(picked ? [picked, ...neighbours(picked).map((x) => x.id)] : []);
  svg.replaceChildren(...data.edges.filter((e) => pos.has(e.a) && pos.has(e.b)).map((e) => {
    const a = pos.get(e.a), b = pos.get(e.b);
    const line = document.createElementNS(NS, 'line');
    for (const [k, v] of [['x1', a.x], ['y1', a.y], ['x2', b.x], ['y2', b.y]]) line.setAttribute(k, v.toFixed(2));
    line.setAttribute('class', 'edge edge-' + e.kind + (near.has(e.a) && near.has(e.b) && (e.a === picked || e.b === picked) ? ' is-hot' : ''));
    line.setAttribute('vector-effect', 'non-scaling-stroke');
    return line;
  }));
  const canvas = $('graph-canvas');
  canvas.classList.toggle('is-narrow', canvas.clientWidth < 600);
  canvas.querySelectorAll('.gnode').forEach((n) => n.remove());
  for (const n of data.nodes) {
    const p = pos.get(n.id);
    const s = size(n);
    canvas.append(el('button', {
      class: 'gnode gnode-' + n.kind + (n.status ? ' st-' + n.status : '') + (n.id === picked ? ' is-picked' : '') +
        (picked && !near.has(n.id) ? ' is-far' : '') + (p.x < 25 ? ' gnode-l' : p.x > 75 ? ' gnode-r' : ''),
      type: 'button', 'data-fk': 'g:' + n.id, 'aria-pressed': String(n.id === picked), title: n.label,
      'aria-label': n.kind + ': ' + n.label, style: { left: p.x + '%', top: p.y + '%' },
      onclick: () => { picked = n.id; keepFocus(render); },
    }, el('span', { class: 'gdot', style: { width: s + 'px', height: s + 'px' } }),
      el('span', { class: 'glabel' }, n.label)));
  }
  renderSide();
}

function focusNode(id) {
  const btn = document.querySelector('[data-fk="g:' + CSS.escape(id) + '"]');
  if (btn) btn.focus({ preventScroll: true });
}

function describe(n) {
  if (n.kind === 'task') {
    const t = store.data && store.data.tasks.find((x) => x.slug === n.slug);
    return t ? (t.next ? 'Next: ' + t.next : t.goal || '') : '';
  }
  if (n.kind === 'decision') return n.date + ' · ' + n.decision;
  const k = neighbours(n.id).filter((x) => x.kind === 'project').length;
  const tasks = k + ' open task' + (k === 1 ? '' : 's');
  return n.label === 'unfiled' ? tasks + ' with no linked session yet.' : tasks + ' in this repo.';
}

function renderSide() {
  const n = byId(picked);
  if (!n) { $('graph-side').replaceChildren(el('p', { class: 'none' }, 'nothing to show yet.')); return; }
  const links = neighbours(n.id).map((x) => byId(x.id)).filter(Boolean);
  const question = n.kind === 'task' ? 'Where are we on ' + n.label + '?' :
    n.kind === 'project' ? 'What is going on in the ' + n.label + ' project?' : 'Why did we decide: ' + n.label + '?';
  $('graph-side').replaceChildren(...[
    el('span', { class: 'label gside-kind' }, n.kind + (n.status ? ' · ' + n.status : '')),
    el('h2', { class: 'gside-title' }, n.label),
    el('p', { class: 'goal' }, describe(n)),
    el('h3', { class: 'label' }, 'linked'),
    el('div', { class: 'glinks' }, links.length ? links.map((m) => el('button', {
      class: 'glink', type: 'button', 'data-fk': 'gl:' + m.id,
      onclick: () => { picked = m.id; render(); focusNode(m.id); },
    }, '→ ' + m.label)) : el('span', { class: 'none' }, 'none')),
    el('span', { class: 'spacer' }),
    n.kind === 'task' ? el('a', { class: 'btn-key gside-open', href: '#today/' + encodeURIComponent(n.slug) }, 'OPEN IN TODAY') : null,
    el('button', { class: 'btn-acc', type: 'button', onclick: () => askNow(question) }, 'ASK ABOUT THIS'),
  ].filter(Boolean));
}

