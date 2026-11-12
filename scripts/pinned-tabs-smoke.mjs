#!/usr/bin/env node
// Native pinned ordering, insertion feedback, pin/unpin, selection and restart.
// Drives registered destination callbacks, NOT the physical AppKit drag gesture.
// All tabs are blank; no network, real profiles or Accessibility permissions needed.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, mkdtemp, readFile, writeFile, rename, rm, copyFile } from 'node:fs/promises';
import { openSync, closeSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'darwin') throw new Error('Pinned tab smoke requires macOS and a built Rail.app.');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const app = resolve(process.env.RAIL_TEST_APP || resolve(root, 'build/Release/Rail.app'));
await mkdir(resolve(root, '.runtime-test'), { recursive: true });
const profile = await mkdtemp(resolve(root, '.runtime-test/pinned-tabs-'));
const statePath = resolve(profile, 'state.json');
const tab = (id, spaceID = 'work', pinned = false, sessionID = 'work') => ({
  id, spaceID, sessionID, pinned, title: id, url: 'about:blank',
  pinnedURL: pinned ? 'about:blank' : '', pinnedTitle: pinned ? id : '', customTitle: pinned ? `Pin ${id}` : '',
});
await writeFile(statePath, JSON.stringify({
  version: 1, activeSpaceID: 'work', activeTabID: 'regular-a', sidebarWidth: 210,
  sessions: [{ id: 'work', name: 'Work' }, { id: 'personal', name: 'Personal' }],
  spaces: ['work', 'personal', 'research'].map(id => ({ id, name: id, sessionID: id === 'personal' ? 'personal' : 'work', selectedTabID: id === 'work' ? 'regular-a' : `${id}-blank` })),
  tabs: [tab('regular-a'), tab('personal-blank', 'personal', false, 'personal'), tab('research-blank', 'research'),
    tab('a', 'work', true, 'isolated-a'), tab('regular-b'), tab('b', 'work', true, 'personal'),
    tab('foreign-a', 'personal', true, 'personal'), tab('c', 'work', true),
    { ...tab('snoozed'), snoozedUntil: Math.floor(Date.now() / 1000) + 3600 },
    tab('d', 'work', true), tab('foreign-b', 'personal', true, 'personal'), tab('e', 'work', true)],
}));

let child, childExit, sequence = 0, checks = 0;
const pause = ms => new Promise(done => setTimeout(done, ms));
async function state() { return JSON.parse(await readFile(resolve(profile, 'automation-state.json'), 'utf8')); }
async function until(label, task, timeout = 15000) {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    if (child?.exitCode !== null && child?.exitCode !== undefined) throw new Error(`App exited during ${label}. See ${profile}/app.log`);
    try { const result = await task(); if (result) return result; } catch (error) { last = error; }
    await pause(80);
  }
  throw new Error(`Timed out: ${label}${last ? `: ${last.message}` : ''}. See ${profile}/app.log`);
}
async function command(action, args = {}) {
  const id = String(++sequence);
  await writeFile(resolve(profile, 'command.tmp'), JSON.stringify({ id, action, ...args }));
  await rename(resolve(profile, 'command.tmp'), resolve(profile, 'automation-command.json'));
  if (action === 'quit') return;
  return until(`command ${action}`, async () => { const s = await state(); return s.command === id && s; });
}
async function start() {
  await rm(resolve(profile, 'automation-state.json'), { force: true });
  await rm(resolve(profile, 'automation-command.json'), { force: true });
  const log = openSync(resolve(profile, 'app.log'), 'a');
  child = spawn(resolve(app, 'Contents/MacOS/Rail'), [`--data-dir=${profile}`, '--automation'], { stdio: ['ignore', log, log] });
  closeSync(log); childExit = once(child, 'exit');
  return until('native startup', state, 25000);
}
async function stop() {
  const exiting = childExit;
  await command('quit');
  let timer;
  try {
    const [code] = await Promise.race([exiting, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Native quit did not finish')), 15000); })]);
    assert.equal(code, 0, 'App must exit cleanly');
    child = null;
  } finally { clearTimeout(timer); }
}
const order = (s, space = 'work') => s.tabs.filter(t => t.pinned && t.space === space).map(t => t.id);
function tile(s, id) { return s.tabDrag.pins.find(pin => pin.tab === id).frame; }
function point(s, id, fraction = .25) {
  const [x, y, width, height] = tile(s, id);
  return { x: x + width * fraction, y: y + height / 2 };
}
async function expectOrder(expected, space = 'work') {
  return until('reordered pins', async () => {
    const s = await state();
    assert.deepEqual(order(s, space), expected);
    return s;
  });
}
async function drop(id, position, expected) {
  await command('tabDrag', { tab: id, phase: 'drop', ...position });
  return expectOrder(expected);
}
function marker(s) {
  assert.equal(s.tabDrag.visible, true, 'hover must show insertion feedback');
  assert.equal(s.tabDrag.indicator[2], 3, 'reorder feedback must be a thin insertion line, not a section highlight');
  assert.equal(s.tabDrag.indicator[3], 36);
}
function passed(message) { checks++; console.log(`PASS ${message}`); }

try {
  let s = await start();
  assert.deepEqual(order(s), ['a', 'b', 'c', 'd', 'e']);
  assert.equal(s.runtimeCount, 0, 'blank fixtures should not create pages');
  const originalTabs = [...s.tabs].sort((a, b) => a.id.localeCompare(b.id));

  s = await command('tabDrag', { tab: 'e', ...point(s, 'a') });
  marker(s);
  assert.deepEqual(order(s), ['a', 'b', 'c', 'd', 'e'], 'hover must not reorder');
  assert.equal(s.tabDrag.indicator[1], tile(s, 'a')[1]);
  assert.ok(s.tabDrag.indicator[0] < tile(s, 'a')[0], 'before-first marker must lead the tile');
  await command('capture');
  await copyFile(resolve(profile, 'native-window.png'), resolve(profile, 'insertion-before-first.png'));
  s = await command('tabDrag', { phase: 'end' });
  assert.equal(s.tabDrag.visible, false);
  assert.deepEqual(order(s), ['a', 'b', 'c', 'd', 'e'], 'cancellation must not reorder');
  passed('hover shows the insertion edge without mutation; leaving/canceling removes it');

  s = await drop('e', point(s, 'a'), ['e', 'a', 'b', 'c', 'd']);
  s = await drop('e', point(s, 'c', .75), ['a', 'b', 'c', 'e', 'd']);
  const [x, y, width, height] = tile(s, 'd');
  const emptyHalf = { x: x + width + 6 + width / 2, y: y + height / 2 };
  s = await command('tabDrag', { tab: 'a', ...emptyHalf });
  marker(s);
  assert.ok(s.tabDrag.indicator[0] > x + width, 'append marker must trail the last tile of an odd row');
  s = await drop('a', emptyHalf, ['b', 'c', 'e', 'd', 'a']);
  assert.equal(s.activeTab, 'regular-a');
  assert.equal(s.activeSpace, 'work');
  assert.deepEqual([...s.tabs].sort((a, b) => a.id.localeCompare(b.id)), originalTabs, 'reorder must preserve metadata, sessions, loaded state and all unrelated tabs');
  assert.deepEqual(order(s, 'personal'), ['foreign-a', 'foreign-b']);
  passed('first/last, both directions, row wrapping and odd-row append preserve tabs, sessions and Spaces');

  const beforeInvalid = order(s);
  s = await command('tabDrag', { tab: 'foreign-a', ...point(s, 'b') });
  assert.equal(s.tabDrag.visible, false, 'another Space must not get insertion feedback');
  s = await drop('foreign-a', point(s, 'b'), beforeInvalid);
  s = await command('tabDrag', { tab: 'b', x: -1, y: s.tabDrag.start });
  assert.equal(s.tabDrag.visible, false, 'outside-document positions must clear feedback');
  passed('invalid and cross-Space drops leave the order unchanged');

  // Crossing the boundary still changes only the dragged pin, not a selection.
  s = await command('tabModifiedClick', { tab: 'regular-b' });
  assert.deepEqual(s.tabDrag.selection, ['regular-a', 'regular-b']);
  s = await command('tabModifiedClick', { tab: 'c' });
  assert.deepEqual(s.tabDrag.selection, [], 'modifier-clicking a pin must activate it, not add it to multi-selection');
  assert.equal(s.activeTab, 'c');
  await command('select', { tab: 'regular-a' });
  s = await command('tabModifiedClick', { tab: 'regular-b', shift: true });
  assert.deepEqual(s.tabDrag.selection, ['regular-a', 'regular-b'], 'range selection must skip reordered pins');
  s = await drop('a', { x: 30, y: s.tabDrag.end + 30 }, ['b', 'c', 'e', 'd']);
  assert.equal(s.tabs.find(t => t.id === 'a').pinned, false);
  assert.deepEqual(s.tabDrag.selection, ['regular-a', 'regular-b']);
  s = await drop('b', point(s, 'd', .75), ['c', 'e', 'd', 'b']);
  s = await command('tabDrag', { tab: 'a', x: 30, y: s.tabDrag.start + 10 });
  assert.ok(s.tabDrag.indicator[2] > 3, 'pinning must retain the section highlight');
  await command('tabDrag', { tab: 'a', phase: 'drop', x: 30, y: s.tabDrag.start + 10 });
  s = await until('repinned tab', async () => { const current = await state(); return current.tabs.find(t => t.id === 'a').pinned && current; });
  assert.deepEqual(s.tabDrag.selection, ['regular-a', 'regular-b']);
  const pinOrder = order(s);
  s = await drop(pinOrder.at(-1), point(s, pinOrder[0]), [pinOrder.at(-1), ...pinOrder.slice(0, -1)]);
  assert.deepEqual(s.tabDrag.selection, ['regular-a', 'regular-b'], 'pin reordering must not change an existing regular selection');
  passed('even-row append, pin/unpin dragging and regular multi-selection retain their behavior');

  await command('tabDrag', { tab: 'e', target: 'rail', space: 'research', phase: 'drop' });
  s = await until('single pin moved to Space', async () => { const current = await state(); return current.tabs.find(t => t.id === 'e').space === 'research' && current; });
  assert.deepEqual(s.tabDrag.selection, ['regular-a', 'regular-b']);
  assert.equal(s.tabs.find(t => t.id === 'regular-a').space, 'work');
  assert.equal(s.tabs.find(t => t.id === 'regular-b').space, 'work');
  const workPins = order(s);
  await command('tabDrag', { tab: 'regular-b', target: 'rail', space: 'personal', phase: 'drop' });
  s = await until('selected regular tabs moved', async () => {
    const current = await state();
    return ['regular-a', 'regular-b'].every(id => current.tabs.find(t => t.id === id).space === 'personal') && current;
  });
  assert.deepEqual(order(s), workPins);
  assert.deepEqual(order(s, 'personal'), ['foreign-a', 'foreign-b']);
  assert.deepEqual(s.tabDrag.selection, []);
  passed('Space dragging moves one pin but still moves a multi-selection of regular tabs together');

  // Real saves/relaunches plus hit testing at each supported control size. Callback
  // coordinates are unscaled; physical gesture/scroll conversion remains a manual check.
  await command('select', { tab: 'a' });
  const expectedBySpace = Object.fromEntries(['work', 'personal', 'research'].map(space => [space, order(s, space)]));
  await stop();
  for (const [controlSize, sidebarWidth, theme] of [['small', 180, 'porcelain'], ['normal', 301, 'nightline'], ['large', 420, 'daylight']]) {
    const saved = JSON.parse(await readFile(statePath, 'utf8'));
    await writeFile(statePath, JSON.stringify({ ...saved, controlSize, sidebarWidth, theme }));
    s = await start();
    for (const [space, expected] of Object.entries(expectedBySpace)) assert.deepEqual(order(s, space), expected, 'pin order must persist in every Space');
    assert.equal(s.activeTab, 'a');
    const pins = order(s);
    s = await command('tabDrag', { tab: pins.at(-1), ...point(s, pins[0], .75) });
    marker(s);
    assert.equal(s.tabDrag.indicator[1], tile(s, pins[1])[1]);
    assert.ok(s.tabDrag.indicator[0] > tile(s, pins[0])[0] + tile(s, pins[0])[2] && s.tabDrag.indicator[0] < tile(s, pins[1])[0], 'between-column marker must sit in the gap');
    await command('capture');
    await copyFile(resolve(profile, 'native-window.png'), resolve(profile, `insertion-${controlSize}-${theme}.png`));
    s = await command('tabDrag', { phase: 'end' });
    assert.equal(s.tabDrag.visible, false);
    await stop();
  }
  passed('order survives real restarts; insertion feedback uses native frames at all sizes and themes');
  console.log(`${checks} pinned-tab checks passed. Artifacts: ${profile}`);
} finally {
  if (child && child.exitCode === null) { child.kill('SIGTERM'); await childExit; }
}
