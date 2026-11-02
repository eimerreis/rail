#!/usr/bin/env node
// Exercise the actual DevTools window with a disposable browser profile.
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
const profile = await mkdtemp(resolve(root, '.runtime-test/devtools-'));
const fixture = createServer((req, res) => res.end('<!doctype html><title>Inspect me</title><h1 id="inspect-me">DevTools fixture</h1>'));
fixture.listen(0, '127.0.0.1'); await once(fixture, 'listening');
const url = `http://127.0.0.1:${fixture.address().port}/`;
const probe = createServer(); probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
const port = probe.address().port; await new Promise(resolve => probe.close(resolve));
const log = openSync(resolve(profile, 'app.log'), 'a');
const child = spawn(resolve(root, 'build/Release/Eimerrail.app/Contents/MacOS/Eimerrail'), [`--data-dir=${profile}`, '--automation', `--debug-port=${port}`], { stdio: ['ignore', log, log] });
closeSync(log);
const exited = once(child, 'exit');
let sequence = 0;
async function until(label, task, timeout = 15000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (child.exitCode !== null) throw new Error(`App exited during ${label}: ${child.exitCode}`);
    try { const result = await task(); if (result) return result; } catch { /* Startup/state writes may be in progress. */ }
    await new Promise(resolve => setTimeout(resolve, 80));
  }
  throw new Error(`Timed out: ${label}. Artifacts: ${profile}`);
}
const state = async () => JSON.parse(await readFile(resolve(profile, 'automation-state.json'), 'utf8'));
async function command(action, args = {}) {
  const id = String(++sequence), tmp = resolve(profile, 'command.tmp');
  await writeFile(tmp, JSON.stringify({ id, action, ...args }));
  await rename(tmp, resolve(profile, 'automation-command.json'));
  if (action !== 'quit') return until(action, async () => { const s = await state(); return s.command === id && s; });
}
const targets = async () => (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json());
const devtools = async () => (await targets()).filter(t => t.url.startsWith('devtools://'));
async function cdp(page, method, params = {}) {
  const socket = new WebSocket(page.webSocketDebuggerUrl); await once(socket, 'open');
  try {
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`CDP timeout: ${method}`)), 5000);
      socket.addEventListener('message', event => {
        const message = JSON.parse(event.data); if (message.id !== 1) return;
        clearTimeout(timer); message.error ? reject(new Error(message.error.message)) : resolve(message.result);
      });
      socket.send(JSON.stringify({ id: 1, method, params }));
    });
  } finally { socket.close(); }
}
try {
  await until('startup', state);
  await command('menu', { title: 'Developer Tools' });
  assert.equal((await devtools()).length, 0, 'Blank tabs have no page to inspect');
  const initial = await command('newTab', { url });
  await until('fixture', async () => (await targets()).some(t => t.url === url && t.title === 'Inspect me'));
  const toggle = (window) => command('shortcut', { key: 'i', keyCode: 34, modifiers: ['cmd', 'alt'], window });
  const open = () => toggle();
  await open();
  const first = await until('Option-Command-I opens DevTools', async () => (await devtools())[0], 6000);
  await until('DevTools frontend loads', async () => {
    const result = await cdp(first, 'Runtime.evaluate', { expression: "document.readyState === 'complete' && !!document.querySelector('.root-view')", returnByValue: true });
    return result.result.value;
  });
  assert.equal((await state()).tabs.length, initial.tabs.length, 'DevTools must not become an ordinary tab');
  assert.equal((await state()).activeTab, initial.activeTab);
  const inspectorWindow = await until('DevTools is the key window', async () => {
    const s = await state(); return !s.keyWindow.main && s.keyWindow;
  });
  assert.equal(inspectorWindow.closable, true, 'DevTools must have a native close control');
  assert.equal(inspectorWindow.closeEnabled, true, 'The DevTools close button must be enabled');
  await command('closeWindow');
  await until('native close button closes inspector', async () => !(await devtools()).length);
  assert.ok((await targets()).some(t => t.url === url), 'Closing DevTools must keep the inspected page');
  await open();
  await until('inspector reopens after native close', async () => (await devtools()).length === 1);
  assert.equal((await command('focusMainWindow')).keyWindow.main, true, 'Focus the page before toggling DevTools');
  await open();
  await until('shortcut toggles inspector closed', async () => !(await devtools()).length);
  await open();
  await until('inspector reopens after toggle', async () => (await devtools()).length === 1);
  await toggle('key');
  await until('shortcut closes focused inspector', async () => !(await devtools()).length);
  await open();
  await until('inspector reopens after focused toggle', async () => (await devtools()).length === 1);
  await command('shortcut', { key: 'w', keyCode: 13, window: 'key' });
  await until('inspector closes independently', async () => !(await devtools()).length);
  assert.ok((await targets()).some(t => t.url === url), 'Closing DevTools must keep the inspected page');
  await command('menu', { title: 'Developer Tools' });
  await until('inspector reopens', async () => (await devtools()).length === 1);
  await command('focusMainWindow');
  await command('menu', { title: 'Developer Tools' });
  await until('menu toggles inspector closed', async () => !(await devtools()).length);
  assert.equal((await state()).activeTab, initial.activeTab, 'Closing DevTools must keep the selected tab');
  await command('menu', { title: 'Developer Tools' });
  await until('inspector reopens after menu toggle', async () => (await devtools()).length === 1);
  await command('close');
  await until('closing inspected tab closes inspector', async () => !(await devtools()).length && !(await state()).tabs.some(t => t.id === initial.activeTab));
  const next = await command('newTab', { url });
  await until('second fixture', async () => (await targets()).some(t => t.url === url));
  await open(); await until('inspector before quit', async () => (await devtools()).length === 1);
  assert.equal((await state()).activeTab, next.activeTab);
  await command('quit');
  let timer;
  try { const [code] = await Promise.race([exited, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Quit hung with DevTools open')), 15000); })]); assert.equal(code, 0); }
  finally { clearTimeout(timer); }
  console.log(`DevTools integration passed: blank tab, loaded frontend, native close button, shortcut toggle from page and inspector, Cmd+W, menu toggle, tab cleanup, clean quit. Artifacts: ${profile}`);
} finally {
  if (child.exitCode === null) { child.kill('SIGTERM'); await exited; }
  await new Promise(resolve => fixture.close(resolve));
}
