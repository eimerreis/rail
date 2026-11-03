import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { git } from './changesets.mjs';

const require = createRequire(import.meta.url);
const cwd = process.cwd();
let temporary;
try {
  if (git(cwd, 'status', '--porcelain').trim()) throw new Error('Commit your changes and changesets before versioning. The version commit must contain only release metadata.');
  temporary = mkdtempSync(join(tmpdir(), 'rail-version-'));
  const output = join(temporary, 'status.json');
  const cli = require.resolve('@changesets/cli/bin.js');
  execFileSync(process.execPath, [cli, 'status', '--output', output], { cwd, stdio: 'inherit' });
  const plan = JSON.parse(readFileSync(output, 'utf8'));
  if (!plan.releases.some(release => release.name === 'rail')) throw new Error('No pending Rail changesets to version.');
  execFileSync(process.execPath, [cli, 'version'], { cwd, stdio: 'inherit' });
  execFileSync('npm', ['install', '--package-lock-only', '--ignore-scripts'], { cwd, stdio: 'inherit' });
  console.log('Updated release metadata. CI runs this command automatically after changesets reach main.');
} catch (error) { console.error(error.message); process.exitCode = 1; }
finally { if (temporary) rmSync(temporary, { recursive: true, force: true }); }
