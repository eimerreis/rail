#!/usr/bin/env node
// Themes in the real app: switching, native appearance, no stale surfaces, persistence and
// fallback across relaunch. Saves screenshots of each theme to .runtime-test/themes-<time>/.
// Uses a disposable profile and localhost fixtures only. Needs Node 22+ and python3 with Pillow
// for pixel checks; full-window screenshots need Screen Recording permission for the terminal.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, mkdtemp, readFile, writeFile, rename, rm, copyFile } from 'node:fs/promises';
import { openSync, closeSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
await mkdir(resolve(root, '.runtime-test'), { recursive: true });
const profile = await mkdtemp(resolve(root, '.runtime-test/theme-'));
const shots = resolve(root, `.runtime-test/themes-${new Date().toISOString().replace(/[:.]/g, '-')}`);
await mkdir(shots, { recursive: true });

const fixture = createServer((request, response) => {
  response.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
  response.end(`<!doctype html><meta charset="utf-8"><title>Rail theme fixture</title><style>body{font:17px system-ui;padding:44px;max-width:640px;color:#1d2733;background:#fff}h1{font-size:30px}</style><h1>A real webpage</h1><p>This page keeps its own colours and fonts in every Rail theme.</p>`);
});
fixture.listen(0, '127.0.0.1'); await once(fixture, 'listening');
const origin = `http://127.0.0.1:${fixture.address().port}`;
const closed = createServer(); closed.listen(0, '127.0.0.1'); await once(closed, 'listening');
const closedPort = closed.address().port; await new Promise(done => closed.close(done));

let child, childExit, sequence = 0, checks = 0;
const pause = ms => new Promise(done => setTimeout(done, ms));
async function until(label, task, timeout = 15000) {
  const end = Date.now() + timeout; let last;
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
  await writeFile(resolve(profile, 'command.tmp'), JSON.stringify({ id, action, ...args }));
  await rename(resolve(profile, 'command.tmp'), resolve(profile, 'automation-command.json'));
  if (action === 'quit') return;
  return until(`command ${action}`, async () => { const s = await state(); return s.command === id && s; });
}
function passed(message) { checks++; console.log(`PASS ${message}`); }
async function start() {
  await rm(resolve(profile, 'automation-state.json'), { force: true });
  await rm(resolve(profile, 'automation-command.json'), { force: true });
  const log = openSync(resolve(profile, 'app.log'), 'a');
  child = spawn(resolve(root, 'build/Release/Rail.app/Contents/MacOS/Rail'), [`--data-dir=${profile}`, '--automation'], { stdio: ['ignore', log, log] });
  closeSync(log); childExit = once(child, 'exit');
  return until('native app startup', state, 25000);
}
async function stop() {
  const exiting = childExit; await command('quit');
  const [code] = await Promise.race([exiting, pause(15000).then(() => { throw new Error('Native quit did not finish'); })]);
  assert.equal(code, 0, 'App must exit cleanly'); child = null;
}

// Pixel colours from a capture of Rail's own views (rendered by AppKit, without web content).
function sample(png, width, points) {
  // Captures are in the display's colour space; convert to sRGB, the space the theme tokens use.
  const script = `import sys,json,io\nfrom PIL import Image,ImageCms\nim=Image.open(sys.argv[1])\nicc=im.info.get('icc_profile')\nim=im.convert('RGB')\nif icc: im=ImageCms.profileToProfile(im,ImageCms.ImageCmsProfile(io.BytesIO(icc)),ImageCms.createProfile('sRGB'))\nsx=im.width/float(sys.argv[2])\nprint(json.dumps([('%02X%02X%02X' % im.getpixel((int(x*sx),int(y*sx)))) for x,y in json.loads(sys.argv[3])]))`;
  return JSON.parse(execFileSync('python3', ['-c', script, png, String(width), JSON.stringify(points)]).toString());
}
const near = (a, b, tolerance = 6) => [0, 2, 4].every(i => Math.abs(parseInt(a.slice(i, i + 2), 16) - parseInt(b.slice(i, i + 2), 16)) <= tolerance);
async function capture(name) {
  const s = await command('capture');
  const native = resolve(profile, 'native-window.png');
  await copyFile(native, resolve(shots, `${name}-views.png`));
  // A real window screenshot, web content included; skipped without Screen Recording permission.
  let window = null;
  try {
    const file = resolve(shots, `${name}.png`);
    execFileSync('screencapture', ['-x', '-o', '-l', String(s.windowNumber), file], { stdio: 'ignore' });
    if (existsSync(file)) window = file;
  } catch {}
  return { native, window, state: s };
}

const palettes = {
  porcelain: { rail: 'E3DDD2', sidebar: 'E8E3D9', shell: 'EEEAE2', content: 'FAF8F2' },
  nightline: { rail: '0F2427', sidebar: '173237', shell: '122A2D', content: '1D3A3D' },
  daylight: { rail: 'D5E3EE', sidebar: 'DCE8F1', shell: 'E5EEF5', content: 'FCFDFE' },
};
// Points on plain surfaces at the small interface size, from the window's bottom-left area:
// the rail below the Spaces, the sidebar below the tab list, the status bar, the page.
async function expectTheme(theme, label) {
  const { native, state: s } = await capture(`${theme}-${label}`);
  const [w, h] = s.rootSize;
  const [rail, sidebar, statusbar, page] = sample(native, w, [[22, h - 160], [200, h - 60], [w * .55, h - 13], [w - 120, h - 90]]);
  const p = palettes[theme];
  assert.ok(near(rail, p.rail), `${theme} ${label}: rail ${rail} should be ${p.rail}`);
  assert.ok(near(sidebar, p.sidebar), `${theme} ${label}: sidebar ${sidebar} should be ${p.sidebar}`);
  assert.ok(near(statusbar, p.shell), `${theme} ${label}: status bar ${statusbar} should be ${p.shell}`);
  assert.ok(near(page, p.content), `${theme} ${label}: built-in page ${page} should be ${p.content}`);
}

try {
  let s = await start();
  assert.equal(s.theme, 'porcelain'); assert.equal(s.appliedTheme, 'porcelain');
  assert.match(s.appearance, /Aqua/); assert.doesNotMatch(s.appearance, /Dark/);
  passed('new profile starts in Porcelain with the light native appearance');

  // Sample content: a page, a pinned tab, a sleeping tab and two projects on local fixtures.
  await command('newTab', { url: `${origin}/page` });
  await until('fixture page', async () => (await state()).tabs.some(t => t.url.startsWith(origin) && t.loaded));
  await command('pin');
  await command('newTab', { url: `${origin}/notes` });
  await command('newTab', { url: 'about:blank' });
  await command('addProject', { name: 'Rail', repo: 'https://github.com/contoso/rail', session: 'work' });
  await command('addEnvironment', { project: 'Rail', name: 'Local', url: origin, session: 'work' });
  await command('addEnvironment', { project: 'Rail', name: 'PROD', url: `${origin}/prod`, session: 'work' });
  await command('addProject', { name: 'Website', repo: '', session: 'work' });
  await command('addEnvironment', { project: 'Website', name: 'Local', url: `http://127.0.0.1:${closedPort}`, session: 'work' });
  await command('home');

  for (const theme of ['porcelain', 'nightline', 'daylight']) {
    s = await command('theme', { theme });
    assert.equal(s.theme, theme); assert.equal(s.appliedTheme, theme);
    assert.equal(/Dark/.test(s.appearance), theme === 'nightline', `${theme}: window appearance ${s.appearance}`);
    await command('checkProjects'); await pause(1200);
    await expectTheme(theme, 'projects');
    await command('activity'); await pause(300); await capture(`${theme}-activity`);
    await command('select', { tab: (await state()).tabs.find(t => t.url === `${origin}/page`).id }); await pause(600);
    await capture(`${theme}-webpage`);
    await command('settings', { pane: 'appearance' }); await pause(400);
    s = await capture(`${theme}-settings`).then(r => r.state);
    assert.equal(/Dark/.test(s.settingsAppearance), theme === 'nightline', `${theme}: settings appearance ${s.settingsAppearance}`);
    if (existsSync(resolve(profile, 'settings-window.png'))) await copyFile(resolve(profile, 'settings-window.png'), resolve(shots, `${theme}-settings-views.png`));
    try { execFileSync('screencapture', ['-x', '-o', '-l', String(s.settingsWindowNumber), resolve(shots, `${theme}-settings-window.png`)], { stdio: 'ignore' }); } catch {}
    await command('home');
    passed(`${theme}: applied without restart; native appearance, rail, sidebar, status bar and Projects page match`);
  }

  // Back and forth: nothing from an earlier theme may survive.
  for (const theme of ['nightline', 'porcelain', 'nightline', 'daylight', 'porcelain', 'daylight']) {
    await command('theme', { theme }); await pause(150);
    await expectTheme(theme, 'repeat');
  }
  passed('switching repeatedly leaves no stale surfaces');

  const before = await state();
  await command('theme', { theme: 'nightline' });
  await stop(); s = await start();
  assert.equal(s.theme, 'nightline'); assert.equal(s.appliedTheme, 'nightline'); assert.match(s.appearance, /Dark/);
  assert.equal(s.tabs.length, before.tabs.length, 'tabs kept across relaunch');
  await command('home'); await expectTheme('nightline', 'relaunch');
  passed('Nightline survives relaunch, with the dark native appearance from the first frame');

  await stop();
  const file = resolve(profile, 'state.json');
  const saved = JSON.parse(await readFile(file, 'utf8'));
  for (const stored of ['sepia', undefined]) {
    if (stored === undefined) delete saved.theme; else saved.theme = stored;
    await writeFile(file, JSON.stringify(saved));
    s = await start();
    assert.equal(s.theme, 'porcelain', `stored ${stored ?? 'no'} theme should fall back to Porcelain`);
    assert.equal(s.appliedTheme, 'porcelain');
    assert.equal(s.tabs.length, before.tabs.length, 'other state kept');
    await stop();
  }
  passed('unknown and missing themes fall back to Porcelain and keep the rest of the layout');

  // The largest interface size scales the rail, logo, wordmark and Space home together.
  for (const theme of ['nightline', 'daylight']) {
    await writeFile(file, JSON.stringify({ ...saved, theme, controlSize: 'large' }));
    s = await start(); assert.equal(s.theme, theme);
    await command('home'); await pause(500); await capture(`${theme}-large`);
    await stop();
  }
  passed('Large interface size starts in the saved theme (screenshots for review)');
  console.log(`${checks} theme checks passed. Screenshots: ${shots}`);
} catch (error) {
  console.error(error.stack || error.message);
  process.exitCode = 1;
  if (child) child.kill('SIGKILL');
} finally {
  fixture.close();
}
