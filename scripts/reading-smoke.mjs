#!/usr/bin/env node
// Reading list integration check: saving, the reader, pages it can't read, link rules, feeds, persistence, quitting.
// Uses a disposable profile and a localhost fixture. EIMERRAIL_APP overrides the app to run.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, mkdtemp, readFile, writeFile, rename, rm, copyFile } from 'node:fs/promises';
import { existsSync, openSync, closeSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const app = process.env.EIMERRAIL_APP || resolve(root, 'build/Release/Eimerrail.app/Contents/MacOS/Eimerrail');
await mkdir(resolve(root, '.runtime-test'), { recursive: true });
const profile = await mkdtemp(resolve(root, '.runtime-test/reading-'));

const paragraph = (n) => `<p>Paragraph ${n} of the article, written in full sentences so it counts as prose. Retry budgets limit how much extra load retries may add, and that limit has to be shared across the whole service, not counted per request.</p>`;
const articleBody = Array.from({ length: 40 }, (_, i) => paragraph(i + 1)).join('');
const page = (title, body, head = '') => `<!doctype html><meta charset="utf-8"><title>${title}</title>${head}<body><nav><a href="/">Home</a><a href="/about">About</a></nav>${body}<footer>Footer text that must not be read</footer></body>`;
const feedRequests = { count: 0 };
let extraEntry = '';
const rss = (origin) => {
  const items = Array.from({ length: 8 }, (_, i) => `<item><title>Feed post ${i + 1}</title><link>${origin}/post/${i + 1}</link><guid>post-${i + 1}</guid><pubDate>${new Date(Date.UTC(2026, 9, 20 + i)).toUTCString()}</pubDate></item>`).join('');
  return `<?xml version="1.0"?><rss version="2.0"><channel><title>Fixture Feed</title><link>${origin}/</link>${extraEntry}${items}</channel></rss>`;
};
let feedBroken = false, flakyFailed = false;
const fixture = createServer((req, res) => {
  const origin = `http://${req.headers.host}`;
  const html = (body, status = 200) => { res.writeHead(status, { 'Content-Type': 'text/html' }); res.end(body); };
  if (req.url === '/article' || req.url.startsWith('/post/') || req.url === '/ruled/article') return html(page('Retry budgets are smaller', `<article><h1>Retry budgets are smaller</h1><h2>Count what you can afford</h2>${articleBody}<ul><li>First point in the list</li></ul><pre>retries = spare * window</pre><p>Read <a href="${origin}/linked">more</a> or <a href="javascript:alert(1)">run this</a>.</p></article><aside>Sidebar text that must not be read</aside>`, '<meta property="og:site_name" content="Rivet Notes"><meta name="author" content="A. Writer">'));
  if (req.url === '/late') return html(page('Late', `<div id="c"></div><script>setTimeout(()=>{document.getElementById('c').innerHTML=${JSON.stringify(articleBody)}},1500)</script>`));
  if (req.url === '/delayed') return setTimeout(() => html(page('Delayed article', `<article>${articleBody}</article>`)), 7000);
  if (req.url === '/flaky' && !flakyFailed) { flakyFailed = true; return req.socket.destroy(); }
  if (req.url === '/flaky') return html(page('Flaky article', `<article>${articleBody}</article>`));
  if (req.url === '/wiki') return html(page('Encyclopedia entry', `<div class="content"><h1>Encyclopedia entry</h1><p>The lead paragraph comes before any section and has to stay in the article, because it says what the whole entry is about.</p><section><h2>History</h2>${articleBody}</section><section><h2>Later years</h2>${paragraph('in the shorter section')}${paragraph('in the shorter section')}</section><h2>References</h2><div class="reflist"><ol class="references">${Array.from({ length: 150 }, (_, i) => `<li>Citation ${i}, "A long source title, with commas, and a date", Publisher. Retrieved 1 October 2023. Must not be read.</li>`).join('')}</ol></div></div>`));
  if (req.url === '/short') return html(page('Short page', '<p>Too little text.</p>'));
  if (req.url === '/signin') return html(page('Sign in', '<form><input name="u"><input type="password" name="p"><button>Sign in</button></form>'));
  if (req.url === '/denied') return html(page('Denied', 'No'), 403);
  if (req.url === '/gone') return html(page('Gone', 'No'), 404);
  if (req.url === '/hostile') return html(page('Hostile', `<article>${articleBody}<script>window.open('/popup');alert('hello');location.href='javascript:void(0)'</script></article>`));
  if (req.url === '/slow') return setTimeout(() => html(page('Slow', '<p>Eventually.</p>')), 30000);
  if (req.url === '/feed.xml') { feedRequests.count++; if (feedBroken) return html('nope', 500); res.writeHead(200, { 'Content-Type': 'application/rss+xml' }); return res.end(rss(origin)); }
  if (req.url === '/blog') return html(page('Blog', '<p>Blog home</p>', '<link rel="alternate" type="application/rss+xml" href="/feed.xml">'));
  return html(page(req.url, '<p>Plain page</p>'));
});
fixture.listen(0, '127.0.0.1'); await once(fixture, 'listening');
const origin = `http://127.0.0.1:${fixture.address().port}`;

let child, sequence = 0, checks = 0;
const pause = ms => new Promise(r => setTimeout(r, ms));
async function until(label, task, timeout = 30000) {
  const end = Date.now() + timeout; let last;
  while (Date.now() < end) {
    if (child?.exitCode !== null && child?.exitCode !== undefined) throw new Error(`App exited during ${label}. See ${profile}/app.log`);
    try { const v = await task(); if (v) return v; } catch (e) { last = e; }
    await pause(100);
  }
  throw new Error(`Timed out: ${label}${last ? `: ${last.message}` : ''}. See ${profile}/app.log`);
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
  child = spawn(app, [`--data-dir=${profile}`, '--automation'], { stdio: ['ignore', log, log] });
  closeSync(log);
  return until('startup', state, 30000);
}
async function stop() {
  const exiting = once(child, 'exit'); await command('quit');
  const [code] = await Promise.race([exiting, pause(15000).then(() => { throw new Error('quit timed out'); })]);
  assert.equal(code, 0); child = null;
}
async function shot(name) { await pause(500); await command('capture'); await copyFile(resolve(profile, 'native-window.png'), resolve(profile, `${name}.png`)); }
const item = (s, url) => s.reading.items.find(i => i.url === url);
async function save(path) { await command('readingSave', { url: origin + path }); return until(`${path} settles`, async () => { const s = await state(); const i = item(s, origin + path); return i && i.reader !== 'pending' && s; }, 100000); }

try {
  await start();
  let s = await command('reading');
  assert.equal(s.readingVisible, true); assert.equal(s.reading.items.length, 0);
  await shot('reading-empty');
  passed('Reading opens, independent of any Space');
  const tabsBefore = s.tabs.length, spaceBefore = s.activeSpace;

  await command('readingSave', { url: 'not a link' });
  s = await state();
  assert.equal(s.reading.items.length, 0); assert.match(s.status, /doesn't look like a link/);
  await command('readingSave', { url: 'javascript:alert(1)' });
  assert.equal((await state()).reading.items.length, 0);
  passed('text and non-web addresses are refused, not searched for');

  s = await save('/article');
  let a = item(s, origin + '/article');
  assert.equal(a.reader, 'ready'); assert.equal(a.title, 'Retry budgets are smaller'); assert.equal(a.read, false); assert.ok(a.minutes >= 1);
  assert.equal(a.session, 'work'); assert.equal(s.tabs.length, tabsBefore); assert.equal(s.activeSpace, spaceBefore);
  const cached = JSON.parse(await readFile(resolve(profile, 'Reading', `${a.id}.json`), 'utf8'));
  const text = JSON.stringify(cached.blocks);
  assert.match(text, /Paragraph 40/); assert.doesNotMatch(text, /must not be read/); assert.doesNotMatch(text, /javascript:/);
  assert.ok(cached.blocks.some(b => b.t === 'pre') && cached.blocks.some(b => b.t === 'li'));
  assert.equal(cached.site, 'Rivet Notes'); assert.equal(cached.byline, 'A. Writer');
  passed('a pasted link becomes an article in the background, without nav, footer, sidebar or script links');

  s = await command('readingSelect', { item: a.id });
  assert.equal(s.reading.selected, a.id); assert.equal(item(s, a.url).read, false);
  await shot('reading-article');
  passed('selecting an item shows it and does not mark it read');

  await command('readingProgress', { progress: .6 });
  s = await state(); assert.ok(Math.abs(item(s, a.url).progress - .6) < .01); assert.equal(item(s, a.url).read, false);
  await command('readingProgress', { progress: 1 });
  s = await state(); assert.equal(item(s, a.url).read, false);
  await command('readingProgress', { progress: .6 });
  passed('reading progress is kept and reaching the end does not mark read');

  await command('readingSave', { url: origin + '/article' });
  s = await state(); assert.equal(s.reading.items.filter(i => i.url === origin + '/article').length, 1); assert.match(s.status, /Already in your list/);
  passed('saving the same link twice keeps one item');

  s = await save('/late');
  assert.equal(item(s, origin + '/late').reader, 'ready');
  passed('articles filled in by scripts are waited for');

  s = await save('/delayed');
  assert.equal(item(s, origin + '/delayed').reader, 'ready');
  passed('a slow server is waited for, not mistaken for an empty page');

  s = await save('/flaky');
  assert.equal(item(s, origin + '/flaky').reader, 'ready');
  passed('a connection that drops once is tried again, not labelled as having no reader view');

  s = await save('/wiki');
  const wiki = JSON.stringify(JSON.parse(await readFile(resolve(profile, 'Reading', `${item(s, origin + '/wiki').id}.json`), 'utf8')).blocks);
  assert.match(wiki, /Paragraph 40/); assert.doesNotMatch(wiki, /Citation \d/);
  assert.match(wiki, /lead paragraph/); assert.match(wiki, /in the shorter section/);
  await command('readingRemove', { item: item(s, origin + '/wiki').id });
  passed('an article split into sections stays whole, without its reference list');

  s = await save('/short');
  assert.equal(item(s, origin + '/short').reader, 'unavailable'); assert.equal(item(s, origin + '/short').title, 'Short page');
  s = await save('/signin'); assert.equal(item(s, origin + '/signin').reader, 'login');
  s = await save('/denied'); assert.equal(item(s, origin + '/denied').reader, 'login');
  s = await save('/gone'); assert.equal(item(s, origin + '/gone').reader, 'unavailable');
  passed('short, login-protected and missing pages say so instead of showing a fragment');

  s = await save('/hostile');
  assert.equal(item(s, origin + '/hostile').reader, 'ready');
  assert.equal(s.tabs.length, tabsBefore); assert.equal(s.sheet, '');
  passed('a page reading in the background cannot open tabs or dialogs');
  await shot('reading-list');

  const short = item(s, origin + '/short');
  s = await command('readingSelect', { item: short.id });
  assert.equal(s.readingVisible, false); assert.equal(s.tabs.find(t => t.id === s.activeTab).url, short.url);
  assert.equal(item(s, short.url).read, false);
  passed('a page without a reader view opens as a tab, still unread');
  await command('reading');
  s = await command('readingOpenOriginal');
  assert.equal(s.tabs.filter(t => t.url === short.url).length, 1);
  passed('opening the same page again reuses its tab');

  await command('reading');
  s = await command('readingSelect', { item: a.id });
  s = await command('readingToggleRead');
  assert.equal(item(s, a.url).read, true); assert.equal(s.reading.selected, a.id);
  await command('readingShowRead', { read: true });
  s = await state(); assert.equal(s.reading.shownRows, 1);
  await shot('reading-read');
  s = await command('readingToggleRead');
  assert.equal(item(s, a.url).read, false);
  s = await command('readingToggleRead');
  await command('readingShowRead', { read: false });
  passed('mark read moves an item to Read, and the same action undoes it');

  // The real keyboard paths, through the app's event handling.
  s = await command('readingSelect', { item: item(await state(), origin + '/late').id });
  const lateID = s.reading.selected;
  s = await command('key', { chars: 'e' });
  assert.equal(s.reading.items.find(i => i.id === lateID).read, true);
  s = await command('key', { chars: 'e' });
  assert.equal(s.reading.items.find(i => i.id === lateID).read, false);
  s = await command('key', { chars: 'k' });
  assert.notEqual(s.reading.selected, lateID);
  s = await command('key', { chars: 'j' });
  assert.equal(s.reading.selected, lateID);
  passed('E marks read and back, J and K move through the list');
  // Short, login and missing pages sit between readable rows; walking past them must keep working.
  s = await command('readingSelect', { item: item(await state(), origin + '/late').id });
  const inbox = s.reading.items.filter(i => !i.read).length;
  let stuck = 0, seenMessage = false;
  for (let i = 0; i < inbox; i++) {
    const before = (await state()).reading.selected;
    s = await command('key', { chars: 'k' });
    const current = s.reading.items.find(x => x.id === s.reading.selected);
    if (current.reader !== 'ready' && !seenMessage) { seenMessage = true; await shot('reading-message'); }
    if (s.reading.selected === before) stuck++;
    else if (current.reader === 'ready') assert.equal(s.reading.readerOffset, 0, `${current.url} should open at its top`);
  }
  assert.ok(seenMessage); assert.equal(stuck, 1, 'only the top of the list stops K');
  passed('J and K keep working across pages without a reader view, and unstarted articles open at the top');
  s = await command('readingSelect', { item: item(await state(), origin + '/delayed').id });
  const triage = s.reading.selected;
  s = await command('key', { chars: 'k' });
  const above = s.reading.selected;
  s = await command('key', { chars: 'j' });
  assert.equal(s.reading.selected, triage);
  s = await command('key', { chars: 'e' });
  assert.equal(s.reading.selected, triage);
  s = await command('key', { chars: 'k' });
  assert.equal(s.reading.selected, above, 'K goes to the row above the one that left');
  await command('readingSelect', { item: triage });
  await command('readingShowRead', { read: true });
  await command('key', { chars: 'e' });
  await command('readingShowRead', { read: false });
  passed('after marking read, the list keeps its place');
  s = await command('key', { chars: 'l', command: true, shift: true });
  assert.equal(s.readingVisible, false);
  s = await command('key', { chars: 'l', command: true, shift: true });
  assert.equal(s.readingVisible, true);
  passed('⌘⇧L opens and closes Reading');
  const clipboard = execFileSync('pbpaste', { encoding: 'utf8' });
  try {
    execFileSync('pbcopy', { input: origin + '/pasted' });
    await command('key', { chars: 'v', command: true });
    s = await until('pasted link', async () => { const v = await state(); return item(v, origin + '/pasted') && v; });
    passed('⌘V saves the link on the clipboard');
    execFileSync('pbcopy', { input: 'just some words' });
    const count = s.reading.items.length;
    s = await command('key', { chars: 'v', command: true });
    assert.equal(s.reading.items.length, count);
    passed('⌘V ignores a clipboard without a link');
  } finally { execFileSync('pbcopy', { input: clipboard }); }
  s = await command('readingRemove', { item: item(await state(), origin + '/pasted').id });

  // Feeds
  await command('readingAddFeed', { url: origin + '/nothing' });
  await until('no feed message', async () => /No feed found/.test((await state()).status));
  await command('readingAddFeed', { url: origin + '/blog' });
  s = await until('feed added', async () => { const v = await state(); return v.reading.feeds.length === 1 && v; });
  assert.equal(s.reading.feeds[0].url, origin + '/feed.xml'); assert.equal(s.reading.feeds[0].title, 'Fixture Feed');
  assert.equal(s.reading.feeds[0].unread, 5);
  const feedItem = item(s, origin + '/post/8');
  assert.ok(feedItem); assert.equal(feedItem.reader, 'pending'); assert.equal(feedItem.title, 'Feed post 8'); assert.equal(item(s, origin + '/post/1'), undefined);
  passed('a site address finds its feed, and a new feed brings only its newest five');
  await shot('reading-feeds');

  await pause(500);
  assert.equal(item(await state(), feedItem.url).reader, 'pending');
  await command('readingSelect', { item: feedItem.id });
  s = await until('feed item read', async () => { const v = await state(); return item(v, feedItem.url).reader === 'ready' && v; });
  assert.equal(item(s, feedItem.url).title, 'Feed post 8');
  passed('feed items are only fetched when opened, and keep the title the feed gave them');

  const countBefore = (await state()).reading.items.length;
  await command('readingCheckFeeds');
  await pause(800);
  assert.equal((await state()).reading.items.length, countBefore);
  extraEntry = `<item><title>Fresh post</title><link>${origin}/post/fresh</link><guid>fresh</guid><pubDate>${new Date().toUTCString()}</pubDate></item>`;
  await command('readingCheckFeeds');
  s = await until('new entry', async () => { const v = await state(); return item(v, origin + '/post/fresh') && v; });
  assert.equal(s.reading.items.length, countBefore + 1);
  passed('checking again adds only entries that are really new');

  feedBroken = true;
  await command('readingCheckFeeds');
  s = await until('feed error', async () => { const v = await state(); return v.reading.feeds[0].error && v; });
  assert.match(s.reading.feeds[0].error, /500/);
  assert.equal(s.reading.items.length, countBefore + 1);
  await shot('reading-feed-error');
  feedBroken = false;
  await command('readingCheckFeeds');
  await until('feed recovers', async () => !(await state()).reading.feeds[0].error);
  passed('a failing feed shows why, keeps its items, and recovers');

  s = await command('readingFilter', { feed: s.reading.feeds[0].id });
  assert.ok(s.reading.shownRows >= 5); assert.ok(s.reading.shownRows < s.reading.items.length);
  await command('readingFilter', { feed: '' });
  passed('a feed can narrow the list');

  // Link targets: a Space rule decides where a link opens.
  await stop();
  const saved = JSON.parse(await readFile(resolve(profile, 'state.json'), 'utf8'));
  saved.spaceRules = [{ pattern: `127.0.0.1:${fixture.address().port}/ruled/**`, spaceID: 'personal' }];
  await writeFile(resolve(profile, 'state.json'), JSON.stringify(saved));
  s = await start();
  assert.equal(s.reading.items.length, countBefore + 1);
  assert.equal(item(s, a.url).read, true); assert.ok(Math.abs(item(s, a.url).progress - .6) < .01);
  assert.equal(item(s, a.url).reader, 'ready'); assert.equal(s.reading.feeds.length, 1);
  passed('the list, read state, progress and feeds survive a restart');

  await command('reading');
  // The list is longer than the window here, so moving down has to scroll it.
  await command('readingSelect', { item: s.reading.items.filter(i => !i.read && i.reader === 'ready')[0].id });
  const rows = (await state()).reading.shownRows;
  let hidden = 0;
  for (let i = 0; i < rows; i++) { const v = await command('key', { chars: 'j' }); if (!v.reading.selectedRowVisible) hidden++; }
  assert.equal(hidden, 0);
  for (let i = 0; i < rows; i++) { const v = await command('key', { chars: 'k' }); if (!v.reading.selectedRowVisible) hidden++; }
  assert.equal(hidden, 0);
  passed('J and K keep the selected row in view');

  // Tab order: paste field, then each row, and eventually the article.
  await command('readingFocusCapture');
  await until('paste field focused', async () => (await state()).reading.focus === 'capture');
  s = await command('key', { chars: '\t', keyCode: 48 });
  assert.notEqual(s.reading.focus, 'capture'); assert.notEqual(s.reading.focus, 'reader');
  const firstFocus = s.reading.focus;
  s = await command('key', { chars: '\t', keyCode: 48 });
  assert.notEqual(s.reading.focus, firstFocus);
  await shot('reading-focus');
  let hops = 0;
  while (s.reading.focus !== 'reader' && hops++ < 60) s = await command('key', { chars: '\t', keyCode: 48 });
  assert.equal(s.reading.focus, 'reader');
  s = await command('key', { chars: '\t', keyCode: 48 });
  assert.equal(s.reading.focus, 'capture');
  passed('Tab runs from the paste field through the rows to the article and back');

  await command('readingShowRead', { read: true });
  await command('readingSelect', { item: a.id });
  await shot('reading-resumed');
  await command('readingShowRead', { read: false });
  s = await save('/ruled/article');
  const ruled = item(s, origin + '/ruled/article');
  assert.equal(ruled.session, 'personal');
  await command('readingSelect', { item: ruled.id });
  s = await command('readingOpenOriginal');
  const opened = s.tabs.find(t => t.id === s.activeTab);
  assert.equal(opened.space, 'personal'); assert.equal(opened.session, 'personal'); assert.equal(opened.url, ruled.url);
  assert.equal(s.activeSpace, 'personal'); assert.equal(s.readingVisible, false); assert.equal(item(s, ruled.url).read, false);
  passed('a link claimed by a Space rule opens in that Space and its session, still unread');

  await command('reading');
  await command('readingSelect', { item: ruled.id });
  s = await command('readingSession', { session: 'work' });
  s = await until('re-read in new session', async () => { const v = await state(); return item(v, ruled.url).reader === 'ready' && item(v, ruled.url).session === 'work' && v; });
  passed('the session an item is read in can be changed');

  await command('readingSelect', { item: a.id });
  const removedPath = resolve(profile, 'Reading', `${ruled.id}.json`);
  await command('readingSelect', { item: ruled.id });
  s = await command('key', { chars: '\x7f', keyCode: 51, command: true });
  assert.equal(s.sheet, 'open'); assert.ok(item(s, ruled.url), '⌘⌫ asks first');
  s = await command('sheetCancel');
  assert.ok(item(s, ruled.url)); assert.equal(s.sheet, '');
  passed('⌘⌫ asks before removing, and cancelling keeps the item');
  assert.equal(existsSync(removedPath), true);
  s = await command('readingRemove', { item: ruled.id });
  assert.equal(item(s, ruled.url), undefined); assert.equal(existsSync(removedPath), false);
  passed('removing an item also removes its saved article');

  await rm(resolve(profile, 'Reading', `${a.id}.json`));
  await command('readingShowRead', { read: true });
  await command('readingSelect', { item: a.id });
  s = await until('article fetched again', async () => { const v = await state(); return item(v, a.url).reader === 'ready' && existsSync(resolve(profile, 'Reading', `${a.id}.json`)) && v; });
  passed('a lost saved article is fetched again');

  // Quitting mid-extraction must not hang or crash Chromium's shutdown.
  await command('readingSave', { url: origin + '/slow' });
  await pause(800);
  assert.notEqual((await state()).reading.activeSession, '');
  await stop();
  passed('quitting while a page is loading exits cleanly');

  await writeFile(resolve(profile, 'reading.json'), '{broken');
  s = await start();
  assert.equal(s.reading.items.length, 0); assert.match(s.status, /could not be read/);
  await stop();
  assert.ok((await import('node:fs')).readdirSync(profile).some(f => f.startsWith('reading-recovery-')));
  passed('a damaged reading list is kept as a recovery copy');

  console.log(`\n${checks} reading checks passed. Screenshots: ${profile}/reading-*.png`);
} catch (error) {
  console.error(`FAIL ${error.message}\nProfile: ${profile}`);
  if (child) child.kill();
  process.exitCode = 1;
} finally {
  fixture.closeAllConnections?.(); fixture.close();
}
