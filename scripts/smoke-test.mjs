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
  response.end(`<!doctype html><meta charset="utf-8"><title>Rail ${request.url}</title><style>body{font:18px system-ui;padding:48px;color:#273445}</style><h1>Rail browser test</h1><p>This page runs inside Chromium.</p><a href="/popup" target="_blank">Open another tab</a>`);
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
async function evaluate(url, expression) {
  const page = await target(url);
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  await once(socket, 'open');
  const response = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('CDP timeout')), 5000);
    socket.addEventListener('message', e => { const data = JSON.parse(e.data); if (data.id === 1) { clearTimeout(timer); data.error ? reject(new Error(data.error.message)) : resolve(data.result); } });
  });
  socket.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression, returnByValue: true, awaitPromise: true, userGesture: true } }));
  try { const result = await response; if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails)); return result.result.value; }
  finally { socket.close(); }
}
function passed(message) { checks++; console.log(`PASS ${message}`); }
async function start() {
  await rm(resolve(profile, 'automation-state.json'), { force: true });
  await rm(resolve(profile, 'automation-command.json'), { force: true });
  const log = openSync(resolve(profile, 'app.log'), 'a');
  child = spawn(resolve(root, 'build/Release/Eimerrail.app/Contents/MacOS/Eimerrail'), [`--data-dir=${profile}`, '--automation', `--debug-port=${debugPort}`], { stdio: ['ignore', log, log] });
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
  const isolatedA = await newTab('/isolated-a', { isolated: true });
  assert.equal(await evaluate(isolatedA.url, 'document.cookie'), '');
  await evaluate(isolatedA.url, `document.cookie='identity=isolated-a; Path=/; Max-Age=86400'`);
  const isolatedB = await newTab('/isolated-b', { isolated: true });
  assert.equal(await evaluate(isolatedB.url, 'document.cookie'), '');
  assert.equal(await evaluate(isolatedA.url, 'document.cookie'), 'identity=isolated-a');
  passed('each isolated tab has its own cookie store');
  await command('select', { tab: workA.id });
  await evaluate(workA.url, `void window.open(${JSON.stringify(origin + '/popup-work')})`);
  await target(origin + '/popup-work');
  const popupWork = (await state()).activeTab;
  assert.equal(await evaluate(origin + '/popup-work', 'document.cookie'), 'identity=work');
  await evaluate(origin + '/popup-work', 'void window.close()');
  await until('script popup closes', async () => !(await state()).tabs.some(t => t.id === popupWork));
  passed('named-session popups share login and window.close removes their tab');
  await command('select', { tab: isolatedA.id });
  await evaluate(isolatedA.url, `void window.open(${JSON.stringify(origin + '/popup-isolated')})`);
  await target(origin + '/popup-isolated');
  const popupIsolated = (await state()).activeTab;
  assert.equal(await evaluate(origin + '/popup-isolated', 'document.cookie'), '');
  assert.notEqual((await state()).tabs.find(t => t.id === popupIsolated).session, (await state()).tabs.find(t => t.id === isolatedA.id).session);
  await command('close', { tab: popupIsolated });
  await until('isolated popup closes', async () => !(await state()).tabs.some(t => t.id === popupIsolated));
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
  await stop();
  console.log(`${checks} integration checks passed, 0 failed. Artifacts: ${profile}`);
} finally {
  if (child && child.exitCode === null) { child.kill('SIGTERM'); await childExit; }
  await new Promise(resolve => fixture.close(resolve));
}
