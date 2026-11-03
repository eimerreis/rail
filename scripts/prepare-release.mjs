import { execFileSync } from 'node:child_process';
import { appendFileSync, mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { checkChange, checkRange, git, planRelease, releaseForVersion } from './changesets.mjs';

const require = createRequire(import.meta.url);

// Runs inside the serialized release workflow. Pushing the result is a separate,
// ordinary fast-forward push: a concurrent main update must never be overwritten.
export function prepareRelease(cwd, releases = []) {
  if (git(cwd, 'status', '--porcelain').trim()) throw new Error('Release preparation requires a clean working tree.');
  const head = git(cwd, 'rev-parse', 'HEAD').trim();
  const previous = planRelease(cwd, { head, manual: true });
  const base = previous.sha || git(cwd, 'rev-list', '--max-parents=0', 'HEAD').trim();
  checkRange(cwd, base, head);
  const temporary = mkdtempSync(join(tmpdir(), 'rail-release-'));
  try {
    const output = join(temporary, 'status.json');
    execFileSync(process.execPath, [require.resolve('@changesets/cli/bin.js'), 'status', '--output', output], { cwd, stdio: 'inherit' });
    const status = JSON.parse(readFileSync(output, 'utf8'));
    const pending = status.releases.find(release => release.name === 'rail');
    if (!pending) {
      console.log('No pending changesets; retry an unpublished version or skip.');
      return previous.sha ? { ...releaseForVersion(previous.version, previous.sha, releases), versioned: false } : { publish: false, versioned: false };
    }
    releaseForVersion(pending.newVersion, head, releases);
    execFileSync('npm', ['run', 'changeset:version'], { cwd, stdio: 'inherit' });
    git(cwd, 'add', 'package.json', 'package-lock.json', 'CHANGELOG.md', '.changeset');
    const result = checkChange(cwd, 'HEAD', 'index');
    git(cwd, 'commit', '-m', `Version Rail ${result.version}`);
    const sha = git(cwd, 'rev-parse', 'HEAD').trim();
    return { ...releaseForVersion(result.version, sha, releases), versioned: true };
  } finally { rmSync(temporary, { recursive: true, force: true }); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  try {
    const { values } = parseArgs({ options: { releases: { type: 'string' } } });
    const result = prepareRelease(process.cwd(), values.releases ? JSON.parse(readFileSync(values.releases, 'utf8')) : []);
    console.log(JSON.stringify(result));
    if (process.env.GITHUB_OUTPUT)
      appendFileSync(process.env.GITHUB_OUTPUT, Object.entries(result).map(([key, value]) => `${key}=${value}\n`).join(''));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
