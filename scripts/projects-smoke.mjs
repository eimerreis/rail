#!/usr/bin/env node
// Projects integration check: Space home (Projects and Activity), health checks, sign-in states, opening environments, persistence.
// Uses a disposable profile, a localhost fixture, example.com (reachable) and a .invalid host (unreachable).
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, mkdtemp, readFile, writeFile, rename, rm, copyFile } from 'node:fs/promises';
import { openSync, closeSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
await mkdir(resolve(root, '.runtime-test'), { recursive: true });
const profile = await mkdtemp(resolve(root, '.runtime-test/projects-'));
const fixture = createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'application/json', 'X-Version': '2.31.0' });
  res.end(JSON.stringify({ status: 'ok', path: req.url }));
});
fixture.listen(0, '127.0.0.1'); await once(fixture, 'listening');
const localPort = fixture.address().port;
const closed = createServer(); closed.listen(0, '127.0.0.1'); await once(closed, 'listening');
const stoppedPort = closed.address().port; await new Promise(r => closed.close(r));

const Health = { unknown: 0, up: 1, slow: 2, down: 3, notRunning: 4, loginRequired: 5 };
let child, sequence = 0, checks = 0;
const pause = ms => new Promise(r => setTimeout(r, ms));
async function until(label, task, timeout = 20000) {
  const end = Date.now() + timeout; let last;
  while (Date.now() < end) {
    if (child?.exitCode !== null && child?.exitCode !== undefined) throw new Error(`App exited during ${label}. See ${profile}/app.log`);
    try { const v = await task(); if (v) return v; } catch (e) { last = e; }
    await pause(100);
  }
  throw new Error(`Timed out: ${label}${last ? `: ${last.message}` : ''}`);
}
const state = async () => JSON.parse(await readFile(resolve(profile, 'automation-state.json'), 'utf8'));
async function command(action, args = {}) {
  const id = String(++sequence); const tmp = resolve(profile, 'command.tmp');
  await writeFile(tmp, JSON.stringify({ id, action, ...args }));
  await rename(tmp, resolve(profile, 'automation-command.json'));
  if (action === 'quit') return;
  return until(`command ${action}`, async () => { const s = await state(); return s.command === id && s; });
}
function passed(message) { checks++; console.log(`PASS ${message}`); }
async function start() {
  await rm(resolve(profile, 'automation-state.json'), { force: true });
  await rm(resolve(profile, 'automation-command.json'), { force: true });
  const log = openSync(resolve(profile, 'app.log'), 'a');
  child = spawn(resolve(root, 'build/Release/Rail.app/Contents/MacOS/Rail'), [`--data-dir=${profile}`, '--automation'], { stdio: ['ignore', log, log] });
  closeSync(log);
  return until('startup', state, 30000);
}
async function stop() {
  const exiting = once(child, 'exit'); await command('quit');
  const [code] = await Promise.race([exiting, pause(15000).then(() => { throw new Error('quit timed out'); })]);
  assert.equal(code, 0); child = null;
}
const project = (s, name) => s.projects.find(p => p.name === name);
const env = (s, projectName, envName) => project(s, projectName)?.environments.find(e => e.name === envName);

try {
  await start();
  await command('home');
  assert.equal((await state()).home, true); passed('Space home opens');
  await command('capture'); await copyFile(resolve(profile, 'native-window.png'), resolve(profile, 'home-empty.png'));

  await command('addProject', { name: 'Billing API', repo: 'https://dev.azure.com/contoso/Billing/_git/billing-api', session: 'work' });
  await command('addEnvironment', { project: 'Billing API', name: 'Local', url: `http://localhost:${localPort}`, session: 'work' });
  await command('addEnvironment', { project: 'Billing API', name: 'INT', url: 'https://example.com', session: 'work' });
  await command('addEnvironment', { project: 'Billing API', name: 'PROD', url: 'https://billing.rail-test.invalid', session: '__isolated__' });
  await command('addLink', { project: 'Billing API', label: 'LaunchDarkly', url: 'https://app.launchdarkly.com/billing/production/features', session: 'work' });
  await command('addProject', { name: 'Webhook Relay', repo: 'https://github.com/contoso/webhook-relay', session: 'work' });
  await command('addEnvironment', { project: 'Webhook Relay', name: 'Local', url: `http://127.0.0.1:${stoppedPort}`, session: 'work' });
  let s = await state();
  assert.equal(s.projects.length, 2); assert.equal(project(s, 'Billing API').links, 3);
  assert.match(env(s, 'Billing API', 'PROD').session, /^isolated-env-/);
  passed('projects, environments and links are added; PROD gets its own isolated profile');

  await command('checkProjects');
  s = await until('health results', async () => {
    const v = await state();
    const done = ['Local', 'INT', 'PROD'].every(n => env(v, 'Billing API', n)?.health) && env(v, 'Webhook Relay', 'Local')?.health;
    return done && v;
  }, 30000);
  assert.equal(env(s, 'Billing API', 'Local').health, Health.up, 'running local server is up');
  assert.ok([Health.up, Health.slow].includes(env(s, 'Billing API', 'INT').health), 'example.com answers');
  assert.equal(env(s, 'Billing API', 'PROD').health, Health.down, 'unresolvable host is down');
  assert.equal(env(s, 'Webhook Relay', 'Local').health, Health.notRunning, 'closed port is not running');
  passed('health: local up, remote up, remote down, local not running');

  // Azure DevOps answers anonymously in an empty session; GitHub has no token yet. Both ask for sign-in.
  s = await until('sign-in attention', async () => { const v = await state(); return project(v, 'Billing API').attention >= 2 && project(v, 'Webhook Relay').attention >= 1 && v; }, 30000);
  passed('signed-out Azure DevOps session and missing GitHub sign-in become attention items');
  await pause(500); await command('capture'); await copyFile(resolve(profile, 'native-window.png'), resolve(profile, 'home-cards.png'));

  await command('activity');
  s = await state();
  assert.equal(s.home, true); assert.equal(s.homePage, 'activity');
  await pause(300); await command('capture'); await copyFile(resolve(profile, 'native-window.png'), resolve(profile, 'home-activity.png'));
  await command('home');
  assert.equal((await state()).homePage, 'projects');
  passed('Activity page opens and switches back to Projects');

  await command('openEnvironment', { project: 'Billing API', name: 'INT' });
  s = await state();
  assert.equal(s.home, false);
  const opened = s.tabs.find(t => t.id === s.activeTab);
  assert.match(opened.url, /^https:\/\/example\.com/); assert.equal(opened.session, 'work');
  await command('home');
  await command('openEnvironment', { project: 'Billing API', name: 'INT' });
  assert.equal((await state()).tabs.filter(t => t.url.startsWith('https://example.com')).length, 1, 'existing tab is reused');
  await command('home');
  await command('openEnvironment', { project: 'Billing API', name: 'PROD' });
  s = await state();
  assert.equal(s.tabs.find(t => t.id === s.activeTab).session, env(s, 'Billing API', 'PROD').session);
  passed('environments open in their session, reuse an open tab, and PROD uses its isolated profile');

  await stop();
  s = await start();
  assert.equal(s.projects.length, 2); assert.equal(project(s, 'Billing API').environments.length, 3);
  assert.ok(s.tabs.some(t => t.session === env(s, 'Billing API', 'PROD').session), 'tab keeps the project profile after restart');
  passed('projects and project-profile tabs persist across restart');
  await stop();
  console.log(`\n${checks} project checks passed. Screenshots: ${profile}/home-empty.png, home-cards.png, home-activity.png`);
} catch (error) {
  console.error(`FAIL ${error.message}`);
  if (child) child.kill();
  process.exitCode = 1;
} finally {
  fixture.close();
}
