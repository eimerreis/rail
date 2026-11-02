#!/usr/bin/env node
// A passkey sign-in that offers "use a phone" (hybrid transport, as on amazon.com) makes Chromium start
// Bluetooth discovery. Without NSBluetoothAlwaysUsageDescription macOS TCC aborts the whole app.
// Launch through LaunchServices so Rail is its own TCC-responsible process; spawned from a terminal,
// TCC would check the terminal's Info.plist instead and hide the crash.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, writeFile, rename } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
await mkdir(resolve(root, '.runtime-test'), { recursive: true });
const profile = await mkdtemp(resolve(root, '.runtime-test/passkey-'));
const fixture = createServer((req, res) => res.end('<!doctype html><title>Passkey</title><h1>Sign in</h1>'));
fixture.listen(0, '127.0.0.1'); await once(fixture, 'listening');
const url = `http://localhost:${fixture.address().port}/`;
const probe = createServer(); probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
const port = probe.address().port; await new Promise(resolve => probe.close(resolve));
const app = resolve(root, `build/${process.env.BUILD_TYPE ?? 'Release'}/Rail.app`);
const log = resolve(profile, 'app.log');
const child = spawn('/usr/bin/open', ['-n', '-W', '--stdout', log, '--stderr', log, app, '--args', `--data-dir=${profile}`, '--automation', `--debug-port=${port}`,
  // A crashed run makes AppKit ask about reopening windows, which blocks launch on a modal.
  '-ApplePersistenceIgnoreState', 'YES'], { stdio: 'ignore' });
const exited = once(child, 'exit');
let sequence = 0, quitting = false;
async function until(label, task, timeout = 15000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (child.exitCode !== null && !quitting) throw new Error(`App exited during ${label}. Check ~/Library/Logs/DiagnosticReports/Rail-*.ips. Artifacts: ${profile}`);
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
  await command('newTab', { url });
  const page = await until('fixture', async () => (await targets()).find(t => t.url === url && t.title === 'Passkey'));
  // Hybrid-only credentials send Chromium straight to the phone QR sheet, which powers up Bluetooth.
  // Fire and forget: the request stays pending while that sheet is open.
  await cdp(page, 'Runtime.evaluate', { userGesture: true, expression: `navigator.credentials.get({ publicKey: {
    challenge: new Uint8Array(32), rpId: 'localhost', timeout: 30000, hints: ['hybrid'],
    allowCredentials: [{ type: 'public-key', id: new Uint8Array(16), transports: ['hybrid'] }] } }).catch(() => {}); true` });
  const settle = Date.now() + 6000;
  await until('app survives passkey request', async () => Date.now() > settle && await state(), 10000);
  quitting = true;
  await command('quit');
  let timer;
  try { const [code] = await Promise.race([exited, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Quit hung after passkey request')), 15000); })]); assert.equal(code, 0); }
  finally { clearTimeout(timer); }
  console.log(`Passkey smoke passed: WebAuthn request did not crash Rail. Artifacts: ${profile}`);
} finally {
  // `open` only waits on Rail; stop Rail itself so a failed run leaves no instance behind.
  spawnSync('/usr/bin/pkill', ['-f', '--', `--data-dir=${profile}`]);
  if (child.exitCode === null) await exited;
  await new Promise(resolve => fixture.close(resolve));
}
