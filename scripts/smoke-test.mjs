#!/usr/bin/env node
// Real CEF integration tests. Uses only disposable profiles and a localhost fixture.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, mkdtemp, readFile, writeFile, rename, rm } from 'node:fs/promises';
import { openSync, closeSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
await mkdir(resolve(root, '.runtime-test'), { recursive: true });
const profile = await mkdtemp(resolve(root, '.runtime-test/smoke-'));
const requests = [];
const fixture = createServer((request, response) => {
  requests.push(request.url);
  response.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
  response.end(`<!doctype html><meta charset="utf-8"><title>Rail ${request.url}</title><style>body{font:18px system-ui;padding:48px;color:#273445}</style><h1>Rail browser test</h1><p>This page runs inside Chromium.</p><a href="/popup" target="_blank">Open another tab</a><p><a id="middle" href="/middle">Middle-click link</a></p>`);
});
fixture.listen(0, '127.0.0.1'); await once(fixture, 'listening');
const origin = `http://127.0.0.1:${fixture.address().port}`;
const portProbe = createServer(); portProbe.listen(0, '127.0.0.1'); await once(portProbe, 'listening');
const debugPort = portProbe.address().port;
await new Promise(resolve => portProbe.close(resolve));
let child, childExit, sequence = 0, checks = 0;
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(label, task, timeout = 15000) {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    if (child?.exitCode !== null && child?.exitCode !== undefined) throw new Error(`App exited (${child.exitCode}) during ${label}. See ${profile}/app.log`);
    try { const value = await task(); if (value) return value; } catch (error) { last = error; }
    await pause(80);
  }
  throw new Error(`Timed out: ${label}${last ? `: ${last.message}` : ''}. See ${profile}/app.log`);
}
async function state() { return JSON.parse(await readFile(resolve(profile, 'automation-state.json'), 'utf8')); }
async function command(action, args = {}) {
  const id = String(++sequence);
  const tmp = resolve(profile, 'command.tmp');
  await writeFile(tmp, JSON.stringify({ id, action, ...args }));
  await rename(tmp, resolve(profile, 'automation-command.json'));
  if (action === 'quit') return;
  return until(`command ${action}`, async () => { const s = await state(); return s.command === id && s; });
}
async function targets() { return (await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json()).filter(t => t.type === 'page'); }
async function target(url) { return until(`page ${url}`, async () => (await targets()).find(t => t.url === url && t.title.startsWith('Rail '))); }
async function cdp(url, method, params) {
  const page = await target(url);
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  await once(socket, 'open');
  const response = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('CDP timeout')), 5000);
    socket.addEventListener('message', e => { const data = JSON.parse(e.data); if (data.id === 1) { clearTimeout(timer); data.error ? reject(new Error(data.error.message)) : resolve(data.result); } });
  });
  socket.send(JSON.stringify({ id: 1, method, params }));
  try { return await response; }
  finally { socket.close(); }
}
async function evaluate(url, expression) {
  const result = await cdp(url, 'Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true, userGesture: true });
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
async function clickLink(url, path, { button = 'middle', modifiers = 0, blank = false } = {}) {
  const point = await evaluate(url, `(() => {
    const link = document.querySelector('#middle');
    link.href = ${JSON.stringify(path)};
    link.target = ${JSON.stringify(blank ? '_blank' : '')};
    const r = link.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  })()`);
  for (const type of ['mousePressed', 'mouseReleased'])
    await cdp(url, 'Input.dispatchMouseEvent', { type, ...point, button, modifiers, clickCount: 1 });
}
function passed(message) { checks++; console.log(`PASS ${message}`); }
async function start() {
  await rm(resolve(profile, 'automation-state.json'), { force: true });
  await rm(resolve(profile, 'automation-command.json'), { force: true });
  const log = openSync(resolve(profile, 'app.log'), 'a');
  child = spawn(resolve(root, 'build/Release/Rail.app/Contents/MacOS/Rail'), [`--data-dir=${profile}`, '--automation', `--debug-port=${debugPort}`], { stdio: ['ignore', log, log] });
  closeSync(log); childExit = once(child, 'exit');
  return until('native app startup', state, 25000);
}
async function stop() {
  const exiting = childExit;
  await command('quit');
  let timer;
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Native quit did not finish')), 15000); });
  let result;
  try { result = await Promise.race([exiting, timeout]); } finally { clearTimeout(timer); }
  assert.equal(result[0], 0, 'App must exit cleanly');
  child = null;
}
async function newTab(path, args = {}) {
  const url = origin + path;
  const s = await command('newTab', { url, ...args });
  const id = s.activeTab;
  await until(`loaded ${path}`, async () => (await state()).tabs.find(t => t.id === id && t.loaded && !t.error));
  try {
    await until(`document ${path}`, async () => await evaluate(url, `location.href === ${JSON.stringify(url)} && document.readyState === 'complete' && document.title.startsWith('Rail ')`));
  } catch (error) {
    console.error('Fixture requests:', requests, 'Page:', await evaluate(url, 'JSON.stringify({href:location.href,title:document.title,ready:document.readyState,body:document.documentElement.outerHTML.slice(0,400)})'));
    throw error;
  }
  return { id, url };
}
try {
  let s = await start();
  assert.equal(s.runtimeCount, 0); assert.equal(s.tabs.length, 3);
  await command('capture');
  passed('native shell starts with lazy, renderer-free blank tabs');
  const workA = await newTab('/work-a', { session: 'work' });
  await evaluate(workA.url, `document.cookie='identity=work; Path=/; Max-Age=86400'`);
  const workB = await newTab('/work-b', { session: 'work' });
  assert.equal(await evaluate(workB.url, 'document.cookie'), 'identity=work');
  passed('named Work tabs share cookies');
  const personal = await newTab('/personal', { session: 'personal' });
  assert.equal(await evaluate(personal.url, 'document.cookie'), '');
  await evaluate(personal.url, `document.cookie='identity=personal; Path=/; Max-Age=86400'`);
  assert.equal(await evaluate(workA.url, 'document.cookie'), 'identity=work');
  passed('Personal and Work sessions remain separate on the same origin');
  const externalPin = await newTab('/external-pin', { session: 'personal' });
  await command('pin', { tab: externalPin.id });
  const otherSpaceBlank = (await state()).tabs.find(t => t.space === 'research');
  await command('select', { tab: otherSpaceBlank.id });
  const tabCount = (await state()).tabs.length;
  const deepLink = origin + '/external-pin/message/42?view=full#reply';
  s = await command('externalURL', { url: deepLink });
  assert.equal(s.tabs.length, tabCount);
  assert.equal(s.activeTab, externalPin.id);
  assert.equal(s.activeSpace, 'work');
  assert.equal(s.tabs.find(t => t.id === externalPin.id).session, 'personal');
  assert.equal(await evaluate(deepLink, 'document.cookie'), 'identity=personal');
  assert.equal((await state()).tabs.find(t => t.id === otherSpaceBlank.id).url, 'about:blank');
  passed('external deep links reuse a pin across Spaces and keep its login instead of replacing a blank tab');
  await evaluate(deepLink, 'window.keptState = 42');
  await command('home');
  s = await command('externalURL', { url: deepLink });
  assert.equal(s.home, false);
  assert.equal(s.tabs.length, tabCount);
  assert.equal(await evaluate(deepLink, 'window.keptState'), 42);
  passed('opening the same external URL leaves Space home and preserves the loaded page');
  await command('select', { tab: otherSpaceBlank.id });
  await command('age', { tab: externalPin.id });
  await until('external pin sleeps', async () => { const t = (await state()).tabs.find(t => t.id === externalPin.id); return !t.loaded && !t.closing; });
  const pinRequests = requests.filter(url => url === '/external-pin').length;
  const sleepingLink = origin + '/external-pin/message/43';
  s = await command('externalURL', { url: sleepingLink });
  assert.equal(s.activeTab, externalPin.id);
  assert.equal(s.tabs.length, tabCount);
  assert.equal(await evaluate(sleepingLink, 'document.cookie'), 'identity=personal');
  assert.equal(requests.filter(url => url === '/external-pin').length, pinRequests);
  passed('external links wake a sleeping pin directly at the incoming address');
  await command('select', { tab: otherSpaceBlank.id });
  await command('age', { tab: externalPin.id });
  await until('external pin sleeps again', async () => { const t = (await state()).tabs.find(t => t.id === externalPin.id); return !t.loaded && !t.closing; });
  const queuedLink = origin + '/external-pin/message/45';
  s = await command('externalURL', { urls: [origin + '/external-pin/message/44', queuedLink] });
  assert.equal(s.tabs.length, tabCount);
  assert.equal(s.activeTab, externalPin.id);
  assert.equal(await evaluate(queuedLink, 'document.cookie'), 'identity=personal');
  passed('multiple external links received while a pin wakes load the final address in that pin');
  await command('pin', { tab: externalPin.id });
  await command('close', { tab: externalPin.id });
  await until('external pin removed', async () => !(await state()).tabs.some(t => t.id === externalPin.id));
  await command('select', { tab: workA.id });
  s = await command('externalURL', { url: origin + '/external-unmatched' });
  const unmatched = s.activeTab;
  assert.notEqual(unmatched, workA.id);
  assert.equal(s.tabs.length, tabCount);
  await target(origin + '/external-unmatched');
  await command('close', { tab: unmatched });
  await until('unmatched external tab removed', async () => !(await state()).tabs.some(t => t.id === unmatched));
  await command('select', { tab: otherSpaceBlank.id });
  s = await command('externalURL', { url: origin + '/external-blank' });
  assert.equal(s.activeTab, otherSpaceBlank.id);
  await target(origin + '/external-blank');
  await command('close', { tab: otherSpaceBlank.id });
  await until('external blank tab removed', async () => !(await state()).tabs.some(t => t.id === otherSpaceBlank.id));
  passed('unmatched external links still open new tabs or reuse the selected blank tab');
  await command('select', { tab: workA.id });
  s = await command('shortcut', { key: 't' });
  const blankChild = s.activeTab;
  assert.notEqual(blankChild, workA.id);
  assert.equal(s.tabs.find(t => t.id === blankChild).url, 'about:blank');
  await command('select', { tab: workB.id });
  await command('select', { tab: blankChild });
  s = await command('shortcut', { key: 'w' });
  assert.equal(s.activeTab, workA.id);
  assert.ok(!s.tabs.some(t => t.id === blankChild));
  passed('native CMD+T/CMD+W returns to the source rather than a newer selection or the first tab');
  const isolatedA = await newTab('/isolated-a', { isolated: true });
  assert.equal(await evaluate(isolatedA.url, 'document.cookie'), '');
  await evaluate(isolatedA.url, `document.cookie='identity=isolated-a; Path=/; Max-Age=86400'`);
  const isolatedB = await newTab('/isolated-b', { isolated: true });
  assert.equal(await evaluate(isolatedB.url, 'document.cookie'), '');
  assert.equal(await evaluate(isolatedA.url, 'document.cookie'), 'identity=isolated-a');
  passed('each isolated tab has its own cookie store');
  for (const [source, options, name] of [
    [workA, {}, 'middle-work'],
    [workA, { blank: true }, 'middle-blank'],
    [isolatedA, {}, 'middle-isolated'],
    [workA, { button: 'left', modifiers: 4 }, 'command-click'],
    [workA, { modifiers: 8 }, 'shift-middle'],
  ]) {
    await command('select', { tab: source.id });
    const before = (await state()).tabs.length;
    const destination = origin + '/' + name;
    await clickLink(source.url, destination, options);
    const opened = await until(`new tab for ${name}`, async () => (await state()).tabs.find(t => t.url === destination && t.id !== source.id));
    await target(destination);
    const current = await state();
    assert.equal(current.tabs.length, before + 1, 'Click opens exactly one new tab');
    assert.equal(current.tabs.find(t => t.id === source.id).url, source.url, 'Source page stays unchanged');
    assert.equal(current.activeTab, options.modifiers === 8 ? opened.id : source.id, 'Click respects foreground/background disposition');
    if (source === isolatedA) {
      assert.notEqual(opened.session, current.tabs.find(t => t.id === source.id).session);
      assert.equal(await evaluate(destination, 'document.cookie'), '');
    } else {
      assert.equal(opened.session, 'work');
      assert.equal(await evaluate(destination, 'document.cookie'), 'identity=work');
    }
    await command('select', { tab: workB.id });
    await command('select', { tab: opened.id });
    await command('shortcut', { key: 'w' });
    await until(`closed ${name}`, async () => !(await state()).tabs.some(t => t.id === opened.id));
    assert.equal((await state()).activeTab, source.id);
    passed(`${name} keeps its selection and session, then closes back to its source`);
  }
  await command('select', { tab: workA.id });
  await evaluate(workA.url, `void window.open(${JSON.stringify(origin + '/popup-work')})`);
  await target(origin + '/popup-work');
  const popupWork = (await state()).activeTab;
  assert.equal(await evaluate(origin + '/popup-work', 'document.cookie'), 'identity=work');
  assert.equal(await evaluate(origin + '/popup-work', 'window.opener !== null'), true);
  await evaluate(origin + '/popup-work', 'void window.close()');
  await until('script popup closes', async () => !(await state()).tabs.some(t => t.id === popupWork));
  assert.equal((await state()).activeTab, workA.id);
  passed('named-session popups share login and window.close removes their tab');
  await command('select', { tab: isolatedA.id });
  await evaluate(isolatedA.url, `void window.open(${JSON.stringify(origin + '/popup-isolated')})`);
  await target(origin + '/popup-isolated');
  const popupIsolated = (await state()).activeTab;
  assert.equal(await evaluate(origin + '/popup-isolated', 'document.cookie'), '');
  assert.notEqual((await state()).tabs.find(t => t.id === popupIsolated).session, (await state()).tabs.find(t => t.id === isolatedA.id).session);
  await command('close', { tab: popupIsolated });
  await until('isolated popup closes', async () => !(await state()).tabs.some(t => t.id === popupIsolated));
  assert.equal((await state()).activeTab, isolatedA.id);
  passed('popups from isolated tabs receive separate profiles');
  await command('select', { tab: isolatedB.id });
  await command('age', { tab: isolatedB.id });
  assert.equal((await state()).tabs.find(t => t.id === isolatedB.id).loaded, true);
  passed('idle policy protects the selected tab');
  await command('pin', { tab: workA.id });
  const oldTarget = (await target(workA.url)).id;
  await command('age', { tab: workA.id });
  await until('pinned idle browser closes', async () => { const t = (await state()).tabs.find(t => t.id === workA.id); return t?.pinned && !t.loaded && !t.closing; });
  assert.ok(!(await targets()).some(t => t.id === oldTarget));
  passed('idle pinned tab keeps metadata and destroys its Chromium page');
  await command('select', { tab: workA.id });
  assert.notEqual((await target(workA.url)).id, oldTarget);
  assert.equal(await evaluate(workA.url, 'document.cookie'), 'identity=work');
  passed('waking an unloaded tab creates a new page and keeps its login');
  await command('select', { tab: workB.id });
  await command('session', { tab: workB.id, session: 'personal' });
  await until('session replacement', async () => { const t = (await state()).tabs.find(t => t.id === workB.id); return t?.session === 'personal' && t.loaded && !t.closing; });
  assert.equal(await evaluate(workB.url, 'document.cookie'), 'identity=personal');
  assert.equal((await state()).tabs.find(t => t.id === workB.id).space, 'work');
  passed('changing a tab session replaces its context without moving its Space');
  await command('select', { tab: workA.id });
  await command('shortcut', { key: 's' }); assert.equal((await state()).sidebarVisible, false);
  await command('shortcut', { key: 's' }); assert.equal((await state()).sidebarVisible, true);
  await command('close', { tab: isolatedB.id });
  await until('close tab removes it', async () => !(await state()).tabs.some(t => t.id === isolatedB.id));
  assert.equal((await state()).activeTab, workA.id);
  passed('native CMD+S and background tab close preserve selection');
  const address = () => JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', resolve(profile, 'address.plist')]));
  await command('shortcut', { key: 'l' }); await pause(200);
  await command('keys', { text: '127.0.0' });
  let field = address();
  assert.ok(field.text.startsWith('127.0.0.1:') && !field.selection.endsWith(', 0}'), `history should be completed inline and selected: ${JSON.stringify(field)}`);
  await command('keys', { text: 'Z' });
  assert.equal(address().text, '127.0.0Z', 'typing over an inline completion should replace it');
  passed('typing replaces the address bar inline completion, as in Chrome');
  await command('select', { tab: isolatedA.id });
  await stop(); passed('CEF closes all browser views and exits cleanly');
  const savedState = JSON.parse(await readFile(resolve(profile, 'state.json'), 'utf8'));
  savedState.spaceRules.push({ pattern: `${origin}/middle-routed`.replace('http://', ''), spaceID: 'personal' });
  await writeFile(resolve(profile, 'state.json'), JSON.stringify(savedState));
  s = await start();
  assert.equal(s.activeTab, isolatedA.id);
  assert.ok(s.tabs.find(t => t.id === workA.id)?.pinned);
  await target(isolatedA.url);
  assert.equal(await evaluate(isolatedA.url, 'document.cookie'), 'identity=isolated-a');
  assert.equal((await state()).runtimeCount, 1);
  passed('restart restores layout, pins and isolated login; loads only selected tab');
  await command('select', { tab: workA.id });
  assert.equal(await evaluate(workA.url, 'document.cookie'), 'identity=work');
  passed('named session login persists after restart');
  await clickLink(workA.url, origin + '/middle-routed');
  const routed = await until('middle-click routed to Personal', async () => (await state()).tabs.find(t => t.url === origin + '/middle-routed'));
  assert.equal(routed.space, 'personal'); assert.equal(routed.session, 'personal');
  assert.equal((await state()).activeTab, workA.id);
  assert.equal((await state()).activeSpace, 'work');
  assert.equal(await evaluate(origin + '/middle-routed', 'document.cookie'), 'identity=personal');
  passed('middle-click respects Space rules and destination session while keeping the source selected');
  const plain = await newTab('/plain-click');
  const beforePlain = (await state()).tabs.length;
  await clickLink(plain.url, origin + '/plain-destination', { button: 'left' });
  await target(origin + '/plain-destination');
  assert.equal((await state()).tabs.length, beforePlain);
  assert.equal((await state()).activeTab, plain.id);
  passed('ordinary left-click still navigates in the current tab');
  await stop();
  console.log(`${checks} integration checks passed, 0 failed. Artifacts: ${profile}`);
} finally {
  if (child && child.exitCode === null) { child.kill('SIGTERM'); await childExit; }
  await new Promise(resolve => fixture.close(resolve));
}
