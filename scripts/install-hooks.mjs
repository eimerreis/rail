import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';

if (!process.env.CI && existsSync('.git')) {
  execFileSync('git', ['config', 'core.hooksPath', '.githooks']);
  console.log('Installed Rail pre-commit changeset check.');
}
