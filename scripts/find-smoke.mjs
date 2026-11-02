#!/usr/bin/env node
// Native find bar and Chromium search, using a disposable profile and local pages.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, writeFile, rename } from 'node:fs/promises';
import { openSync, closeSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
await mkdir(resolve(root, '.runtime-test'), { recursive: true });
const profile = await mkdtemp(resolve(root, '.runtime-test/find-'));
const fixture = createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(`<!doctype html><title>Find fixture</title><p>Needle</p><p>needle</p><p>NEEDLE</p><p>日本語</p><div style="height:1800px"></div><p>needle at the bottom</p>`);
});
fixture.listen(0, '127.0.0.1'); await once(fixture, 'listening');
const url = `http://127.0.0.1:${fixture.address().port}/`;
const probe = createServer(); probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
const port = probe.address().port; await new Promise(resolve => probe.close(resolve));
const log = openSync(resolve(profile, 'app.log'), 'a');
const child = spawn(resolve(root, 'build/Release/Rail.app/Contents/MacOS/Rail'), [`--data-dir=${profile}`, '--automation', `--debug-port=${port}`], { stdio: ['ignore', log, log] });
closeSync(log);
const exited = once(child, 'exit');
let sequence = 0;
async function until(label, task, timeout = 15000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (child.exitCode !== null) throw new Error(`App exited during ${label}: ${child.exitCode}`);
    const result = await task(); if (result) return result;
    await new Promise(resolve => setTimeout(resolve, 80));
  }
  throw new Error(`Timed out: ${label}. Artifacts: ${profile}`);
}
const state = async () => { try { return JSON.parse(await readFile(resolve(profile, 'automation-state.json'), 'utf8')); } catch { return null; } };
async function command(action, args = {}) {
  const id = String(++sequence), tmp = resolve(profile, 'command.tmp');
  await writeFile(tmp, JSON.stringify({ id, action, ...args }));
  await rename(tmp, resolve(profile, 'automation-command.json'));
  if (action !== 'quit') return until(action, async () => { const s = await state(); return s?.command === id && s; });
}
const shortcut = (key, keyCode, modifiers = ['cmd']) => command('shortcut', { key, keyCode, modifiers });
const targets = async () => (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json());
async function evaluate(pageURL, expression) {
  const page = (await targets()).find(t => t.url === pageURL);
  const socket = new WebSocket(page.webSocketDebuggerUrl); await once(socket, 'open');
  try {
    const reply = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('CDP timeout')), 5000);
      socket.addEventListener('message', event => {
        const message = JSON.parse(event.data); if (message.id !== 1) return;
        clearTimeout(timer); message.error ? reject(new Error(message.error.message)) : resolve(message.result.result.value);
      });
    });
    socket.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression, returnByValue: true } }));
    return await reply;
  } finally { socket.close(); }
}
async function matches(count, ordinal) {
  return until(`${ordinal}/${count} matches`, async () => {
    const s = await state();
    return s?.find?.count === count && (ordinal === undefined || s.find.ordinal === ordinal) && !s.find.pending && s;
  });
}
try {
  await until('startup', state);
  await shortcut('f', 3);
  assert.equal((await state()).find.visible, false, 'An empty tab has no page to search');
  const initial = await command('newTab', { url });
  await until('fixture', async () => (await targets()).some(t => t.url === url && t.title === 'Find fixture'));
  let s = await shortcut('f', 3);
  assert.equal(s.sheet, '', 'Cmd+F must not open a modal sheet');
  assert.equal(s.find?.visible, true, 'Cmd+F opens the native find bar');
  assert.equal(s.find.focused, true);
  await command('keys', { text: 'needle' });
  await matches(4, 1);
  await command('capture');
  assert.equal((await state()).find.text, 'needle');
  await shortcut('\r', 36, []); await matches(4, 2);
  await shortcut('\r', 36, ['shift']); await matches(4, 1);
  await shortcut('g', 5, ['cmd', 'shift']); await matches(4, 4);
  assert.ok(await evaluate(url, 'scrollY > 500'), 'Chromium scrolls to a match below the fold');
  await shortcut('g', 5); await matches(4, 1);
  await command('findControl', { control: 'next' }); await matches(4, 2);
  await command('findControl', { control: 'previous' }); await matches(4, 1);
  await shortcut('f', 3);
  s = await state(); assert.equal(s.find.selection, '{0, 6}', 'Repeated Cmd+F selects the query');
  await command('keys', { text: 'absent' }); await matches(0, 0);
  assert.equal((await state()).find.label, '0/0');
  await shortcut('f', 3); await command('keys', { text: '\b' }); await matches(0, 0);
  assert.equal((await state()).find.text, '');
  await command('keys', { text: '日本語' }); await matches(1, 1);
  // A changed query searches from the current selection, as Chromium does.
  await shortcut('f', 3); await command('keys', { text: 'needle' }); await matches(4);
  await command('navigate', { url: `${url}?navigated` });
  await until('navigation', async () => (await targets()).some(t => t.url === `${url}?navigated` && t.title === 'Find fixture'));
  await matches(4, 1);
  const other = await command('newTab', { url: `${url}?other` });
  assert.equal(other.find.visible, false, 'Find visibility belongs to the tab');
  await until('other fixture', async () => (await targets()).some(t => t.url === `${url}?other` && t.title === 'Find fixture'));
  await shortcut('f', 3); await command('keys', { text: 'absent' }); await matches(0, 0);
  await command('select', { tab: initial.activeTab });
  s = await matches(4, 1); assert.equal(s.find.text, 'needle');
  await shortcut('f', 3);
  await shortcut('\u001b', 53, []);
  s = await state(); assert.equal(s.find.visible, false); assert.equal(s.find.focused, false);
  assert.equal(s.find.pageFocused, true, 'Escape returns focus to the page');
  await shortcut('f', 3); s = await matches(4, 1);
  assert.equal(s.find.text, 'needle', 'Reopening retains the query');
  await command('findControl', { control: 'close' });
  assert.equal((await state()).find.visible, false);
  await command('menu', { title: 'Find…' }); assert.equal((await state()).find.visible, true);
  await command('menu', { title: 'Find Next' }); await matches(4, 2);
  await command('menu', { title: 'Find Previous' }); await matches(4, 1);
  await command('home'); assert.equal((await state()).find.visible, false);
  await shortcut('f', 3); assert.equal((await state()).find.focused, false, 'Space home must not focus a hidden page find bar');
  await command('select', { tab: initial.activeTab }); assert.equal((await state()).find.visible, true);
  await command('close');
  await until('tab closes', async () => !(await state()).tabs.some(t => t.id === initial.activeTab));
  await command('quit');
  const [code] = await exited; assert.equal(code, 0);
  console.log(`Find integration passed: live case-insensitive search, counts, wraparound, scrolling, keyboard/buttons/menu, empty/missing/Unicode queries, tab isolation, navigation, reopen, focus and clean quit. Artifacts: ${profile}`);
} finally {
  if (child.exitCode === null) { child.kill('SIGKILL'); await exited; }
  await new Promise(resolve => fixture.close(resolve));
}
