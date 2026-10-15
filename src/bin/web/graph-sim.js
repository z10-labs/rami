// Force layout for the graph, in world pixels (1 unit = 1px at zoom 1).
// Deterministic: the same nodes start in the same places, so a reload
// settles into the same picture. Positions survive data refreshes by id.

const REPEL = 2600;          // node-node push
const GRAVITY = 0.012;       // pull toward the origin, keeps islands close
const SPRING = 0.06;
const DAMP = 0.58;           // velocity kept per tick
const ALPHA_MIN = 0.004;
const ALPHA_DECAY = 0.975;
const REST = { project: 110, session: 130, decision: 70 };

function hash(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
  return (h >>> 0) / 4294967295;
}

export function createSim() {
  return { bodies: new Map(), links: [], alpha: 0 };
}

// Bring the sim in line with new data: keep known bodies where they are,
// place new ones next to a linked body (or on a ring if they have none).
export function syncSim(sim, nodes, edges, radius) {
  const old = sim.bodies;
  const bodies = new Map();
  const ring = 160 + nodes.length * 6;
  nodes.forEach((n) => {
    const prev = old.get(n.id);
    if (prev) { bodies.set(n.id, { ...prev, r: radius(n) }); return; }
    const a = hash(n.id) * Math.PI * 2;
    const d = n.kind === 'project' ? ring * 0.35 : ring;
    bodies.set(n.id, { x: d * Math.cos(a), y: d * Math.sin(a), vx: 0, vy: 0, fx: null, fy: null, r: radius(n) });
  });
  for (const n of nodes) {
    if (old.has(n.id)) continue;
    const anchor = edges.map((e) => (e.a === n.id ? e.b : e.b === n.id ? e.a : null))
      .find((id) => id && old.has(id));
    if (!anchor) continue;
    const p = bodies.get(anchor), a = hash(n.id + '~') * Math.PI * 2;
    Object.assign(bodies.get(n.id), { x: p.x + 60 * Math.cos(a), y: p.y + 60 * Math.sin(a) });
  }
  sim.bodies = bodies;
  sim.links = edges.filter((e) => bodies.has(e.a) && bodies.has(e.b));
  return old.size === 0;
}

export function tick(sim) {
  const list = [...sim.bodies.values()];
  const { alpha } = sim;
  for (let i = 0; i < list.length; i++) {
    const a = list[i];
    for (let j = i + 1; j < list.length; j++) {
      const b = list[j];
      let dx = a.x - b.x, dy = a.y - b.y;
      if (dx === 0 && dy === 0) { dx = 0.1 * (i - j); dy = 0.1; }
      const d2 = dx * dx + dy * dy, d = Math.sqrt(d2);
      let f = (REPEL * alpha) / Math.max(d2, 100);
      const gap = a.r + b.r + 34;                  // room for a label between dots
      if (d < gap) f += ((gap - d) / d) * 0.5;
      a.vx += dx * f / d; a.vy += dy * f / d;
      b.vx -= dx * f / d; b.vy -= dy * f / d;
    }
    a.vx -= a.x * GRAVITY * alpha; a.vy -= a.y * GRAVITY * alpha;
  }
  for (const e of sim.links) {
    const a = sim.bodies.get(e.a), b = sim.bodies.get(e.b);
    const dx = b.x - a.x, dy = b.y - a.y, d = Math.max(Math.hypot(dx, dy), 0.01);
    const f = ((d - (REST[e.kind] || 100)) / d) * SPRING * alpha;
    a.vx += dx * f; a.vy += dy * f; b.vx -= dx * f; b.vy -= dy * f;
  }
  for (const a of list) {
    if (a.fx !== null) { a.x = a.fx; a.y = a.fy; a.vx = 0; a.vy = 0; continue; }
    a.vx *= DAMP; a.vy *= DAMP;
    a.x += a.vx; a.y += a.vy;
  }
  sim.alpha = sim.alpha * ALPHA_DECAY;
  return sim.alpha > ALPHA_MIN;
}

export function heat(sim, alpha) {
  sim.alpha = Math.max(sim.alpha, alpha);
}

// Run until still: used for the first picture and under reduced motion.
export function settle(sim, alpha = 1) {
  heat(sim, alpha);
  for (let i = 0; i < 600 && tick(sim); i++);
  sim.alpha = 0;
}
