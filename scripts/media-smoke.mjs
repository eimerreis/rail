#!/usr/bin/env node
// Decode H.264/AAC in the real browser using a disposable profile.
// Requires ffmpeg. RAIL_TEST_APP selects a separate Rail.app; optionally set
// RAIL_TEST_YOUTUBE_URL to verify a live stream as well as the local fixture.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, writeFile, rename } from 'node:fs/promises';
import { openSync, closeSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
await mkdir(resolve(root, '.runtime-test'), { recursive: true });
const profile = await mkdtemp(resolve(root, '.runtime-test/media-'));
const clip = resolve(profile, 'h264-aac.mp4');
execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
  'testsrc2=size=160x90:rate=15', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100',
  '-t', '4', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-movflags', '+faststart', clip]);
const bytes = await readFile(clip);
const fixture = createServer((req, res) => {
  if (req.url === '/clip.mp4') {
    res.writeHead(200, { 'Content-Type': 'video/mp4', 'Content-Length': bytes.length });
    res.end(bytes);
  } else {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end('<!doctype html><title>Rail media fixture</title><video controls loop src="/clip.mp4"></video>');
  }
});
fixture.listen(0, '127.0.0.1'); await once(fixture, 'listening');
const url = `http://127.0.0.1:${fixture.address().port}/`;
const probe = createServer(); probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
const port = probe.address().port; await new Promise(resolve => probe.close(resolve));
const log = openSync(resolve(profile, 'app.log'), 'a');
const app = resolve(process.env.RAIL_TEST_APP || resolve(root, 'build/Release/Rail.app'));
const child = spawn(resolve(app, 'Contents/MacOS/Rail'), [`--data-dir=${profile}`, '--automation', `--debug-port=${port}`], { stdio: ['ignore', log, log] });
closeSync(log);
const exited = once(child, 'exit');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
let sequence = 0;
async function until(label, task, timeout = 20000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (child.exitCode !== null) throw new Error(`App exited during ${label}: ${child.exitCode}`);
    try { const value = await task(); if (value) return value; } catch { /* Startup and navigation can still be in progress. */ }
    await pause(100);
  }
  throw new Error(`Timed out: ${label}. Artifacts: ${profile}`);
}
const state = async () => JSON.parse(await readFile(resolve(profile, 'automation-state.json'), 'utf8'));
async function command(action, args = {}) {
  const id = String(++sequence);
  await writeFile(resolve(profile, 'command.tmp'), JSON.stringify({ id, action, ...args }));
  await rename(resolve(profile, 'command.tmp'), resolve(profile, 'automation-command.json'));
  if (action !== 'quit') await until(action, async () => (await state()).command === id);
}
async function pageFor(address) {
  return until(`page ${address}`, async () => {
    const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(2000) })).json();
    return pages.find(page => page.type === 'page' && page.url === address);
  });
}
async function evaluate(page, expression) {
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  try {
    await once(ws, 'open', { signal: AbortSignal.timeout(5000) });
    const result = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('CDP evaluation timed out')), 10000);
      ws.addEventListener('message', event => {
        const message = JSON.parse(event.data); if (message.id !== 1) return;
        clearTimeout(timer);
        message.error ? reject(new Error(message.error.message)) : resolve(message.result);
      });
      ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression, returnByValue: true, awaitPromise: true, userGesture: true } }));
    });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  } finally { ws.close(); }
}
try {
  await until('startup', state);
  await command('newTab', { url });
  const page = await pageFor(url);
  const codecs = await evaluate(page, `(() => {
    const video = document.createElement('video');
    return ['video/mp4; codecs="avc1.42E01E"', 'audio/mp4; codecs="mp4a.40.2"'].map(type =>
      ({ type, element: video.canPlayType(type), mediaSource: MediaSource.isTypeSupported(type) }));
  })()`);
  console.log('Codec support:', JSON.stringify(codecs));
  assert.ok(codecs.every(codec => codec.element && codec.mediaSource), 'H.264 and AAC must both support HTML video and MediaSource');
  await evaluate(page, 'document.querySelector("video").play().then(() => true)');
  await until('H.264/AAC playback advances with decoded video and audio', async () => evaluate(page, `(() => {
    const v = document.querySelector('video');
    return v.currentTime > 0.5 && !v.paused && !v.error && v.readyState >= 2 &&
      v.webkitDecodedFrameCount > 0 && v.webkitAudioDecodedByteCount > 0;
  })()`));
  console.log('PASS H.264 video and AAC audio decode and play');
  if (process.env.RAIL_TEST_YOUTUBE_URL) {
    const address = new URL(process.env.RAIL_TEST_YOUTUBE_URL);
    assert.ok(['www.youtube.com', 'youtube.com'].includes(address.hostname) && address.protocol === 'https:', 'Use an HTTPS YouTube URL');
    await command('newTab', { url: address.href });
    const youtube = await pageFor(address.href);
    await until('YouTube player initializes', async () => evaluate(youtube, '!!document.querySelector("#movie_player")?.getPlayerResponse?.()?.videoDetails'), 30000);
    console.log('YouTube:', JSON.stringify(await evaluate(youtube, `(() => {
      const r = document.querySelector('#movie_player').getPlayerResponse();
      return { title: r.videoDetails?.title, status: r.playabilityStatus?.status, isLive: r.videoDetails?.isLive,
        formats: r.streamingData?.adaptiveFormats?.map(f => f.mimeType), error: document.querySelector('.ytp-error')?.innerText };
    })()`)));
    await evaluate(youtube, 'document.querySelector("#movie_player").playVideo(); true');
    await until('YouTube playback', async () => evaluate(youtube, `(() => {
      const v = document.querySelector('video');
      return v && !v.paused && !v.error && v.readyState >= 2 && v.webkitDecodedFrameCount > 0 && v.webkitAudioDecodedByteCount > 0;
    })()`), 45000);
    const before = await evaluate(youtube, 'document.querySelector("video").currentTime');
    await until('YouTube playback advances', async () => (await evaluate(youtube, 'document.querySelector("video").currentTime')) > before + 0.5);
    console.log('PASS YouTube playback advances with decoded video and audio');
  }
} finally {
  if (child.exitCode === null) {
    try { await command('quit'); } catch { child.kill('SIGTERM'); }
    let timer;
    const finished = await Promise.race([exited.then(() => true), new Promise(resolve => { timer = setTimeout(() => resolve(false), 10000); })]);
    clearTimeout(timer);
    if (!finished) child.kill('SIGKILL');
  }
  await new Promise(resolve => fixture.close(resolve));
  console.log(`Artifacts: ${profile}`);
}
