# Rail changesets

Run `npm ci` to install the CLI and pre-commit hook. Add a new changeset to every change commit with `npm run changeset`; choose `rail`, a patch/minor/major bump, and a release note.

Merge or push your change and changeset into `main`. The pipeline runs `changeset status`, runs `npm run changeset:version` when pending changesets exist, commits the generated version/changelog metadata, and publishes the signed Sparkle release. No separate version PR is needed.

See [the release workflow](../docs/updates.md) and [Changesets documentation](https://changesets.dev/guide/getting-started).
