#!/usr/bin/env node
// Real CEF visibility/media deferral, without proprietary codecs or external sites.
// Node 22+, macOS Rail.app and ffmpeg with libvpx/libopus required. --check-fixture is portable.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, writeFile, rename, rm } from 'node:fs/promises';
import { openSync, closeSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const html = await readFile(resolve(root, 'tests/fixtures/background-media.html'), 'utf8');
// An uncompressed PCM tone works with the official CEF build, unlike H.264/AAC.
const samples = 8000 * 30, tone = Buffer.alloc(44 + samples * 2);
tone.write('RIFF'); tone.writeUInt32LE(tone.length - 8, 4); tone.write('WAVEfmt ', 8);
tone.writeUInt32LE(16, 16); tone.writeUInt16LE(1, 20); tone.writeUInt16LE(1, 22);
tone.writeUInt32LE(8000, 24); tone.writeUInt32LE(16000, 28); tone.writeUInt16LE(2, 32); tone.writeUInt16LE(16, 34);
tone.write('data', 36); tone.writeUInt32LE(samples * 2, 40);
for (let i = 0; i < samples; i++) tone.writeInt16LE(Math.round(4000 * Math.sin(i * 2 * Math.PI * 440 / 8000)), 44 + i * 2);

if (process.argv.includes('--check-fixture')) {
  // Syntax and format checks only, not a substitute for the native smoke.
  new Function(html.match(/<script>([\s\S]*)<\/script>/)[1]);
  assert.equal(tone.toString('ascii', 0, 4), 'RIFF');
  assert.equal(tone.readUInt32LE(40), tone.length - 44);
  assert.equal(tone.readUInt16LE(20), 1);
  assert.ok(html.includes('media.play()') && html.includes('iframe') && html.includes('target="_blank"'));
  console.log('PASS local media fixture JavaScript and PCM WAV format (no native playback tested)');
  process.exit(0);
}
assert.equal(process.platform, 'darwin', 'Native smoke requires macOS; use --check-fixture on Linux');
await mkdir(resolve(root, '.runtime-test'), { recursive: true });
const profile = await mkdtemp(resolve(root, '.runtime-test/background-media-'));
const clip = resolve(profile, 'clip.webm');
execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
  'testsrc2=size=160x90:rate=10', '-f', 'lavfi', '-i', 'sine=frequency=330:sample_rate=48000',
  '-t', '10', '-c:v', 'libvpx', '-c:a', 'libopus', clip]);
const video = await readFile(clip), events = new Map();
const fixture = createServer((req, res) => {
  const url = new URL(req.url, 'http://fixture');
  if (url.pathname === '/event') {
    const key = `${url.searchParams.get('case')}:${url.searchParams.get('media')}`;
    events.set(key, (events.get(key) || 0) + 1); res.writeHead(204); res.end(); return;
  }
  const bytes = url.pathname === '/tone.wav' ? tone : url.pathname === '/clip.webm' ? video : html;
  res.writeHead(200, { 'Content-Type': bytes === tone ? 'audio/wav' : bytes === video ? 'video/webm' : 'text/html', 'Cache-Control': 'no-store' });
  res.end(bytes);
});
fixture.listen(0, '127.0.0.1'); await once(fixture, 'listening');
const origin = `http://127.0.0.1:${fixture.address().port}`, launcherURL = `${origin}/launcher`;
const probe = createServer(); probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
const port = probe.address().port; await new Promise(resolve => probe.close(resolve));
const app = resolve(process.env.RAIL_TEST_APP || resolve(root, 'build/Release/Rail.app'));
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
let child, exited, sequence = 0;
function launch() {
  const log = openSync(resolve(profile, 'app.log'), 'a');
  // Avoid a false pass caused by Chrome's gesture/engagement autoplay policy.
  // Hidden-page load deferral is independent of this switch. Never emulate focus.
  child = spawn(resolve(app, 'Contents/MacOS/Rail'), [`--data-dir=${profile}`, '--automation', `--debug-port=${port}`,
    '--autoplay-policy=no-user-gesture-required', ...(process.env.RAIL_TEST_MOCK_KEYCHAIN === '1' ? ['--use-mock-keychain'] : [])], { stdio: ['ignore', log, log] });
  closeSync(log); exited = once(child, 'exit');
}
async function until(label, task, timeout = 20000) {
  const end = Date.now() + timeout; let last;
  while (Date.now() < end) {
    if (child.exitCode !== null) throw new Error(`App exited during ${label}: ${child.exitCode}`);
    try { const result = await task(); if (result) return result; } catch (error) { last = error; }
    await pause(100);
  }
  throw new Error(`Timed out: ${label}${last ? `: ${last.message}` : ''}. Artifacts: ${profile}`);
}
const state = async () => JSON.parse(await readFile(resolve(profile, 'automation-state.json'), 'utf8'));
async function command(action, args = {}) {
  const id = String(++sequence), tmp = resolve(profile, 'command.tmp');
  await writeFile(tmp, JSON.stringify({ id, action, ...args }));
  await rename(tmp, resolve(profile, 'automation-command.json'));
  if (action !== 'quit') return until(action, async () => { const s = await state(); return s.command === id && s; });
}
async function pages() { return (await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(2000) })).json(); }
const pageFor = address => until(`page ${address}`, async () => (await pages()).find(p => p.type === 'page' && p.url === address));
async function cdp(page, method, params = {}) {
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  try {
    await once(socket, 'open', { signal: AbortSignal.timeout(5000) });
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
async function evaluate(page, expression) {
  const result = await cdp(page, 'Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
async function click(page, selector, button = 'left', modifiers = 0) {
  const point = await evaluate(page, `(() => { const el=document.querySelector(${JSON.stringify(selector)}); el.scrollIntoView(); const r=el.getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2}; })()`);
  for (const type of ['mousePressed', 'mouseReleased']) await cdp(page, 'Input.dispatchMouseEvent', { type, ...point, button, modifiers, clickCount: 1 });
}
async function tabFor(address) {
  return until(`tab ${address}`, async () => (await state()).tabs.find(t => t.url === address && t.loaded));
}
async function blocked(address, key) {
  const tab = await tabFor(address), page = await pageFor(address);
  assert.ok(tab.initialMediaHeld, 'unvisited browser must retain its one-shot gate');
  await until('ordinary page and iframe script load in background', () => evaluate(page,
    'fixture.ready && fixture.ticks > 1 && document.querySelector("iframe").contentWindow.fixture?.ready'));
  assert.equal(await evaluate(page, 'document.visibilityState'), 'hidden', `${key}: Chromium must receive hidden-page visibility before media is checked`);
  // Observe actual playback events as well as the clock: muting or pausing after
  // playback starts must not count as successfully preventing initial playback.
  for (let i = 0; i < 10; i++) {
    const media = await evaluate(page, `[document, document.querySelector('iframe').contentDocument].flatMap(d => [...d.querySelectorAll('audio,video')].map(m => ({time:m.currentTime,error:m.error?.code || 0})))`);
    assert.equal(media.length, 4);
    assert.ok(media.every(m => m.time === 0 && !m.error), `${key}: ${JSON.stringify(media)}`);
    for (const suffix of ['', '-child']) for (const tag of ['audio', 'video']) assert.equal(events.get(`${key}${suffix}:${tag}`) || 0, 0, `premature ${key}${suffix} ${tag} playback`);
    await pause(100);
  }
  return { tab, page };
}
async function playing(page, key) {
  await until(`first activation plays ${key} audio/video and iframe`, async () => {
    const media = await evaluate(page, `[document, document.querySelector('iframe').contentDocument].flatMap(d => [...d.querySelectorAll('audio,video')].map(m => ({time:m.currentTime,paused:m.paused,error:m.error?.code || 0})))`);
    return media.length === 4 && media.every(m => m.time > 0.2 && !m.paused && !m.error)
      && ['', '-child'].every(suffix => ['audio', 'video'].every(tag => events.get(`${key}${suffix}:${tag}`) > 0));
  });
}
async function quit() {
  await command('quit');
  let timer;
  try {
    const [code] = await Promise.race([exited, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Quit timed out')), 15000); })]);
    assert.equal(code, 0);
  } finally { clearTimeout(timer); }
}
try {
  launch(); await until('startup', state);
  const source = (await command('newTab', { url: launcherURL, session: 'work' })).activeTab;
  const launcher = await pageFor(launcherURL);
  await until('launcher initializes', () => evaluate(launcher, 'window.fixture?.ready'));
  await evaluate(launcher, 'document.cookie="openerMarker=named; Path=/"; true');
  // An active control proves that the fixture actually autoplays in this engine.
  const controlURL = `${origin}/player?case=control`;
  const control = await command('newTab', { url: controlURL });
  await playing(await pageFor(controlURL), 'control');
  await command('select', { tab: source });
  await command('close', { tab: control.activeTab });

  for (const key of ['middle', 'cmd', 'context', 'target', 'popup']) {
    if (key === 'context') {
      await rm(resolve(profile, 'context-menu.json'), { force: true });
      await writeFile(resolve(profile, 'context-menu-choice.txt'), 'Open Link in New Tab');
      await click(launcher, '#context', 'right');
    } else await click(launcher, `#${key}`, ['middle', 'target'].includes(key) ? 'middle' : 'left', ['cmd', 'popup'].includes(key) ? 4 : 0);
    const address = `${origin}/player?case=${key}`, { tab, page } = await blocked(address, key);
    assert.equal((await state()).activeTab, source, `${key} must remain background`);
    assert.equal(tab.session, 'work', `${key} must retain the named session`);
    assert.ok((await evaluate(page, 'document.cookie')).includes('openerMarker=named'), 'shared session cookies must remain available during background loading');
    if (key === 'popup') assert.ok(await evaluate(page, '!!window.opener'), 'initially blank named-session popup must retain its opener');
    await command('select', { tab: tab.id }); await playing(page, key);
    assert.equal(await evaluate(page, 'document.visibilityState'), 'visible');
    await evaluate(page, 'document.querySelector("video").muted=false; true');
    const before = await evaluate(page, '[...document.querySelectorAll("audio,video")].map(m=>m.currentTime)');
    await command('select', { tab: source });
    await until('intentional background audio/video keeps advancing', async () => (await evaluate(page, '[...document.querySelectorAll("audio,video")].map(m=>m.currentTime)')).every((time, i) => time > before[i] + 0.25));
    assert.ok(!(await state()).tabs.find(t => t.id === tab.id).initialMediaHeld, 'switching away must not rearm the gate');
    assert.equal(await evaluate(page, 'document.querySelector("audio").muted'), false);
    // Playlist-like new media loads must keep working after the initial play.
    await evaluate(page, 'window.nextTrack = new Audio("/tone.wav?next"); nextTrack.volume=.02; nextTrack.play(); true');
    await until('background playlist track advances', () => evaluate(page, 'nextTrack.currentTime > .2 && !nextTrack.paused'));
    await command('close', { tab: tab.id });
  }

  const foregroundURL = `${origin}/player?case=foreground`;
  await evaluate(launcher, `document.querySelector('#middle').href=${JSON.stringify(foregroundURL)}; true`);
  await click(launcher, '#middle', 'middle', 8);
  const foreground = await tabFor(foregroundURL);
  assert.equal((await state()).activeTab, foreground.id, 'Shift-middle-click must still activate immediately');
  await playing(await pageFor(foregroundURL), 'foreground');
  await command('select', { tab: source }); await command('close', { tab: foreground.id });

  const isolatedURL = `${origin}/launcher?isolated`;
  const isolatedSource = (await command('newTab', { url: isolatedURL, isolated: true })).activeTab;
  const isolatedLauncher = await pageFor(isolatedURL);
  await until('isolated launcher initializes', () => evaluate(isolatedLauncher, 'window.fixture?.ready'));
  await evaluate(isolatedLauncher, 'document.cookie="openerMarker=isolated; Path=/"; document.querySelector("#cmd").href="/player?case=isolated"; true');
  await click(isolatedLauncher, '#cmd', 'left', 4);
  const isolated = await blocked(`${origin}/player?case=isolated`, 'isolated');
  const sourceSession = (await state()).tabs.find(t => t.id === isolatedSource).session;
  assert.ok(isolated.tab.session.startsWith('isolated-') && isolated.tab.session !== sourceSession, 'isolated background links need their own profile');
  assert.ok(!(await evaluate(isolated.page, 'document.cookie')).includes('openerMarker='), 'isolated background tab must not inherit opener cookies');
  await command('select', { tab: isolated.tab.id }); await playing(isolated.page, 'isolated');
  await command('select', { tab: source });
  await command('close', { tab: isolated.tab.id }); await command('close', { tab: isolatedSource });

  // A routed tab can be the remembered selection of another Space, without
  // ever being active in Rail. Named-session identity follows that Space.
  await command('spaceRules', { space: 'personal', pattern: `${new URL(origin).host}/space/**` });
  const spaceURL = `${origin}/space/player?case=space`;
  await command('backgroundLink', { tab: source, url: spaceURL });
  const routed = await blocked(spaceURL, 'space');
  assert.equal(routed.tab.space, 'personal'); assert.equal(routed.tab.session, 'personal');
  assert.equal((await state()).activeSpace, 'work');
  await command('space', { space: 'personal' }); await playing(routed.page, 'space');
  const beforeSpace = await evaluate(routed.page, 'document.querySelector("audio").currentTime');
  await command('space', { space: 'work' });
  await until('Space switch keeps playing audio', async () => (await evaluate(routed.page, 'document.querySelector("audio").currentTime')) > beforeSpace + .25);
  await command('close', { tab: routed.tab.id });

  await command('reading');
  const readingURL = `${origin}/player?case=reading`;
  await command('backgroundLink', { tab: source, url: readingURL });
  const reading = await blocked(readingURL, 'reading');
  assert.ok((await state()).readingVisible);
  await command('select', { tab: reading.tab.id }); await playing(reading.page, 'reading');
  await command('select', { tab: source }); await command('close', { tab: reading.tab.id });

  // Creation behind a native page must not briefly present media or steal focus.
  await command('home');
  const homeURL = `${origin}/player?case=home`;
  await command('backgroundLink', { tab: source, url: homeURL });
  const home = await blocked(homeURL, 'home');
  assert.ok((await state()).home);
  await command('select', { tab: home.tab.id }); await playing(home.page, 'home');
  await command('select', { tab: source });
  await command('age', { tab: home.tab.id });
  await until('idle unload tears down browser', async () => !(await state()).tabs.find(t => t.id === home.tab.id).loaded);
  await command('select', { tab: home.tab.id }); await playing(await pageFor(homeURL), 'home');
  // Session changes recreate Chromium, but must preserve active playback policy.
  await command('session', { tab: home.tab.id, session: 'personal' });
  await until('session replacement', async () => { const t=(await state()).tabs.find(t => t.id === home.tab.id); return t.session === 'personal' && t.loaded; });
  await playing(await pageFor(homeURL), 'home');
  await command('select', { tab: source });
  const neverURL = `${origin}/player?case=never`;
  await command('backgroundLink', { tab: source, url: neverURL });
  const never = await blocked(neverURL, 'never');
  await quit();
  for (const file of ['automation-state.json', 'automation-command.json']) await rm(resolve(profile, file), { force: true });
  launch(); await until('relaunch', state);
  assert.ok(!(await state()).tabs.find(t => t.id === never.tab.id).loaded, 'restored background tab stays unloaded');
  await command('select', { tab: never.tab.id }); await playing(await pageFor(neverURL), 'never');
  await quit();
  console.log(`PASS initial background media, native click/popup paths, hidden Spaces, Home/Reading, sessions, playlists, unload and restart. Artifacts: ${profile}`);
} finally {
  if (child?.exitCode === null) { child.kill('SIGTERM'); await exited; }
  await new Promise(resolve => fixture.close(resolve));
}
