// Meet: record a call on this Mac, a live transcript, and cards that point at
// what the brain already knows. "#meet" is standby or the call in progress;
// "#meet/<id>" shows a recorded meeting's notes.
import { $, el, api, act, store, panelHead, keepFocus, setStatusLine, taskTitle, dayLabel, day, hm } from './core.js';
import { askNow } from './ask.js';

const LIVE_MS = 1000;
const IDLE_MS = 3000;
const SEGS = 16;
const TABS = [['all', 'all'], ['LINK', 'link'], ['ANSWER', 'answer'], ['TASK', 'task'], ['DECISION', 'decision'], ['transcript', 'transcript']];
const SWITCHES = [['screen', 'Screen', 'video of the main display'], ['system', 'System audio', 'what the call says (them)'],
  ['mic', 'Microphone', 'what you say (you)'], ['detect', 'Detect calls', 'offer to record when a call starts'],
  ['notes', 'Notes by claude', 'summary and action items after the call; the transcript is sent to claude']];
const ACTIONS = { link: 'LINK TO TASK', ask: 'ASK RAMI', inbox: '+ INBOX', decide: '+ LOG' };

let info = null;      // GET api/meet
let live = null;      // GET api/meet/<id>/live while recording
let shown = null;     // GET api/meet/<id>/detail when viewing one
let viewId = null;
let tab = 'all';
let skipped = '';     // the call app the owner said not to record, until the call ends
let timer = null;
let mounted = 0;
let busy = false;
let lastJson = '';
const form = { title: '', task: '' };   // kept across re-renders while typing

const clock = (s) => {
  s = Math.max(0, Math.floor(s || 0));
  const mm = String(Math.floor(s / 60) % 60).padStart(2, '0') + ':' + String(s % 60).padStart(2, '0');
  return s >= 3600 ? Math.floor(s / 3600) + ':' + mm : mm;
};
const size = (b) => (b > 1e9 ? (b / 1e9).toFixed(1) + ' GB' : b > 1e6 ? Math.round(b / 1e6) + ' MB' : Math.max(1, Math.round(b / 1e3)) + ' KB');
const cur = () => info && info.overview.recording;

export function mount(panel, param) {
  const me = ++mounted;
  lastJson = '';
  viewId = param || null;
  shown = null;
  panel.replaceChildren(
    panelHead('07', 'meet', 'meet-sub'),
    el('div', { class: 'meet', id: 'meet' },
      el('div', { class: 'meet-main', id: 'meet-main' }, el('p', { class: 'none' }, 'loading…')),
      el('aside', { class: 'meet-side', 'aria-label': 'Library and capture' },
        el('section', { class: 'block' }, el('h2', { class: 'label rule' }, 'library'), el('div', { class: 'lib', id: 'meet-lib' })),
        el('section', { class: 'block' }, el('h2', { class: 'label rule' }, 'capture'), el('div', { id: 'meet-sw' })))));
  $('meet-sub').textContent = 'screen + audio · transcribed on this mac · kept in ~/brain/meetings';
  refresh(me);
}

export function unmount() {
  mounted++;
  clearTimeout(timer);
  timer = null;
}

export function update() { /* Meet polls on its own */ }

async function refresh(me) {
  if (me !== mounted) return;
  clearTimeout(timer);
  try {
    info = await api('api/meet');
    const rec = cur();
    live = rec ? await api('api/meet/' + encodeURIComponent(rec.id) + '/live') : null;
    if (viewId && (!shown || shown.meta.id !== viewId || shown.meta.state !== 'done')) {
      shown = await api('api/meet/' + encodeURIComponent(viewId) + '/detail');
    }
    if (!info.overview.call.detected) skipped = '';
  } catch (e) {
    setStatusLine(false, 'meet unavailable: ' + e.message);
  }
  if (me !== mounted || !$('meet')) return;
  if (!info) {   // never loaded: try again rather than render nothing for good
    timer = setTimeout(() => refresh(me), IDLE_MS);
    return;
  }
  const json = JSON.stringify([info, live, shown, viewId, tab, skipped]);
  if (json !== lastJson) {
    lastJson = json;
    keepFocus(render);
  }
  const waiting = cur() || (shown && shown.meta.state !== 'done');
  timer = setTimeout(() => refresh(me), waiting ? LIVE_MS : IDLE_MS);
}

const again = () => refresh(mounted);

// One action at a time; STOP (force) is never dropped.
async function post(path, body, force) {
  if (busy && !force) return null;
  busy = true;
  try {
    const j = await api(path, body);
    setStatusLine(true, '');
    return j;
  } catch (e) {
    setStatusLine(true, e.message);
    return null;
  } finally {
    busy = false;
    shown = null;   // an action can change the meeting shown: fetch it again
    again();
  }
}

async function startRec(app) {
  if (await post('api/meet/start', { title: form.title, task: form.task, app: app || '' })) {
    form.title = '';
    form.task = '';
    viewId = null;
    shown = null;
    tab = 'all';
    if (location.hash !== '#meet') history.replaceState(null, '', '#meet');
  }
}

async function stopRec() {
  const rec = cur();
  const j = await post('api/meet/stop', {}, true);
  if (j && rec) location.hash = '#meet/' + encodeURIComponent(rec.id);
}

function render() {
  renderSide();
  const rec = cur();
  let body;
  if (rec && live && (!viewId || viewId === rec.id)) body = recording(live);
  else if (shown) body = shown.meta.state === 'done' ? notes(shown) : processing(shown);
  else if (!info.available.ok) body = unavailable(info.available);
  else if (info.overview.call.detected && info.overview.call.app !== skipped) body = detected(info.overview.call);
  else body = standby();
  $('meet-main').replaceChildren(...[].concat(body).filter(Boolean));
}

// ---------------------------------------------------------------- states

function unavailable(av) {
  return el('div', { class: 'standby' },
    el('span', { class: 'label' }, 'recording is off'),
    el('span', { class: 'standby-big' }, 'Meet cannot record here.'),
    el('span', { class: 'standby-text' }, av.reason || 'the recorder is not available'),
    el('span', { class: 'standby-text' }, 'Recorded meetings stay readable in the library.'));
}

function taskPicker() {
  const open = store.data ? store.data.tasks.filter((t) => t.status !== 'done') : [];
  return el('div', { class: 'meet-form' },
    el('label', { class: 'sr-only', for: 'meet-title' }, 'Meeting title'),
    el('input', { id: 'meet-title', class: 'meet-input', autocomplete: 'off', maxlength: '120', placeholder: 'title (optional)',
      'data-fk': 'meet:title', value: form.title, oninput: (e) => { form.title = e.target.value; } }),
    el('label', { class: 'sr-only', for: 'meet-task' }, 'Link to task'),
    el('select', { id: 'meet-task', class: 'meet-input', 'data-fk': 'meet:task', onchange: (e) => { form.task = e.target.value; } },
      el('option', { value: '' }, 'no task yet'),
      open.map((t) => el('option', { value: t.slug, selected: t.slug === form.task }, t.title || t.slug))));
}

function standby() {
  const av = info.available;
  const perms = [av.screen === 'granted' ? '' : 'screen recording not granted yet', av.mic === 'granted' ? '' : 'microphone not granted yet'].filter(Boolean);
  return el('div', { class: 'standby' },
    el('span', { class: 'label standby-led' }, el('span', { class: 'led', 'aria-hidden': 'true' }),
      info.settings.detect ? 'standby · listening for calls' : 'standby'),
    el('span', { class: 'standby-big' }, 'No meeting in progress.'),
    el('span', { class: 'standby-text' }, 'When Zoom, Teams, FaceTime or a browser call uses the microphone, Rami offers to record. ' +
      'Screen, mic and system audio are captured and transcribed by Apple\'s on-device model; nothing is uploaded while you record.'),
    perms.length ? el('span', { class: 'standby-text is-warn' }, perms.join(' · ') + ': macOS asks on the first recording') : null,
    taskPicker(),
    el('div', { class: 'meet-actions' },
      el('button', { type: 'button', class: 'btn-acc', 'data-fk': 'meet:rec', onclick: () => startRec('') }, '● RECORD NOW')));
}

function detected(call) {
  return el('div', { class: 'callbox', role: 'alert' },
    el('span', { class: 'label' }, 'call detected · ' + call.app),
    el('span', { class: 'callbox-big' }, 'Record this call?'),
    el('span', { class: 'callbox-text' }, 'Tell the others before you record. Rami links what is said to your tasks as you talk.'),
    taskPicker(),
    el('div', { class: 'meet-actions' },
      el('button', { type: 'button', class: 'btn-acc', 'data-fk': 'meet:rec', onclick: () => startRec(call.app) }, '● RECORD'),
      el('button', { type: 'button', class: 'btn-ghost', 'data-fk': 'meet:skip', onclick: () => { skipped = call.app; keepFocus(render); } }, 'SKIP')));
}

function meterSegs(v) {
  const lit = Math.round((v || 0) * SEGS);
  return el('span', { class: 'lv-segs', 'aria-hidden': 'true' },
    Array.from({ length: SEGS }, (_, i) => el('span', { class: 'lv-seg' + (i < lit ? (i >= SEGS - 3 ? ' is-hot' : ' is-on') : '') })));
}

function recording(l) {
  const heard = [l.heard.them, l.heard.you].filter(Boolean).join(' / ');
  const last = l.lines[l.lines.length - 1];
  return [
    el('div', { class: 'recbar' },
      el('div', { class: 'recbar-top' },
        el('span', { class: 'rec-dot', 'aria-hidden': 'true' }),
        el('span', { class: 'rec-time', role: 'timer', 'aria-label': 'recording time' }, clock(l.elapsed)),
        el('span', { class: 'rec-what' }, l.title + ' · screen ' + (l.screen ? 'on' : 'off') + (l.rec === 'preparing' ? ' · starting…' : '')),
        el('span', { class: 'spacer' }),
        ['you', 'them'].map((w) => el('span', { class: 'lv', title: w + ' level' }, el('span', { class: 'lv-k' }, w), meterSegs(l.levels[w]))),
        el('button', { type: 'button', class: 'btn-acc', 'data-fk': 'meet:stop', onclick: stopRec }, '■ STOP')),
      el('span', { class: 'rec-heard', 'aria-live': 'off' }, 'heard · ' + (heard || (last ? last.text : 'listening…'))),
      l.errors.length ? el('span', { class: 'rec-err' }, l.errors[l.errors.length - 1]) : null),
    tabs(l.cards, l.count),
    tab === 'transcript' ? transcript(l.lines, true) : cardList(l.id, l.cards, l.tasks)];
}

function processing(d) {
  return el('div', { class: 'callbox' },
    el('span', { class: 'label' }, 'processing · ' + d.meta.title),
    el('ol', { class: 'steps' },
      el('li', {}, '✓ recording saved'),
      el('li', {}, '✓ transcript · ' + d.lines.length + ' lines, on device'),
      el('li', {}, (info.settings.notes ? '… notes by claude' : '… notes from the cards'))));
}

// ---------------------------------------------------------------- cards and transcript

function tabs(cards, count) {
  const live = cards.filter((c) => c.state !== 'dismissed');
  return el('div', { class: 'ins-tabs', role: 'tablist', 'aria-label': 'What to show' },
    TABS.map(([id, label]) => {
      const n = id === 'all' ? live.length : id === 'transcript' ? count : live.filter((c) => c.type === id).length;
      return el('button', {
        type: 'button', role: 'tab', class: 'st', 'aria-selected': String(tab === id), 'aria-pressed': String(tab === id),
        'data-fk': 'tab:' + id, onclick: () => { tab = id; keepFocus(render); },
      }, label + ' ' + n);
    }));
}

function cardList(mid, cards, linked) {
  const list = cards.filter((c) => c.state !== 'dismissed' && (tab === 'all' || c.type === tab)).slice().reverse();
  if (!list.length) return el('p', { class: 'none' }, 'cards appear as things are said that your brain knows about');
  return el('ol', { class: 'cards' }, list.map((c) => cardRow(mid, c, linked)));
}

function cardAction(mid, c, action) {
  if (action === 'ask') {
    askNow(c.question || c.heard);
    return;
  }
  post('api/meet/' + encodeURIComponent(mid) + '/cards/' + encodeURIComponent(c.id), { action });
}

function cardRow(mid, c, linked) {
  const done = c.state === 'done';
  let label = ACTIONS[c.act];
  if (c.act === 'decide' && !linked.length) label = '+ INBOX';
  return el('li', { class: 'card' + (done ? ' is-done' : '') },
    el('div', { class: 'card-side' },
      el('span', { class: 'ctype ctype-' + c.type.toLowerCase() }, c.type),
      el('span', { class: 'card-ts' }, clock(c.t) + ' · ' + c.who)),
    el('div', { class: 'card-body' },
      el('span', { class: 'card-heard' }, '“' + c.heard + '”'),
      el('span', { class: 'card-title' }, c.title),
      el('span', { class: 'card-text' }, c.body),
      el('div', { class: 'card-foot' },
        c.refs.filter((r) => r !== 'you' && r !== 'them').map((r) => el('a', { class: 'chip', href: '#today/' + encodeURIComponent(r) }, '↳ ' + taskTitle(r))),
        el('span', { class: 'spacer' }),
        done ? el('span', { class: 'none' }, '✓ done') : el('button', {
          type: 'button', class: 'btn-key', 'data-fk': 'card:' + c.id, onclick: () => cardAction(mid, c, c.act),
        }, label),
        done ? null : el('button', {
          type: 'button', class: 'btn-x', 'aria-label': 'Dismiss card', 'data-fk': 'cardx:' + c.id,
          onclick: () => cardAction(mid, c, 'dismiss'),
        }, '×'))));
}

// While recording the transcript follows new lines, unless the owner has
// scrolled up to read: then it stays where it is across re-renders.
function transcript(lines, follow) {
  if (!lines.length) return el('p', { class: 'none' }, 'nothing heard yet');
  const old = document.querySelector('.tscript');
  const atEnd = !old || old.scrollHeight - old.scrollTop - old.clientHeight < 40;
  const keep = old ? old.scrollTop : 0;
  const box = el('ol', { class: 'tscript', 'aria-label': 'Transcript' }, lines.map((x) => el('li', { class: 'tx tx-' + x.who },
    el('span', { class: 'tx-ts' }, clock(x.t)), el('span', { class: 'tx-who' }, x.who), el('span', { class: 'tx-text' }, x.text))));
  if (follow) requestAnimationFrame(() => { box.scrollTop = atEnd ? box.scrollHeight : keep; });
  return box;
}

// ---------------------------------------------------------------- notes

function notes(d) {
  const m = d.meta;
  const s = d.summary || {};
  const open = store.data ? store.data.tasks.filter((t) => t.status !== 'done' && !m.tasks.includes(t.slug)) : [];
  return [
    el('div', { class: 'notes-head' },
      el('span', { class: 'label' }, [dayLabel(day(m.started)), hm(m.started), clock(m.duration), (m.speakers || []).join(', ')].filter(Boolean).join(' · ')),
      el('h2', { class: 'notes-title' }, m.title)),
    s.summary ? el('p', { class: 'goal' }, s.summary) : el('p', { class: 'none' }, s.error || 'no summary (notes by claude is off)'),
    list('action items', s.actions || [], (a) => el('li', { class: 'act-row' },
      el('span', { class: 'act-text' }, a.text), a.owner && el('span', { class: 'pill' }, a.owner),
      el('button', { type: 'button', class: 'btn-key', 'data-fk': 'act:' + a.text, onclick: (e) => toInbox(e, a.text) }, '+ INBOX'))),
    list('decisions', s.decisions || [], (x) => el('li', {}, x)),
    list('gaps · nobody owns these', s.gaps || [], (x) => el('li', {}, x)),
    suggested(m, s),
    el('div', { class: 'block' },
      el('h3', { class: 'label' }, 'tasks'),
      el('div', { class: 'chips' },
        m.tasks.map((t) => el('a', { class: 'chip', href: '#today/' + encodeURIComponent(t) }, '↳ ' + taskTitle(t))),
        open.length ? el('select', {
          class: 'meet-input meet-link', 'aria-label': 'Link this meeting to a task', 'data-fk': 'meet:link',
          onchange: (e) => e.target.value && post('api/meet/' + encodeURIComponent(m.id) + '/link', { slug: e.target.value }),
        }, el('option', { value: '' }, '+ link to task…'), open.map((t) => el('option', { value: t.slug }, t.title || t.slug))) : null)),
    el('div', { class: 'block' },
      el('h3', { class: 'label' }, 'stored · ' + d.path),
      el('div', { class: 'chips' }, d.files.map((f) => el('span', { class: 'chip' }, f.name + ' · ' + size(f.size))))),
    m.errors && m.errors.length ? el('p', { class: 'rec-err' }, m.errors.join(' · ')) : null,
    el('details', { class: 'block' }, el('summary', { class: 'label' }, 'transcript · ' + d.lines.length + ' lines'), transcript(d.lines, false)),
    el('div', { class: 'meet-actions' },
      el('button', { type: 'button', class: 'btn-acc', 'data-fk': 'meet:ask',
        onclick: () => askNow('What was said in the meeting "' + m.title + '" (meetings/' + m.id + ')?') }, 'ASK ABOUT THIS MEETING'),
      el('a', { class: 'btn-ghost', href: '#meet' }, 'BACK TO STANDBY'))];
}

// Tasks the notes say this call worked on; linking one notes the meeting in its Work done.
function suggested(m, s) {
  const sug = (s.tasks || []).filter((t) => !m.tasks.includes(t.slug));
  if (!sug.length) return null;
  return el('div', { class: 'block' }, el('h3', { class: 'label' }, 'suggested · link recording'),
    el('ul', { class: 'work' }, sug.map((t) => el('li', { class: 'act-row' },
      el('span', { class: 'act-text' }, el('b', {}, taskTitle(t.slug)), t.note ? ' · ' + t.note : ''),
      el('button', {
        type: 'button', class: 'btn-key', 'data-fk': 'sug:' + t.slug,
        onclick: () => post('api/meet/' + encodeURIComponent(m.id) + '/link', { slug: t.slug }),
      }, 'LINK TO TASK')))));
}

function list(title, items, row) {
  if (!items.length) return null;
  return el('div', { class: 'block' }, el('h3', { class: 'label' }, title), el('ul', { class: 'work' }, items.map(row)));
}

async function toInbox(e, text) {
  e.target.disabled = true;
  if (await act('api/captures', { text })) e.target.textContent = '✓ IN INBOX';
  else e.target.disabled = false;
}

// ---------------------------------------------------------------- side

function renderSide() {
  const lib = info.library;
  $('meet-lib').replaceChildren(...(lib.length ? lib.slice(0, 20).map((x) => el('a', {
    class: 'lib-row' + (x.id === viewId ? ' is-sel' : ''), href: '#meet/' + encodeURIComponent(x.id), 'aria-current': x.id === viewId ? 'true' : null,
  },
    el('span', { class: 'lib-meta' }, el('span', {}, dayLabel(day(x.started))),
      el('span', {}, (x.state === 'recording' ? '● rec' : x.state === 'processing' ? 'processing' : clock(x.duration)) + ' · ' + size(x.size))),
    el('span', { class: 'lib-title' }, x.title))) : [el('span', { class: 'none' }, 'no meetings yet')]));
  $('meet-sw').replaceChildren(...SWITCHES.map(([key, label, hint]) => {
    const on = !!info.settings[key];
    return el('div', { class: 'setting' },
      el('span', { class: 'setting-text' }, el('b', {}, label), el('span', {}, hint)),
      el('button', {
        class: 'switch' + (on ? ' is-on' : ''), type: 'button', role: 'switch', 'aria-checked': String(on), 'aria-label': label,
        'data-fk': 'msw:' + key, disabled: !!cur() && key !== 'notes' && key !== 'detect',
        onclick: () => post('api/meet/settings', { key, value: !on }),
      }, el('span', { class: 'switch-knob' })));
  }));
}
