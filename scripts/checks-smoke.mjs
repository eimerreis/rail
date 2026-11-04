#!/usr/bin/env node
// Checks integration test: the Capsule's states, Announcements, its list, Acknowledge, and what survives a restart.
// Uses a disposable profile. Automation commands stand in for provider checks, so no network is involved.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, mkdtemp, readFile, writeFile, rename, rm, copyFile } from 'node:fs/promises';
import { openSync, closeSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
await mkdir(resolve(root, '.runtime-test'), { recursive: true });
const profile = await mkdtemp(resolve(root, '.runtime-test/checks-'));
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
  // Chromium's teardown watchdog can end an otherwise clean quit with code 2; a signal would mean a crash.
  const [code, signal] = await Promise.race([exiting, pause(15000).then(() => { throw new Error('quit timed out'); })]);
  assert.ok(!signal && code !== null, `quit ended with ${signal ?? code}`); child = null;
}
async function capture(name) { await command('capture'); await pause(350); await command('capture'); await copyFile(resolve(profile, 'native-window.png'), resolve(profile, `${name}.png`)); }

const pr = (state, extra = {}) => ({ key: 'pr:1187', title: 'Handle transferred seats', project: 'License Service', number: '!1187', url: 'https://example.com/run/4', page: 'https://example.com/pr/1187', state, ...extra });
const e2e = { key: 'pr:611', title: 'Add invoice download', project: 'Customer Portal', number: '!611', url: 'https://example.com/run/5', page: 'https://example.com/pr/611', state: 'running', startedAgo: 240 };
const jitter = { key: 'pr:214', title: 'Add jitter to delivery backoff', project: 'Webhook Relay', number: '#214', url: 'https://example.com/run/6', page: 'https://example.com/pr/214', state: 'running', startedAgo: 60 };
const release = (state, revision = '41') => ({ key: 'run:release', kind: 'pipeline', title: 'release-prod', project: 'Billing API', number: '20261104.3', url: 'https://example.com/run/7', state, revision, startedAgo: 900 });

try {
  let s = await start();
  assert.equal(s.checks.visible, false); passed('the Capsule is hidden with nothing to follow');

  s = await command('trackedRuns', { runs: [pr('running'), e2e, jitter] });
  assert.equal(s.checks.visible, true); assert.equal(s.checks.running, 3); assert.equal(s.checks.announcing, ''); passed('the first check is quiet and shows what is running');
  await capture('compact');

  s = await command('trackedRuns', { runs: [pr('failed'), e2e, jitter] });
  assert.equal(s.checks.failed, 1); assert.equal(s.checks.announcing, 'Checks failed'); passed('a failure announces');
  await capture('announcing-failure');
  await pause(7000);
  assert.equal((await state()).checks.announcing, 'Checks failed'); passed('a failure stays announced');

  s = await command('trackedRuns', { runs: [pr('failed'), e2e, { ...jitter, state: 'passed' }, release('waiting')] });
  assert.equal(s.checks.waiting, 1); assert.equal(s.checks.passed, 1); assert.equal(s.checks.announcing, 'Checks failed'); passed('a failure outranks passes and approvals');

  s = await command('toggleChecks');
  assert.equal(s.checks.listOpen, true); assert.equal(s.checks.passed, 0); passed('opening the list resets the passed count');
  assert.deepEqual(s.checks.runs.map(r => r.key), ['pr:1187', 'run:release', 'pr:611', 'pr:214']); passed('the list leads with what needs you');
  await capture('list');
  await command('toggleChecks');

  s = await command('acknowledgeRun', { key: 'pr:1187' });
  assert.equal(s.checks.failed, 0); assert.equal(s.checks.runs.length, 4); passed('acknowledging clears the failed state but keeps it listed');

  await stop();
  s = await start();
  assert.equal(s.checks.failed, 0); assert.ok(s.checks.runs.find(r => r.key === 'pr:1187').acknowledged); passed('an acknowledgement survives a restart');
  s = await command('trackedRuns', { runs: [pr('failed'), { ...e2e, state: 'failed' }, { ...jitter, state: 'passed' }, release('waiting')] });
  assert.equal(s.checks.failed, 1); assert.equal(s.checks.announcing, ''); passed('what failed while closed shows without an announcement');
  await capture('after-restart');

  s = await command('trackedRuns', { runs: [pr('failed'), { ...e2e, state: 'failed' }, { ...jitter, state: 'passed' }, release('passed')] });
  assert.equal(s.checks.announcing, 'release-prod passed'); passed('a pass announces');
  await capture('announcing-pass');
  await until('the pass to settle', async () => (await state()).checks.announcing === '', 9000); passed('and settles back to counts');

  s = await command('trackedRuns', { runs: [pr('failed'), { ...e2e, state: 'failed' }, { ...jitter, state: 'passed' }, release('waiting', '42')], warnings: ['Sign in to Azure DevOps to keep checks up to date'] });
  assert.equal(s.checks.announcing, 'release-prod waiting for approval'); passed('waiting for approval announces');
  await capture('announcing-waiting');
  await until('the approval to settle', async () => (await state()).checks.announcing === '', 9000);
  await capture('waiting-and-warning');
  s = await command('toggleChecks'); await capture('list-with-warning'); await command('toggleChecks');

  await command('activity');
  s = await command('showRunInActivity', { key: 'pr:611' });
  assert.equal(s.checks.failed, 0); passed('Show in Activity acknowledges');

  await stop();
  console.log(`${checks} checks passed. Screenshots in ${profile}`);
} catch (error) {
  console.error(error);
  if (child) child.kill('SIGKILL');
  process.exitCode = 1;
}
