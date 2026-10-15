// Graph: projects, tasks and decisions, and how they connect.
// Live force layout (graph-sim.js) drawn in screen pixels. Drag a node to move
// it, drag the background to pan, scroll or pinch to zoom, +/-/0 on the canvas.
// Labels that would collide are hidden; zoom in or hover a node to see them.
import { $, el, api, store, panelHead, keepFocus, reducedMotion } from './core.js';
import { askNow } from './ask.js';
import { createSim, syncSim, tick, heat, settle } from './graph-sim.js';

const NS = 'http://www.w3.org/2000/svg';
const ZOOM_MIN = 0.25, ZOOM_MAX = 4, ZOOM_STEP = 1.3;
const DRAG_SLOP = 4;          // px before a press on a node counts as a drag
const FIT_PAD = 48;
const LABEL_GAP = 6;          // px between a dot and its label
const LABEL_H = 16;

let data = null;
let lastJson = '';
let picked = null;
let hovered = null;
let sim = createSim();
let view = { k: 1, x: 0, y: 0 };
let userView = false;      // the owner panned or zoomed: stop auto-fitting
let frame = 0;
let tween = null;
let dom = null;               // { canvas, svg, layer, lines: [[edge, line]], nodes: Map id -> {btn, label, w} }
let resize = null;

export function mount(panel) {
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('aria-hidden', 'true');
  const tool = (label, text, fn) => el('button', { class: 'gtool', type: 'button', 'aria-label': label, title: label, onclick: fn }, text);
  panel.replaceChildren(
    panelHead('04', 'graph', 'graph-sub'),
    el('div', { class: 'graph' },
      el('div', { class: 'graph-canvas', id: 'graph-canvas', tabindex: '0', 'aria-label': 'Graph. Plus and minus zoom, 0 fits.' },
        svg,
        el('div', { class: 'graph-layer', id: 'graph-layer' }),
        el('div', { class: 'graph-tools' },
          tool('Zoom in', '+', () => zoomBy(ZOOM_STEP)),
          tool('Zoom out', '−', () => zoomBy(1 / ZOOM_STEP)),
          tool('Fit to view', 'FIT', () => fit(true))),
        el('p', { class: 'graph-hint' }, 'drag · scroll or pinch to zoom · double-click to fit')),
      el('aside', { class: 'graph-side', id: 'graph-side', 'aria-live': 'polite' })));
  sim = createSim();
  dom = null; lastJson = ''; userView = false; hovered = null;
  const canvas = $('graph-canvas');
  bindGestures(canvas);
  resize = new ResizeObserver(() => { if (!userView) fit(false); draw(); });
  resize.observe(canvas);
  refresh();
}

export function unmount() {
  cancelAnimationFrame(frame);
  frame = 0;
  if (resize) resize.disconnect();
  resize = null;
  dom = null;
}

export async function update() {
  if ($('graph-canvas')) await refresh();
}

async function refresh() {
  let next;
  try {
    next = await api('api/graph');
  } catch (e) {
    $('graph-sub').textContent = 'graph unavailable: ' + e.message;
    return;
  }
  const json = JSON.stringify(next);
  if (json === lastJson || !$('graph-canvas')) return;
  lastJson = json;
  data = next;
  const first = syncSim(sim, data.nodes, data.edges, (n) => size(n) / 2);
  if (!data.nodes.some((n) => n.id === picked)) picked = (data.nodes.find((n) => n.kind === 'project') || data.nodes[0] || {}).id || null;
  keepFocus(build);
  if (first || reducedMotion()) {
    settle(sim);
    if (first || !userView) fit(false);
    draw();
  } else {
    heat(sim, 0.3);
    run();
  }
}

// ---------------------------------------------------------------- data helpers
const neighbours = (id) => data.edges.filter((e) => e.a === id || e.b === id)
  .map((e) => ({ id: e.a === id ? e.b : e.a, kind: e.kind }));
const byId = (id) => data.nodes.find((n) => n.id === id);

function size(n) {
  if (n.kind === 'project') return 18 + 4 * Math.min(6, neighbours(n.id).length);
  if (n.kind === 'task') return 12 + Math.min(10, Math.round((n.work || 0) / 3));
  return 10;
}

// The node whose neighbourhood is lit: the hovered one, else the picked one.
function focusSet() {
  const id = hovered || picked;
  return { id, near: new Set(id ? [id, ...neighbours(id).map((x) => x.id)] : []) };
}

// ---------------------------------------------------------------- DOM
function build() {
  const projects = data.nodes.filter((n) => n.kind === 'project').length;
  const tasks = data.nodes.filter((n) => n.kind === 'task').length;
  $('graph-sub').textContent = projects + ' projects · ' + tasks + ' open tasks · linked by repo, shared sessions and decisions';
  const svg = $('graph-canvas').querySelector('svg');
  const lines = sim.links.map((e) => {
    const line = document.createElementNS(NS, 'line');
    line.setAttribute('class', 'edge edge-' + e.kind);
    return [e, line];
  });
  svg.replaceChildren(...lines.map(([, l]) => l));
  const nodes = new Map();
  $('graph-layer').replaceChildren(...data.nodes.map((n) => {
    const s = size(n);
    const label = el('span', { class: 'glabel' }, n.label);
    const btn = el('button', {
      class: 'gnode gnode-' + n.kind + (n.status ? ' st-' + n.status : ''),
      type: 'button', 'data-fk': 'g:' + n.id, 'data-id': n.id, title: n.label,
      'aria-label': n.kind + ': ' + n.label,
      onclick: () => pick(n.id, false),
      onpointerenter: () => hover(n.id), onpointerleave: () => hover(null),
      onfocus: () => hover(n.id), onblur: () => hover(null),
    }, el('span', { class: 'gdot', style: { width: s + 'px', height: s + 'px' } }), label);
    nodes.set(n.id, { btn, label, r: s / 2, w: 0 });
    return btn;
  }));
  for (const v of nodes.values()) v.w = v.label.offsetWidth;
  dom = { canvas: $('graph-canvas'), lines, nodes };
  renderSide();
}

function draw() {
  if (!dom || !data) return;
  const W = dom.canvas.clientWidth, H = dom.canvas.clientHeight;
  const sx = (b) => b.x * view.k + view.x, sy = (b) => b.y * view.k + view.y;
  const { id: lit, near } = focusSet();
  for (const [e, line] of dom.lines) {
    const a = sim.bodies.get(e.a), b = sim.bodies.get(e.b);
    line.setAttribute('x1', sx(a).toFixed(1)); line.setAttribute('y1', sy(a).toFixed(1));
    line.setAttribute('x2', sx(b).toFixed(1)); line.setAttribute('y2', sy(b).toFixed(1));
    line.classList.toggle('is-hot', e.a === lit || e.b === lit);
    line.classList.toggle('is-far', !!lit && e.a !== lit && e.b !== lit);
  }
  for (const n of data.nodes) {
    const v = dom.nodes.get(n.id), b = sim.bodies.get(n.id);
    v.x = sx(b); v.y = sy(b);
    v.btn.style.setProperty('transform', 'translate(' + v.x.toFixed(1) + 'px,' + v.y.toFixed(1) + 'px)');
    v.btn.classList.toggle('is-picked', n.id === picked);
    v.btn.classList.toggle('is-far', !!lit && !near.has(n.id));
    v.btn.setAttribute('aria-pressed', String(n.id === picked));
  }
  placeLabels(W, H, lit, near);
}

// Greedy label placement: most important first; each label goes below its dot,
// else above, else is hidden. Labels are nudged inside the canvas edges.
function placeLabels(W, H, lit, near) {
  const rank = (n) => (n.id === picked || n.id === lit ? 0 : near.has(n.id) ? 1 : n.kind === 'project' ? 2 : n.kind === 'task' ? 3 : 4);
  const order = [...data.nodes].sort((a, b) => rank(a) - rank(b) || size(b) - size(a));
  const taken = [...dom.nodes.values()].map((v) => ({ x0: v.x - v.r, x1: v.x + v.r, y0: v.y - v.r, y1: v.y + v.r }));
  const hits = (r) => taken.some((t) => r.x0 < t.x1 && r.x1 > t.x0 && r.y0 < t.y1 && r.y1 > t.y0);
  for (const n of order) {
    const v = dom.nodes.get(n.id);
    const dx = Math.max(4 - (v.x - v.w / 2), Math.min(0, W - 4 - (v.x + v.w / 2)));
    const x0 = v.x + dx - v.w / 2, x1 = x0 + v.w;
    const below = { x0, x1, y0: v.y + v.r + LABEL_GAP, y1: v.y + v.r + LABEL_GAP + LABEL_H };
    const above = { x0, x1, y0: v.y - v.r - LABEL_GAP - LABEL_H, y1: v.y - v.r - LABEL_GAP };
    const must = rank(n) === 0;
    const spot = !hits(below) ? 'below' : !hits(above) ? 'above' : must ? 'below' : null;
    const onScreen = v.x > -v.w && v.x < W + v.w && v.y > -40 && v.y < H + 40;
    v.label.classList.toggle('is-hidden', !spot || !onScreen);
    v.label.classList.toggle('is-up', spot === 'above');
    v.label.style.setProperty('--dx', dx.toFixed(1) + 'px');
    v.label.style.setProperty('--r', v.r + 'px');
    if (spot && onScreen) taken.push(spot === 'below' ? below : above);
  }
}

// ---------------------------------------------------------------- motion
function run() {
  if (frame) return;
  const step = () => {
    let busy = sim.alpha > 0 && tick(sim);
    if (!busy) sim.alpha = 0;
    if (tween) busy = stepTween() || busy;
    draw();
    frame = busy && dom ? requestAnimationFrame(step) : 0;
  };
  frame = requestAnimationFrame(step);
}

function setView(next, animate) {
  if (!animate || reducedMotion()) { view = next; tween = null; draw(); return; }
  tween = { from: view, to: next, t0: performance.now() };
  run();
}

function stepTween() {
  const t = Math.min(1, (performance.now() - tween.t0) / 320);
  const e = 1 - Math.pow(1 - t, 3);
  const { from, to } = tween;
  view = { k: from.k + (to.k - from.k) * e, x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e };
  if (t >= 1) tween = null;
  return t < 1;
}

function fit(animate) {
  if (animate) userView = false;
  if (!dom || !data || !data.nodes.length) return;
  const W = dom.canvas.clientWidth, H = dom.canvas.clientHeight;
  if (!W || !H) return;
  const bs = [...sim.bodies.values()];
  const x0 = Math.min(...bs.map((b) => b.x)) - 60, x1 = Math.max(...bs.map((b) => b.x)) + 60;
  const y0 = Math.min(...bs.map((b) => b.y)) - 30, y1 = Math.max(...bs.map((b) => b.y)) + 40;
  const k = clampK(Math.min((W - 2 * FIT_PAD) / (x1 - x0), (H - 2 * FIT_PAD) / (y1 - y0), 1.4));
  setView({ k, x: W / 2 - k * (x0 + x1) / 2, y: H / 2 - k * (y0 + y1) / 2 }, animate);
}

const clampK = (k) => Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, k));

function zoomAt(px, py, factor, animate) {
  userView = true;
  const k = clampK(view.k * factor);
  const f = k / view.k;
  setView({ k, x: px - (px - view.x) * f, y: py - (py - view.y) * f }, animate);
}

function zoomBy(factor) {
  zoomAt(dom.canvas.clientWidth / 2, dom.canvas.clientHeight / 2, factor, true);
}

function centerOn(id) {
  const b = sim.bodies.get(id);
  if (!b) return;
  const W = dom.canvas.clientWidth, H = dom.canvas.clientHeight;
  const x = b.x * view.k + view.x, y = b.y * view.k + view.y;
  if (x > 60 && x < W - 60 && y > 60 && y < H - 60) return;
  setView({ k: view.k, x: W / 2 - b.x * view.k, y: H / 2 - b.y * view.k }, true);
}

// ---------------------------------------------------------------- interaction
function pick(id, reveal) {
  picked = id;
  hovered = null;
  draw();
  renderSide();
  if (reveal) centerOn(id);
}

function hover(id) {
  if (hovered === id) return;
  hovered = id;
  draw();
}

function bindGestures(canvas) {
  const points = new Map();     // pointerId -> {x, y}
  let drag = null;              // {kind: 'node'|'pan'|'pinch', ...}
  let suppressClick = false;
  const local = (e) => { const r = canvas.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };
  const world = (p) => ({ x: (p.x - view.x) / view.k, y: (p.y - view.y) / view.k });

  canvas.addEventListener('pointerdown', (e) => {
    if (e.button !== 0 || e.target.closest('.graph-tools')) return;
    const p = local(e);
    points.set(e.pointerId, p);
    tween = null;
    if (points.size === 2) {
      const [a, b] = [...points.values()];
      releaseNode(drag);
      for (const id of points.keys()) canvas.setPointerCapture(id);
      drag = { kind: 'pinch', d: Math.hypot(a.x - b.x, a.y - b.y) };
      return;
    }
    const node = e.target.closest('.gnode');
    drag = node ? { kind: 'node', id: node.dataset.id, start: p, moved: false } : { kind: 'pan', last: p, start: p, moved: false };
  });

  canvas.addEventListener('pointermove', (e) => {
    if (!points.has(e.pointerId) || !drag) return;
    const p = local(e);
    points.set(e.pointerId, p);
    if (drag.kind === 'pinch') {
      const [a, b] = [...points.values()];
      const d = Math.hypot(a.x - b.x, a.y - b.y);
      zoomAt((a.x + b.x) / 2, (a.y + b.y) / 2, d / drag.d, false);
      drag.d = d;
      return;
    }
    if (!drag.moved && Math.hypot(p.x - drag.start.x, p.y - drag.start.y) < DRAG_SLOP) return;
    // Capture only once it is a drag: capturing on press would send the
    // click to the canvas instead of the node button under the pointer.
    if (!drag.moved) canvas.setPointerCapture(e.pointerId);
    drag.moved = true;
    canvas.classList.add('is-dragging');
    if (drag.kind === 'pan') {
      userView = true;
      setView({ ...view, x: view.x + p.x - drag.last.x, y: view.y + p.y - drag.last.y }, false);
      drag.last = p;
      return;
    }
    const b = sim.bodies.get(drag.id), w = world(p);
    if (!b) return;
    b.fx = w.x; b.fy = w.y;
    heat(sim, 0.25);
    run();
  });

  const end = (e) => {
    if (!points.delete(e.pointerId)) return;
    canvas.classList.remove('is-dragging');
    if (drag && drag.moved) suppressClick = true;
    releaseNode(drag);
    drag = null;
  };
  canvas.addEventListener('pointerup', end);
  canvas.addEventListener('pointercancel', end);
  // A drag ends with a click on whatever is under the pointer: swallow it.
  canvas.addEventListener('click', (e) => {
    if (suppressClick) { suppressClick = false; e.stopPropagation(); e.preventDefault(); }
  }, true);

  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    const p = local(e);
    const unit = e.deltaMode === 1 ? 16 : 1;
    zoomAt(p.x, p.y, Math.exp(-e.deltaY * unit * (e.ctrlKey ? 0.01 : 0.0015)), false);
  }, { passive: false });

  // Double-click: on a pinned node lets it go back into the layout; on the background fits.
  canvas.addEventListener('dblclick', (e) => {
    if (e.target.closest('.graph-tools')) return;
    const node = e.target.closest('.gnode');
    const b = node && sim.bodies.get(node.dataset.id);
    if (!node) fit(true);
    else if (b && b.fx !== null) { b.fx = null; b.fy = null; heat(sim, 0.3); run(); }
  });

  canvas.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const act = { '+': () => zoomBy(ZOOM_STEP), '=': () => zoomBy(ZOOM_STEP), '-': () => zoomBy(1 / ZOOM_STEP), '0': () => fit(true) }[e.key];
    if (act) { e.preventDefault(); act(); }
  });
}

// A dragged node stays where it was dropped (until reload); a press without
// a drag leaves it free.
function releaseNode(drag) {
  if (!drag || drag.kind !== 'node' || drag.moved) return;
  const b = sim.bodies.get(drag.id);
  if (b) { b.fx = null; b.fy = null; }
}

// ---------------------------------------------------------------- side panel
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
      onclick: () => {
        pick(m.id, true);
        const btn = dom && dom.nodes.get(m.id);
        if (btn) btn.btn.focus({ preventScroll: true });
      },
      onpointerenter: () => hover(m.id), onpointerleave: () => hover(null),
    }, '→ ' + m.label)) : el('span', { class: 'none' }, 'none')),
    el('span', { class: 'spacer' }),
    n.kind === 'task' ? el('a', { class: 'btn-key gside-open', href: '#today/' + encodeURIComponent(n.slug) }, 'OPEN IN TODAY') : null,
    el('button', { class: 'btn-acc', type: 'button', onclick: () => askNow(question) }, 'ASK ABOUT THIS'),
  ].filter(Boolean));
}
