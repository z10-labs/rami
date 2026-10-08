// System: is the brain healthy, and what has it been doing.
import { $, el, api, act, panelHead, shortWhen, keepFocus, setStatusLine, LOOKS, getLook, setLook } from './core.js';

const REFRESH_MS = 30000;
let status = null;
let timer = null;
let mounted = 0;   // bumps on every mount/unmount, so a late refresh knows it is stale

export async function mount(panel) {
  const me = ++mounted;
  panel.replaceChildren(
    panelHead('06', 'system', 'sys-sub'),
    el('div', { class: 'sys', id: 'sys' }, el('p', { class: 'none' }, 'loading…')));
  await refresh();
  if (me === mounted) timer = setInterval(refresh, REFRESH_MS);
}

export function unmount() {
  mounted++;
  clearInterval(timer);
  timer = null;
}

async function refresh() {
  try {
    status = await api('api/status');
    if ($('sys')) keepFocus(render);
  } catch (e) {
    setStatusLine(false, 'status unavailable: ' + e.message);
  }
}

export function update() { /* status has its own refresh */ }

async function setConfig(key, value) {
  if (await act('api/config', { key, value })) await refresh();
}

function meter(label, values) {
  const max = Math.max(1, ...values);
  const total = values.reduce((a, b) => a + b, 0);
  return el('div', { class: 'meter' },
    el('div', { class: 'meter-head' }, el('span', {}, label), el('span', { class: 'meter-v' }, total + ' in 24h')),
    el('div', { class: 'meter-segs', role: 'img', 'aria-label': label + ': ' + total + ' in the last 24 hours, by hour' },
      values.map((v) => el('span', { class: 'mseg', style: { '--lvl': String(v ? 0.25 + 0.75 * (v / max) : 0) }, title: String(v) }))),
    el('div', { class: 'meter-axis', 'aria-hidden': 'true' }, el('span', {}, '−24h'), el('span', {}, 'now')));
}

function toggle(key, on, labels) {
  return el('button', {
    class: 'switch' + (on ? ' is-on' : ''), type: 'button', role: 'switch', 'aria-checked': String(on),
    'aria-label': labels, 'data-fk': 'cfg:' + key, onclick: () => setConfig(key, on ? 'off' : 'on'),
  }, el('span', { class: 'switch-knob' }));
}

function render() {
  const s = status;
  const bad = s.checks.filter((c) => c.level !== 'ok').length;
  $('sys-sub').textContent = bad ? bad + ' need attention · ' + s.store.path : 'all checks ok · ' + s.store.path;
  const models = s.page_keys.AGENT_MODEL;
  $('sys').replaceChildren(
    el('div', { class: 'sys-col' },
      el('section', { class: 'block' },
        el('h2', { class: 'label rule' }, 'health'),
        el('ul', { class: 'checklist' }, s.checks.map((c) => el('li', { class: 'chk' },
          el('span', { class: 'dot dot-' + c.level, role: 'img', 'aria-label': c.level }),
          el('span', { class: 'chk-label' }, c.label),
          el('span', { class: 'chk-detail' }, c.detail))))),
      el('div', { class: 'setting' },
        el('span', { class: 'setting-text' }, el('b', {}, 'Notifications'), el('span', {}, 'macOS banners for things the agent finds')),
        toggle('NOTIFY', s.config.NOTIFY === 'on', 'Notifications')),
      el('div', { class: 'setting' },
        el('span', { class: 'setting-text' }, el('b', {}, 'Look'), el('span', {}, 'auto follows the system; kept in this browser')),
        el('div', { class: 'seg-keys seg-keys-4', role: 'group', 'aria-label': 'Look' }, LOOKS.map(([id, label]) => el('button', {
          class: 'st', type: 'button', 'aria-pressed': String(getLook() === id), 'data-fk': 'look:' + id,
          onclick: () => { setLook(id); keepFocus(render); },
        }, label)))),
      el('div', { class: 'setting' },
        el('span', { class: 'setting-text' }, el('b', {}, 'Agent model'), el('span', {}, 'used by the background agent and Ask')),
        el('div', { class: 'seg-keys', role: 'group', 'aria-label': 'Agent model' }, models.map((m) => el('button', {
          class: 'st', type: 'button', 'aria-pressed': String(s.config.AGENT_MODEL === m), 'data-fk': 'model:' + m,
          onclick: () => { if (s.config.AGENT_MODEL !== m) setConfig('AGENT_MODEL', m); },
        }, m)))),
      el('section', { class: 'block' },
        el('h2', { class: 'label rule' }, 'store'),
        el('dl', { class: 'facts facts-4' }, [['tasks', s.store.tasks], ['archived', s.store.archived],
          ['decisions', s.store.decisions], ['follow-ups', s.store.followups_open], ['captures', s.store.captures],
          ['sessions', s.store.sessions]].map(([k, v]) => el('div', {}, el('dt', {}, k), el('dd', {}, String(v))))))),
    el('div', { class: 'sys-col' },
      el('div', { class: 'big' },
        el('span', { class: 'label' }, 'ticks today'),
        el('span', { class: 'big-n' }, String(s.tick.today).padStart(2, '0')),
        el('span', { class: 'big-sub' }, 'every ' + s.tick.every_minutes + ' min · agent ' + s.agent.today + ' runs today · ' + s.agent.model)),
      meter('sessions started', s.activity.sessions),
      meter('log lines written', s.activity.log),
      el('section', { class: 'block' },
        el('h2', { class: 'label rule' }, 'recent ticks'),
        el('ol', { class: 'ticks' }, s.tick.recent.map((r) => el('li', {},
          el('span', { class: 'tick-at' }, shortWhen(r.at)), el('span', { class: 'tick-r' }, r.result)))))));
}
