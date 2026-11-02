#!/usr/bin/env node
// Real Chromium navigation, native confirmation and macOS URL delivery. Node 22+.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, readFile, writeFile, rename } from 'node:fs/promises';
import { openSync, closeSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
await mkdir(resolve(root, '.runtime-test'), { recursive: true });
const profile = await mkdtemp(resolve(root, '.runtime-test/external-app-'));
const scheme = `rail-test-${randomUUID()}`;
const callback = `${scheme}://auth/callback?code=one%2Btwo%2Fthree%3D&state=a%26b#done`;
const appName = 'Rail Callback Test';
const receiver = resolve(profile, `${appName}.app`);
const receivedPath = resolve(profile, 'received.json');
const lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';
await mkdir(resolve(receiver, 'Contents/MacOS'), { recursive: true });
await writeFile(resolve(receiver, 'Contents/Info.plist'), JSON.stringify({
  CFBundleIdentifier: `de.eimerreis.${scheme}`, CFBundleName: appName,
  CFBundleExecutable: 'receiver', CFBundlePackageType: 'APPL', LSUIElement: true,
  CFBundleURLTypes: [{ CFBundleURLSchemes: [scheme], CFBundleURLName: scheme }],
  CallbackFile: receivedPath,
}));
execFileSync('plutil', ['-convert', 'xml1', resolve(receiver, 'Contents/Info.plist')]);
execFileSync('xcrun', ['clang++', '-fobjc-arc', '-framework', 'Cocoa', resolve(root, 'tests/ExternalAppFixture.mm'), '-o', resolve(receiver, 'Contents/MacOS/receiver')]);
execFileSync('codesign', ['--force', '--sign', '-', receiver], { stdio: 'pipe' });
execFileSync(lsregister, ['-f', receiver]);

const fixture = createServer((request, response) => {
  if (request.url === '/redirect') {
    response.writeHead(302, { Location: callback }); response.end(); return;
  }
  response.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
  response.end('<!doctype html><title>Callback fixture</title><h1>Desktop sign-in</h1>');
});
fixture.listen(0, '127.0.0.1'); await once(fixture, 'listening');
const origin = `http://127.0.0.1:${fixture.address().port}`;
const pageURL = `${origin}/auth`;
const probe = createServer(); probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
const debugPort = probe.address().port;
await new Promise(resolve => probe.close(resolve));
const log = openSync(resolve(profile, 'app.log'), 'a');
const child = spawn(process.env.RAIL_APP || resolve(root, 'build/Release/Rail.app/Contents/MacOS/Rail'),
  [`--data-dir=${profile}`, '--automation', `--debug-port=${debugPort}`], { stdio: ['ignore', log, log] });
closeSync(log);
const exited = once(child, 'exit');
let sequence = 0, checks = 0;
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(label, task, timeout = 10000) {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    if (child.exitCode !== null) throw new Error(`App exited during ${label}. See ${profile}/app.log`);
    try { const result = await task(); if (result) return result; } catch (error) { last = error; }
    await pause(80);
  }
  throw new Error(`Timed out: ${label}${last ? `: ${last.message}` : ''}. Artifacts: ${profile}`);
}
async function state() { return JSON.parse(await readFile(resolve(profile, 'automation-state.json'), 'utf8')); }
async function received() {
  try { return JSON.parse(await readFile(receivedPath, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return []; throw error; }
}
async function command(action, args = {}) {
  const id = String(++sequence);
  await writeFile(resolve(profile, 'command.tmp'), JSON.stringify({ id, action, ...args }));
  await rename(resolve(profile, 'command.tmp'), resolve(profile, 'automation-command.json'));
  if (action === 'quit') return;
  return until(`command ${action}`, async () => { const s = await state(); return s.command === id && s; });
}
async function evaluate(expression, { url = pageURL, gesture = false } = {}) {
  const target = await until(`page ${url}`, async () => (await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json()).find(t => t.type === 'page' && t.url === url));
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await once(socket, 'open');
  let timer;
  const reply = new Promise((resolve, reject) => {
    timer = setTimeout(() => reject(new Error('CDP timeout')), 5000);
    socket.addEventListener('message', event => { const result = JSON.parse(event.data); if (result.id === 1) result.error ? reject(new Error(result.error.message)) : resolve(result.result); });
  });
  socket.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression, returnByValue: true, userGesture: gesture } }));
  try { const result = await reply; if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails)); return result.result.value; }
  finally { clearTimeout(timer); socket.close(); }
}
async function prompt() {
  const s = await until('native Open application confirmation', async () => { const s = await state(); return s.sheet === 'open' && s; });
  const text = s.sheetText.join('\n');
  assert.ok(text.includes(`Open ${appName}?`), text);
  assert.ok(text.includes(origin), 'Prompt identifies the requesting origin, including port');
  assert.ok(!text.includes('one%2Btwo') && !text.includes('code='), 'Prompt must not expose callback credentials');
  return s;
}
async function dismiss(button = 'Cancel') {
  await command('sheet', { button });
  await until('confirmation closes', async () => (await state()).sheet === '');
}
function passed(label) { checks++; console.log(`PASS ${label}`); }
try {
  await until('native app startup', state, 25000);
  const initial = await command('newTab', { url: pageURL });
  await until('fixture loaded', async () => await evaluate("document.readyState === 'complete'"));

  await evaluate(`location.href = ${JSON.stringify(callback)}`);
  await prompt();
  assert.deepEqual(await received(), [], 'The app must not open before confirmation');
  await evaluate(`location.href = ${JSON.stringify(callback + '-repeat')}`);
  await dismiss();
  await pause(200);
  assert.equal((await state()).sheet, '', 'Repeated callbacks must not queue confirmations');
  assert.deepEqual(await received(), [], 'Cancel must not dispatch the callback');
  assert.equal(await evaluate('location.href'), pageURL);
  assert.equal((await state()).tabs.find(t => t.id === initial.activeTab).error, '');
  passed('automatic callback asks once; cancel keeps the auth page usable');

  await evaluate(`location.href = ${JSON.stringify(callback)}`);
  await prompt(); await dismiss(`Open ${appName}`);
  await until('macOS delivers callback unchanged', async () => (await received())[0] === callback);
  passed('Open delivers the exact callback, query and fragment to the desktop app');

  await evaluate("location.href = '/redirect'");
  await prompt(); await dismiss();
  assert.equal(await evaluate('location.href'), pageURL);
  passed('HTTP redirect to an app callback preserves the auth page');

  const beforePopup = (await state()).tabs.length;
  await evaluate(`void window.open(${JSON.stringify(callback)})`, { gesture: true });
  await prompt(); await dismiss();
  assert.equal((await state()).tabs.length, beforePopup, 'External popup must not leave an empty tab');
  passed('direct popup callback prompts without creating a tab');

  await evaluate(`void window.open(${JSON.stringify(origin + '/popup')})`, { gesture: true });
  await until('auth popup tab', async () => (await state()).tabs.length === beforePopup + 1);
  const popup = (await state()).activeTab;
  await evaluate(`location.href = ${JSON.stringify(callback)}`, { url: origin + '/popup' });
  await prompt();
  await command('close', { tab: popup });
  await until('closing source tab dismisses confirmation', async () => (await state()).sheet === '');
  await command('select', { tab: initial.activeTab });
  passed('auth popups support callbacks and closing one cancels its pending handoff');

  await evaluate(`location.href = ${JSON.stringify(callback)}`);
  await prompt();
  await evaluate("location.href = '/after-auth'");
  await until('navigation cancels stale confirmation', async () => (await state()).sheet === '');
  await command('navigate', { url: pageURL });
  await until('auth page reloaded', async () => await evaluate("document.readyState === 'complete'"));
  passed('navigating the source page cancels its pending handoff');

  await evaluate(`location.href = 'rail-missing-${randomUUID()}://auth'`);
  await until('missing handler message', async () => (await state()).status.includes('No application'));
  assert.equal((await state()).sheet, '');
  assert.equal(await evaluate('location.href'), pageURL);
  passed('missing applications leave the page intact with a useful message');

  await evaluate(`void window.open('file:///Applications/Calculator.app')`, { gesture: true });
  await pause(500);
  assert.equal((await state()).sheet, '');
  assert.equal((await state()).tabs.length, beforePopup);
  assert.deepEqual(await received(), [callback]);
  passed('local files never become external app launches');

  // CDP's earlier gesture remains active for several seconds, even when a
  // later evaluation sets userGesture:false. Exercise an actually idle page.
  await until('previous user activation expires', async () => !await evaluate('navigator.userActivation.isActive'));
  await evaluate(`{ const f = document.createElement('iframe'); f.src = ${JSON.stringify(callback)}; document.body.append(f); }`);
  await pause(500);
  assert.equal((await state()).sheet, '', 'Unprompted subframes cannot launch apps');
  assert.deepEqual(await received(), [callback]);
  passed('automatic iframe callbacks cannot prompt or launch an application');

  await command('quit');
  let timer;
  try { const [code] = await Promise.race([exited, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Quit hung')), 15000); })]); assert.equal(code, 0); }
  finally { clearTimeout(timer); }
  console.log(`${checks} external application checks passed, 0 failed. Artifacts: ${profile}`);
} finally {
  if (child.exitCode === null) { child.kill('SIGTERM'); await exited; }
  await new Promise(resolve => fixture.close(resolve));
  execFileSync(lsregister, ['-u', receiver]);
}
