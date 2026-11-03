#!/usr/bin/env node
// Actual Chromium right-click hit testing and native clipboard, using a disposable profile.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, writeFile, rename, rm } from 'node:fs/promises';
import { openSync, closeSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
await mkdir(resolve(root, '.runtime-test'), { recursive: true });
const profile = await mkdtemp(resolve(root, '.runtime-test/context-menu-'));
// Preserve the user's clipboard and inspect image pixels without granting a page clipboard access.
const helperSource = resolve(profile, 'Clipboard.swift'), helper = resolve(profile, 'clipboard');
await writeFile(helperSource, `import AppKit
let board = NSPasteboard.general
let file = URL(fileURLWithPath: CommandLine.arguments[2])
switch CommandLine.arguments[1] {
case "save":
  let items = (board.pasteboardItems ?? []).map { item in
    Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
  }
  try PropertyListEncoder().encode(items).write(to: file)
case "restore":
  let saved = try PropertyListDecoder().decode([[String: Data]].self, from: Data(contentsOf: file))
  let items = saved.map { values in
    let item = NSPasteboardItem()
    for (type, data) in values { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
    return item
  }
  board.clearContents()
  if !items.isEmpty { board.writeObjects(items) }
case "read":
  if let data = board.data(forType: .png) { print(data.base64EncodedString()) }
default: fatalError("Unknown clipboard command")
}
`);
execFileSync('xcrun', ['swiftc', helperSource, '-o', helper]);
const clipboardFile = resolve(profile, 'clipboard.plist');
const clipboard = action => execFileSync(helper, [action, clipboardFile], { encoding: 'utf8' }).trim();
clipboard('save');
const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="19" height="13"><rect width="10" height="13" fill="red"/></svg>';
const fixture = createServer((req, res) => {
  if (req.url === '/image.svg') {
    if (!req.headers.cookie?.includes('imageSession=work')) { res.writeHead(403); res.end(); return; }
    res.writeHead(200, { 'Content-Type': 'image/svg+xml' }); res.end(svg); return;
  }
  if (req.url === '/broken.png') { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': 'text/html', 'Set-Cookie': 'imageSession=work; Path=/' });
  res.end(`<!doctype html><title>Context fixture</title><style>body{padding:24px}img{width:76px;height:52px}p{margin:20px}</style>
    <p id="plain">Plain text</p><p><a id="link" href="/destination">A link</a></p>
    <p><a href="/linked-destination"><img id="image" src="/image.svg"></a></p>
    <p><img id="broken" src="/broken.png"></p><p><img id="data" src="data:image/svg+xml,${encodeURIComponent(svg)}"></p>
    <p><img id="blob"></p><p><a id="script" href="javascript:alert('no')">Script link</a></p>
    <script>document.querySelector('#blob').src=URL.createObjectURL(new Blob([${JSON.stringify(svg)}],{type:'image/svg+xml'}));</script>`);
});
fixture.listen(0, '127.0.0.1'); await once(fixture, 'listening');
const url = `http://127.0.0.1:${fixture.address().port}/`;
const probe = createServer(); probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
const port = probe.address().port; await new Promise(resolve => probe.close(resolve));
const app = resolve(process.env.RAIL_TEST_APP || resolve(root, 'build/Release/Rail.app'));
const log = openSync(resolve(profile, 'app.log'), 'a');
const child = spawn(resolve(app, 'Contents/MacOS/Rail'), [`--data-dir=${profile}`, '--automation', `--debug-port=${port}`, ...(process.env.RAIL_TEST_MOCK_KEYCHAIN === '1' ? ['--use-mock-keychain'] : [])], { stdio: ['ignore', log, log] });
closeSync(log);
const exited = once(child, 'exit');
let sequence = 0;
async function until(label, task, timeout = 15000) {
  const end = Date.now() + timeout; let last;
  while (Date.now() < end) {
    if (child.exitCode !== null) throw new Error(`App exited during ${label}: ${child.exitCode}`);
    try { const result = await task(); if (result) return result; } catch (error) { last = error; }
    await new Promise(resolve => setTimeout(resolve, 80));
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
async function cdp(method, params = {}) {
  const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = pages.find(t => t.url === url);
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
const evaluate = async expression => (await cdp('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true })).result.value;
async function menu(selector, choice = '') {
  await rm(resolve(profile, 'context-menu.json'), { force: true });
  await writeFile(resolve(profile, 'context-menu-choice.txt'), choice);
  const point = await evaluate(`(() => { const el=document.querySelector(${JSON.stringify(selector)}); el.scrollIntoView(); const r=el.getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2}; })()`);
  for (const type of ['mousePressed', 'mouseReleased'])
    await cdp('Input.dispatchMouseEvent', { type, ...point, button: 'right', clickCount: 1 });
  return until('context menu', async () => JSON.parse(await readFile(resolve(profile, 'context-menu.json'), 'utf8')));
}
const has = (items, title) => items.some(item => item.title === title && item.enabled);
async function copiedImage(selector) {
  const before = clipboard('read');
  const items = await menu(selector, 'Copy Image');
  assert.ok(has(items, 'Copy Image'));
  await until('PNG on macOS clipboard', () => clipboard('read') && clipboard('read') !== before);
  const png = Buffer.from(clipboard('read'), 'base64');
  assert.equal(png.readUInt32BE(16), 19); assert.equal(png.readUInt32BE(20), 13);
}
try {
  await until('startup', state);
  const initial = await command('newTab', { url, session: 'work' });
  try { await until('fixture images', () => evaluate("document.readyState==='complete' && ['image','data','blob'].every(id=>document.getElementById(id).naturalWidth===19)")); }
  catch (error) { console.error(await evaluate("JSON.stringify({title:document.title,html:document.documentElement.outerHTML,images:[...document.images].map(i=>({id:i.id,width:i.naturalWidth,src:i.src}))})")); throw error; }
  const plain = await menu('#plain');
  assert.ok(has(plain, 'Inspect Element')); assert.ok(!has(plain, 'Copy Image')); assert.ok(!has(plain, 'Open Link in New Tab'));
  const linked = await menu('#image');
  for (const title of ['Copy Image', 'Open Image in New Tab', 'Open Link in New Tab']) assert.ok(has(linked, title), title);
  const broken = await menu('#broken');
  assert.ok(broken.some(item => item.title === 'Copy Image' && !item.enabled));
  assert.ok(!has(await menu('#script'), 'Open Link in New Tab'));
  await menu('#link', 'Open Link in New Tab');
  let s = await until('background link tab', async () => { const s = await state(); return s.tabs.some(t => t.url === `${url}destination`) && s; });
  assert.equal(s.activeTab, initial.activeTab);
  assert.equal(s.tabs.find(t => t.url === `${url}destination`).session, 'work');
  await menu('#image', 'Open Image in New Tab');
  s = await until('background image tab', async () => { const s = await state(); return s.tabs.some(t => t.url === `${url}image.svg`) && s; });
  assert.equal(s.activeTab, initial.activeTab);
  assert.equal(s.tabs.find(t => t.url === `${url}image.svg`).session, 'work');
  await copiedImage('#image');
  // Clear only the test image so identical pixels still prove that the next command copied.
  clipboard('restore'); await copiedImage('#data');
  clipboard('restore'); await copiedImage('#blob');
  await command('quit'); const [code] = await exited; assert.equal(code, 0);
  console.log(`Context menu integration passed: link/image menus, background tabs, session inheritance, broken images, blocked script links, authenticated/data/blob image copying and native PNG dimensions. Artifacts: ${profile}`);
} finally {
  if (child.exitCode === null) { child.kill('SIGTERM'); await exited; }
  clipboard('restore');
  await new Promise(resolve => fixture.close(resolve));
}
